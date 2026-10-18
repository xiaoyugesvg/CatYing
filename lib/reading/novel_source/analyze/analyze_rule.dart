/// 规则引擎门面：按规则模式（CSS/XPath/JSON/JS/正则）分派到对应解析器，
/// 支持 `##` 正则替换、`@put` 变量、`<js>`/`@js:` 内嵌脚本与 `&&/||/%%` 复合规则。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as dkcrypto;
import 'package:encrypt/encrypt.dart' as dkenc;
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/desede_engine.dart';
import 'package:pointycastle/block/modes/cbc.dart';
import 'package:pointycastle/block/modes/ecb.dart';
import 'package:pointycastle/padded_block_cipher/padded_block_cipher_impl.dart';
import 'package:pointycastle/paddings/pkcs7.dart';
import 'package:pointycastle/pointycastle.dart';
import 'package:uuid/uuid.dart';
import '../../../services/app_log.dart';
import 'source_rule.dart';
import 'analyze_jsoup.dart';
import 'analyze_xpath.dart';
import 'analyze_json.dart';
import 'analyze_regex.dart';
import 'js_engine.dart';
import 'sync_http_bridge.dart';
import 'host_bridge.dart';
import 'cookie_store.dart';
import 'source_variable_store.dart';
import '../model/xiaoshuo_book.dart';
import '../model/xiaoshuo_book_chapter.dart';

class AnalyzeRule {
  XiaoshuoBook? book;
  XiaoshuoBookChapter? chapter;
  String? baseUrl;
  String? redirectUrl;
  String? nextChapterUrl;
  dynamic content;
  bool isJson = false;

  AnalyzeByJsoup? _analyzeByJsoup;
  AnalyzeByXPath? _analyzeByXPath;
  AnalyzeByJson? _analyzeByJson;
  JsEngine? _jsEngine;

  final Map<String, String> _variables = {};
  final Map<String, List<SourceRule>> _stringRuleCache = {};

  /// [PATCH-7] 当前书源身份：`source.bookSourceUrl` / `source.getKey()` 用。
  /// 由调用方（书源解析流程）在求值前设置；未设置时 `getKey()` 退回 `baseUrl`。
  String? bookSourceUrl;

  /// [PATCH-7] 书源备注（`source.bookSourceComment`）。
  String? bookSourceComment;

  /// [PATCH-7] 书源级变量与登录信息（`source.getVariable/setVariable/putLoginInfo`）。
  ///
  /// 与 `_variables`（`java.put/get`）分开：legado 里 `java.put/get` 是
  /// **规则级**变量，`source.*Variable` 是**书源级**（切换书源不串）。
  ///
  /// ── 🔴 为什么从"实例字段"改成"进程级存储" ──────────────────
  /// 原来它是 `AnalyzeRule` 的**实例字段** ✗ —— 而搜索 / 详情 / 目录 / 正文
  /// **各自 new 一个 `AnalyzeRule`**（全仓 12 处构造点）⇒ 在 `searchUrl` 里
  /// `source.setVariable(...)` 存下的值到 `bookInfo` 求值时**已经丢了** ✗
  /// ⇒ `source.getVariable()` 永远拿到空 ⇒ 依赖该机制的源整条链路失效 ✗。
  /// 现在按**书源身份**落到进程级存储：同一书源各步骤共享 ✓、不同书源不串 ✓。
  Map<String, String> get _sourceVariables =>
      SourceVariableStore.instance.box(_sourceKey);

  /// 当前书源身份键（`source.*` 存储分组用）。
  String get _sourceKey {
    final u = bookSourceUrl;
    if (u != null && u.isNotEmpty) return u;
    return baseUrl ?? '';
  }

  AnalyzeRule({this.book, this.chapter});

  AnalyzeRule setContent(dynamic newContent, [String? newBaseUrl]) {
    content = newContent;
    if (newContent is! Node) {
      // Map/List 直接来自 `ruleBookInfo.init` 的 JS 返回值（文档：
      // init 返回 `{a:'书名', b:'作者'…}`，之后各字段填 a/b/…）。
      // 只认字符串会让这类源退化成 CSS 模式 ⇒ 详情页所有字段都取不到。
      isJson = newContent is Map ||
          newContent is List ||
          _isJsonString(newContent?.toString() ?? '');
    } else {
      isJson = false;
    }
    if (newBaseUrl != null) baseUrl = newBaseUrl;
    _analyzeByJsoup = null;
    _analyzeByXPath = null;
    _analyzeByJson = null;
    return this;
  }

  AnalyzeRule setBaseUrl(String? url) {
    if (url != null) baseUrl = url;
    return this;
  }

  String? setRedirectUrl(String url) {
    try {
      redirectUrl = url;
    } catch (_) {}
    return redirectUrl;
  }

  AnalyzeRule setChapter(XiaoshuoBookChapter? ch) {
    chapter = ch;
    return this;
  }

  AnalyzeRule setNextChapterUrl(String? url) {
    nextChapterUrl = url;
    return this;
  }

  void put(String key, String value) {
    _variables[key] = value;
    if (key == 'title' && chapter != null) {
      chapter!.title = value;
    }
  }

  String get(String key) {
    switch (key) {
      case 'bookName':
        return book?.name ?? '';
      case 'title':
        return chapter?.title ?? '';
      default:
        return _variables[key] ?? book?.getVariable(key) ?? chapter?.getVariable(key) ?? '';
    }
  }

  List<String> getStringList(String? ruleStr, {bool isUrl = false}) {
    if (ruleStr == null || ruleStr.isEmpty) return [];
    final ruleList = _splitSourceRuleCache(ruleStr);
    return _getStringListFromRules(ruleList, isUrl: isUrl);
  }

  String getString(String? ruleStr, {bool unescape = true, bool isUrl = false, dynamic mContent}) {
    if (ruleStr == null || ruleStr.isEmpty) return '';
    final ruleList = _splitSourceRuleCache(ruleStr);
    return _getStringFromRules(ruleList, unescape: unescape, isUrl: isUrl, mContent: mContent);
  }

  String getStringFromRules(List<dynamic> ruleList, {bool unescape = true, bool isUrl = false, dynamic mContent}) {
    if (ruleList.isEmpty) return '';
    final sourceRules = ruleList.whereType<SourceRule>().toList();
    return _getStringFromRules(sourceRules, unescape: unescape, isUrl: isUrl, mContent: mContent);
  }

  List<String> getStringListFromRules(List<dynamic> ruleList, {bool isUrl = false}) {
    if (ruleList.isEmpty) return [];
    final sourceRules = ruleList.whereType<SourceRule>().toList();
    return _getStringListFromRules(sourceRules, isUrl: isUrl);
  }

  List<dynamic> getElements(String ruleStr) {
    if (ruleStr.isEmpty) return [];
    final ruleList = splitSourceRule(ruleStr, allInOne: true);
    return _getElementsFromRules(ruleList);
  }

  dynamic getElement(String ruleStr) {
    if (ruleStr.isEmpty) return null;
    var result = content;
    final ruleList = splitSourceRule(ruleStr, allInOne: true);
    if (result != null && ruleList.isNotEmpty) {
      for (final sourceRule in ruleList) {
        _putAll(sourceRule.putMap);
        if (result == null) continue;
        final st = _makeUpRule(sourceRule, result);
        if (st.rule.isNotEmpty) {
          result = _executeRuleElements(result, sourceRule, single: true);
        }
        if (result != null && st.replaceRegex.isNotEmpty) {
          result = _replaceRegex(result.toString(), st);
        }
      }
    }
    return result;
  }

  List<SourceRule> _splitSourceRuleCache(String ruleStr) {
    return _stringRuleCache.putIfAbsent(ruleStr, () => splitSourceRule(ruleStr));
  }

  /// `ruleBookInfo.init` 专用：JS 返回 **对象** 时取 JSON 文本。
  ///
  /// 官方约定 init 返回 `{a:'书名', b:'作者', …}`，后续字段填 a/b/…。
  /// QuickJS 的 `stringResult` 对对象只给 `[object Object]`，拿不到字段，
  /// 所以这里用 `JSON.stringify` 把同一段规则再包一层求值一次。
  /// （只在 `getElement` 确实返回 `[object Object]` 时调用，字符串规则不会多跑。）
  String evalJsObjectJson(String ruleStr) {
    var js = ruleStr.trim();
    js = js.replaceFirst(RegExp(r'^@js:\s*', caseSensitive: false), '');
    if (js.isEmpty) return '';
    final out = _evalJs('JSON.stringify((function(){ $js })())', content);
    if (out.isEmpty || out == 'undefined' || out == 'null') return '';
    return out;
  }

  // ════════════════════════════════════════════════════════════════
  // java.* 桥（对齐原版 cmbok / Legado 引擎）：这些方法通过 JS 绑定的
  // `java` 对象直接可调（js_engine 把本实例注入 JS 全局）。
  // ════════════════════════════════════════════════════════════════

  static final Uuid _uuid = Uuid();

  /// java.randomUUID()
  String randomUUID() => _uuid.v4();

  /// java.md5Encode(str) → 32 位小写 hex
  String md5Encode(String s) => dkcrypto.md5.convert(utf8.encode(s)).toString();

  /// java.md5Encode16(str) → 16 位（Legado：中间 16 位）
  String md5Encode16(String s) {
    final full = md5Encode(s);
    return full.substring(8, 24);
  }

  /// java.base64Encode(str)（UTF-8 → base64）
  String base64EncodeString(String s) => base64.encode(utf8.encode(s));

  /// java.base64Decode(str) → latin1 字符串（Legado 返回 byte[]，JS 按字符串用）
  String base64Decode(String s) {
    try {
      return latin1.decode(base64.decode(s));
    } catch (_) {
      return '';
    }
  }

  /// java.base64DecodeToByteArray(str) → Uint8List
  Uint8List base64DecodeToByteArray(String s) {
    try {
      return base64.decode(s);
    } catch (_) {
      return Uint8List(0);
    }
  }

  /// java.hexEncodeToString(str)（UTF-8 → hex 小写）
  String hexEncodeToString(String s) {
    return utf8.encode(s).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// java.hexDecodeToString(hex) → UTF-8 字符串
  String hexDecodeToString(String s) {
    try {
      final bytes = Uint8List(s.length ~/ 2);
      for (var i = 0; i < s.length; i += 2) {
        bytes[i ~/ 2] = int.parse(s.substring(i, i + 2), radix: 16);
      }
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  /// java.getElementsSingle(rule, [text])：列表规则取首元素
  dynamic getElementsSingle(String ruleStr, [String? text]) {
    final saved = content;
    if (text != null) content = text;
    try {
      final list = getElements(ruleStr);
      return list.isEmpty ? null : list.first;
    } finally {
      content = saved;
    }
  }

  /// java.getStringListByRules(rules, [text])：依次取非空列表（Legado 语义）
  List<String> getStringListByRules(List<dynamic> rules, [String? text]) {
    final saved = content;
    if (text != null) content = text;
    try {
      for (final r in rules) {
        if (r == null || r.toString().isEmpty) continue;
        final list = getStringList(r.toString());
        if (list.isNotEmpty) return list;
      }
      return [];
    } finally {
      content = saved;
    }
  }

  // ── 对称加密（AES/DES）────────────────────────────────────────

  // [PATCH-12] 改成 static：JS 的 `java` 是**全局对象**（JsEngine.shared

  // 进程级复用），句柄必须跨 AnalyzeRule 实例存活，否则第二次求值时

  // `_cryptoHandles[handle]` 查不到 ⇒ cryptoOp 静默返回空串。

  static final Map<int, _CryptoSpec> _cryptoHandles = {};
  // [PATCH-12] 与 _cryptoHandles 一起改 static：否则两个 AnalyzeRule 实例
  // 各自从 1 开始发号 ⇒ **句柄撞号**（后建的实例会覆盖前一个的 spec）。
  static int _cryptoSeq = 1;

  /// java.createSymmetricCrypto(algorithm, key, iv, mode) → 句柄
  /// algorithm 如 `AES/CBC/PKCS7Padding`、`AES/ECB/NoPadding`、`DES/CBC/PKCS5Padding`
  /// 返回 `{'__handle': id}`，后续调 java.cryptoOp(handle, op, data)。
  Map<String, int> createSymmetricCrypto(String algorithm, String key,
      [String? iv, dynamic mode]) {
    // [PATCH-14] iv 一并交给 _buildSpec 存进句柄（此前被丢弃）
    final spec = _buildSpec(algorithm, key, iv);
    final id = _cryptoSeq++;
    _cryptoHandles[id] = spec;
    return {'__handle': id};
  }

  /// java.crypto —— Rhino Java 互操作 polyfill 的 Dart 后端。
  /// JS 侧把 byte[] 用 base64 打包传参，返回 hex（摘要/HMAC）或 base64（AES）。
  /// 算法：MD5/SHA1/SHA256/SHA512、HmacMD5/SHA1/SHA256/SHA512、AES（ECB/CBC/CTR + PKCS7）。
  Object? _dispatchCryptoPolyfill(List<Object?> args) {
    String s(int i) => args.length > i && args[i] != null ? '${args[i]}' : '';
    Uint8List b(int i) => base64.decode(s(i));
    switch (s(0)) {
      case 'md5':
        return dkcrypto.md5.convert(b(1)).toString();
      case 'sha1':
        return dkcrypto.sha1.convert(b(1)).toString();
      case 'sha256':
        return dkcrypto.sha256.convert(b(1)).toString();
      case 'sha512':
        return dkcrypto.sha512.convert(b(1)).toString();
      case 'hmacmd5':
        return dkcrypto.Hmac(dkcrypto.md5, b(1)).convert(b(2)).toString();
      case 'hmacsha1':
        return dkcrypto.Hmac(dkcrypto.sha1, b(1)).convert(b(2)).toString();
      case 'hmacsha256':
        return dkcrypto.Hmac(dkcrypto.sha256, b(1)).convert(b(2)).toString();
      case 'hmacsha512':
        return dkcrypto.Hmac(dkcrypto.sha512, b(1)).convert(b(2)).toString();
      case 'aes':
        final mode = s(1);
        final encrypting = s(2) == 'encrypt';
        final key = dkenc.Key(b(3));
        final ivStr = s(4);
        final data = b(5);
        late final dkenc.Encrypter enc;
        dkenc.IV? iv;
        switch (mode) {
          case 'cbc':
          case 'cfb64':
            iv = dkenc.IV(ivStr.isEmpty ? Uint8List(16) : base64.decode(ivStr));
            enc = dkenc.Encrypter(
              dkenc.AES(key, mode: mode == 'cbc' ? dkenc.AESMode.cbc : dkenc.AESMode.cfb64),
            );
          case 'ctr':
            iv = dkenc.IV(ivStr.isEmpty ? Uint8List(16) : base64.decode(ivStr));
            enc = dkenc.Encrypter(dkenc.AES(key, mode: dkenc.AESMode.ctr));
          default: // ecb
            enc = dkenc.Encrypter(dkenc.AES(key, mode: dkenc.AESMode.ecb));
        }
        try {
          if (encrypting) {
            return base64.encode(enc.encryptBytes(data, iv: iv).bytes);
          }
          return base64.encode(enc.decryptBytes(dkenc.Encrypted(data), iv: iv));
        } catch (e) {
          throw Exception('java.crypto AES($mode ${encrypting ? '加密' : '解密'})失败: $e');
        }
    }
    throw Exception('java.crypto 不支持的操作: ${s(0)}');
  }

  /// java.cryptoOp(handle, op, data)
  /// op：Base64Decode / Base64Encode / HexDecode / HexEncode / String（原样）
  String cryptoOp(int handle, String op, String data) {
    final spec = _cryptoHandles[handle];
    if (spec == null) return '';
    try {
      final bytes = base64.decode(data);
      final dec = _decryptSpec(spec, bytes, null);
      switch (op) {
        case 'Base64Decode':
          // [FIX-CRYPTO-UTF8] 必须是 UTF-8：中文正文用 latin1 解会变 'ä½ å¥½ä¸ç'。
          // legado 的 `Base64Decode` 语义是 new String(bytes, UTF_8)。
          return utf8.decode(dec, allowMalformed: true);
        case 'HexDecode':
          return utf8.decode(dec, allowMalformed: true);
        case 'Base64Encode':
          return base64.encode(dec);
        case 'HexEncode':
          return dec.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
        default:
          return utf8.decode(dec, allowMalformed: true);
      }
    } catch (_) {
      return '';
    }
  }

  /// java.aesBase64DecodeToString(data, key, mode, iv)
  /// mode 如 `AES/CBC/PKCS7Padding`；key 可为 base64 或明文；iv 为空时用全零。
  String aesBase64DecodeToString(String data, String key,
      [String? mode, String? iv]) {
    try {
      final spec = _buildSpec(mode ?? 'AES/CBC/PKCS7Padding', key);
      final dec = _decryptSpec(spec, base64.decode(data), iv);
      return utf8.decode(dec, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  /// java.aesEncodeToString(data, key, mode, iv)
  ///
  /// legado 语义：明文 → AES 加密 → Base64 字符串。
  /// mode 如 `AES/CBC/PKCS7Padding`；key 可为 base64 或明文；iv 为空时补零。
  String aesEncodeToString(String data, String key,
      [String? mode, String? iv]) {
    try {
      final spec = _buildSpec(mode ?? 'AES/CBC/PKCS7Padding', key);
      final out = _encryptSpec(
          spec, Uint8List.fromList(utf8.encode(data)), iv);
      return base64.encode(out);
    } catch (_) {
      return '';
    }
  }

  /// java.desBase64DecodeToString(data, key, mode, iv)
  String desBase64DecodeToString(String data, String key,
      [String? mode, String? iv]) {
    try {
      final spec = _buildSpec(mode ?? 'DES/CBC/PKCS5Padding', key);
      final dec = _decryptSpec(spec, base64.decode(data), iv);
      return utf8.decode(dec, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  _CryptoSpec _buildSpec(String algorithm, String key, [String? iv]) {
    final upper = algorithm.toUpperCase();
    final parts = upper.split('/');
    final algo = parts.isNotEmpty ? parts[0] : 'AES';
    final useCbc = parts.length > 1 ? parts[1] == 'CBC' : true;
    final isDes = algo == 'DES' || algo == 'DESEDE' || algo == '3DES';
    final keyBytes = _decodeKeyBytes(key);
    // [PATCH-14] 句柄携带的 IV（空/未传 ⇒ null，解密时退回零 IV）
    final rawIv = (iv == null || iv.isEmpty) ? null : _decodeKeyBytes(iv);
    if (isDes) {
      final len = keyBytes.length == 8 ? 8 : (keyBytes.length >= 24 ? 24 : 16);
      return _CryptoSpec.des(
          _padKey(keyBytes, len), useCbc, rawIv == null ? null : _padIv(rawIv, 8));
    }
    final len = _aesKeyLen(keyBytes);
    return _CryptoSpec.aes(
        dkenc.Key(_padKey(keyBytes, len)),
        useCbc ? dkenc.AESMode.cbc : dkenc.AESMode.ecb,
        _normPadding(parts.length > 2 ? parts[2] : 'PKCS7'),
        rawIv == null ? null : _padIv(rawIv, 16));
  }

  static String? _normPadding(String p) {
    final up = p.toUpperCase();
    if (up == 'NOPADDING') return null;
    if (up == 'PKCS5PADDING' || up == 'PKCS7PADDING' || up == 'PKCS5' || up == 'PKCS7') {
      return 'PKCS7';
    }
    return up.isEmpty ? 'PKCS7' : up;
  }

  /// [PATCH-14] IV 来源优先级：**显式字符串参数** > 句柄里存的 `spec.iv` > 空（补零）。
  static Uint8List _resolveIv(_CryptoSpec spec, String? iv) {
    if (iv != null && iv.isNotEmpty) return _decodeKeyBytes(iv);
    if (spec.iv != null) return spec.iv!;
    return Uint8List(0);
  }

  List<int> _decryptSpec(_CryptoSpec spec, Uint8List bytes, String? iv) {
    if (spec.isDes) {
      // pointycastle 3.9 无单 DES 引擎：8 字节密钥复制 3 份交给
      // DESede（DES∘DES⁻¹∘DES = DES），16/24 字节直接用。
      final desKey = spec.keyBytes.length == 8
          ? Uint8List.fromList([...spec.keyBytes, ...spec.keyBytes, ...spec.keyBytes])
          : spec.keyBytes;
      final engine = DESedeEngine();
      final cipher = spec.cbc
          ? PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(engine))
          : PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(engine));
      if (spec.cbc) {
        final ivBytes = _padIv(_resolveIv(spec, iv), 8);
        final withIv = ParametersWithIV<KeyParameter>(KeyParameter(desKey), ivBytes);
        cipher.init(
            false,
            PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>,
                ParametersWithIV<KeyParameter>>(withIv, withIv));
      } else {
        cipher.init(
            false,
            PaddedBlockCipherParameters<KeyParameter, Null>(
                KeyParameter(desKey), null));
      }
      return _runBlockCipher(cipher, bytes);
    }
    final ivObj = spec.mode != dkenc.AESMode.ecb
        ? dkenc.IV(_padIv(_resolveIv(spec, iv), 16))
        : null;
    return dkenc.Encrypter(dkenc.AES(spec.key!, mode: spec.mode, padding: spec.padding))
        .decryptBytes(dkenc.Encrypted(bytes), iv: ivObj);
  }

  /// 加密（与 [_decryptSpec] 对称）：AES 走 encrypt 库，DES 走 pointycastle。
  List<int> _encryptSpec(_CryptoSpec spec, Uint8List bytes, String? iv) {
    if (spec.isDes) {
      final desKey = spec.keyBytes.length == 8
          ? Uint8List.fromList(
              [...spec.keyBytes, ...spec.keyBytes, ...spec.keyBytes])
          : spec.keyBytes;
      final engine = DESedeEngine();
      final cipher = spec.cbc
          ? PaddedBlockCipherImpl(PKCS7Padding(), CBCBlockCipher(engine))
          : PaddedBlockCipherImpl(PKCS7Padding(), ECBBlockCipher(engine));
      if (spec.cbc) {
        final ivBytes = _padIv(_resolveIv(spec, iv), 8);
        final withIv = ParametersWithIV<KeyParameter>(KeyParameter(desKey), ivBytes);
        cipher.init(
            true,
            PaddedBlockCipherParameters<ParametersWithIV<KeyParameter>,
                ParametersWithIV<KeyParameter>>(withIv, withIv));
      } else {
        cipher.init(
            true,
            PaddedBlockCipherParameters<KeyParameter, Null>(
                KeyParameter(desKey), null));
      }
      return _runBlockCipher(cipher, bytes);
    }
    final ivObj = spec.mode != dkenc.AESMode.ecb
        ? dkenc.IV(_padIv(_resolveIv(spec, iv), 16))
        : null;
    return dkenc.Encrypter(
            dkenc.AES(spec.key!, mode: spec.mode, padding: spec.padding))
        .encryptBytes(bytes, iv: ivObj)
        .bytes;
  }

  static List<int> _runBlockCipher(PaddedBlockCipherImpl cipher, Uint8List input) {
    // pointycastle 3.9 的 PaddedBlockCipherImpl.process 一步完成
    // 尾块 + padding 处理（内部 doFinal），解密直接返回明文字节。
    return cipher.process(input);
  }

  static int _aesKeyLen(Uint8List bytes) {
    if (bytes.length >= 32) return 32;
    if (bytes.length >= 24) return 24;
    return 16;
  }

  static Uint8List _padKey(Uint8List bytes, int len) {
    if (bytes.length >= len) return Uint8List.fromList(bytes.sublist(0, len));
    final out = Uint8List(len);
    for (var i = 0; i < len; i++) {
      out[i] = i < bytes.length ? bytes[i] : 0;
    }
    return out;
  }

  static Uint8List _padIv(Uint8List bytes, int len) {
    if (bytes.length >= len) return Uint8List.fromList(bytes.sublist(0, len));
    final out = Uint8List(len);
    for (var i = 0; i < len; i++) {
      out[i] = i < bytes.length ? bytes[i] : 0;
    }
    return out;
  }

  /// 密钥解码：**长度优先**（16/24/32 字符按明文），否则按 base64。
  ///
  /// 与 Legado 对齐：它先看 `key.getBytes().length` 是否为 AES 合法长度，
  /// 是就按明文；否则才 `Base64.decode`。以前这里**总是先试 base64**，
  /// 于是 16 位明文密钥（如 `1234567890abcdef`，恰好是合法 base64）被误解成
  /// 12 字节再补零 —— 加密/解密自己内部能对上，但与源站/Java 端不一致。
  static Uint8List _decodeKeyBytes(String s) {
    final t = s.trim();
    if (t.length == 16 || t.length == 24 || t.length == 32) {
      return Uint8List.fromList(utf8.encode(t));
    }
    try {
      return base64.decode(t);
    } catch (_) {
      return Uint8List.fromList(utf8.encode(t));
    }
  }

  // ── jsoup 句柄（org.jsoup 风格：java.jsoupParse(html).select(css)）──

  final Map<int, Element> _jsoupDocs = {};
  int _jsoupSeq = 1;

  Map<String, int> jsoupParse(String html) {
    final doc = html_parser.parse(html).documentElement;
    if (doc == null) return {'__handle': 0};
    final id = _jsoupSeq++;
    _jsoupDocs[id] = doc;
    return {'__handle': id};
  }

  /// java.jsoupSelect(handle, css) → 元素文本列表
  List<String> jsoupSelect(int handle, String css) {
    final root = _jsoupDocs[handle];
    if (root == null) return [];
    try {
      return root
          .querySelectorAll(css)
          .map((e) => e.text.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  /// java.jsoupSelectFirst(handle, css) → 首个元素文本
  String jsoupSelectFirst(int handle, String css) {
    final list = jsoupSelect(handle, css);
    return list.isEmpty ? '' : list.first;
  }

  List<SourceRule> splitSourceRule(String? ruleStr, {bool allInOne = false}) {
    if (ruleStr == null || ruleStr.isEmpty) return [];
    final ruleList = <SourceRule>[];
    Mode mMode = Mode.defaultMode;
    var start = 0;

    if (allInOne && ruleStr.startsWith(': ')) {
      mMode = Mode.regex;
      start = 1;
    }

    // 不再预分割 &&，让 AnalyzeByJsoup 内部处理 &&/||/%%
    final trimmed = ruleStr.substring(start).trim();
    if (trimmed.isEmpty) return [];

    // 处理 JS 模式
    final jsPattern = RegExp(r'<js>([\w\W]*?)</js>|@js:([\w\W]*)', caseSensitive: false);
    final matches = jsPattern.allMatches(trimmed).toList();

    if (matches.isEmpty) {
      ruleList.add(SourceRule(trimmed, mMode, isJson));
    } else {
      var segStart = 0;
      for (final match in matches) {
        if (match.start > segStart) {
          final tmp = trimmed.substring(segStart, match.start).trim();
          if (tmp.isNotEmpty) {
            ruleList.add(SourceRule(tmp, mMode, isJson));
          }
        }
        final jsContent = match.group(2) ?? match.group(1) ?? '';
        ruleList.add(SourceRule(jsContent, Mode.js, isJson));
        segStart = match.end;
      }
      if (trimmed.length > segStart) {
        final tmp = trimmed.substring(segStart).trim();
        if (tmp.isNotEmpty) {
          ruleList.add(SourceRule(tmp, mMode, isJson));
        }
      }
    }

    return ruleList;
  }

  String _getStringFromRules(List<SourceRule> ruleList, {bool unescape = true, bool isUrl = false, dynamic mContent}) {
    if (ruleList.isEmpty) return '';
    var result = mContent ?? content;
    if (result != null && ruleList.isNotEmpty) {
      for (final sourceRule in ruleList) {
        _putAll(sourceRule.putMap);
        final st = _makeUpRule(sourceRule, result);
        if (result == null) continue;
        if (st.rule.isNotEmpty || st.replaceRegex.isEmpty) {
          if (st.templateMode) {
            // 模板模式：内嵌表达式替换后的整串即结果。
            result = st.rule;
          } else {
            result = _executeRule(result, sourceRule.mode, st.rule, isUrl: isUrl);
          }
        }
        if (result != null && st.replaceRegex.isNotEmpty) {
          result = _replaceRegex(result.toString(), st);
        }
      }
    }
    result ??= '';
    var resultStr = result.toString();
    if (unescape && resultStr.contains('&')) {
      resultStr = _unescapeHtml(resultStr);
    }
    if (isUrl) {
      if (resultStr.trim().isEmpty) {
        return baseUrl ?? '';
      }
      return _getAbsoluteUrl(resultStr);
    }
    return resultStr;
  }

  List<String> _getStringListFromRules(List<SourceRule> ruleList, {bool isUrl = false}) {
    if (ruleList.isEmpty) return [];
    var result = content;
    if (content != null && ruleList.isNotEmpty) {
      for (final sourceRule in ruleList) {
        _putAll(sourceRule.putMap);
        final st = _makeUpRule(sourceRule, result);
        if (result == null) continue;
        if (st.rule.isNotEmpty || st.replaceRegex.isEmpty) {
          if (st.templateMode) {
            result = st.rule;
          } else {
            result = _executeRule(result, sourceRule.mode, st.rule, isUrl: isUrl);
          }
        }
        if (result != null && st.replaceRegex.isNotEmpty) {
          if (result is List) {
            result = result.map((o) => _replaceRegex(o.toString(), st)).toList();
          } else {
            result = _replaceRegex(result.toString(), st);
          }
        }
      }
    }
    if (result == null) return [];
    if (result is String) {
      return result.split('\n').where((s) => s.isNotEmpty).toList();
    }
    if (result is List) {
      return result.map((e) => e.toString()).toList();
    }
    return [result.toString()];
  }

  List<dynamic> _getElementsFromRules(List<SourceRule> ruleList) {
    if (ruleList.isEmpty) return [];
    var result = content;

    for (final sourceRule in ruleList) {
      _putAll(sourceRule.putMap);
      result = _executeRuleElements(result, sourceRule);
      if (result == null) continue;
    }

    if (result == null) return [];
    if (result is List) return result;
    return [];
  }

  dynamic _executeRule(dynamic result, Mode mode, String rule, {bool isUrl = false}) {
    switch (mode) {
      case Mode.js:
        return _evalJs(rule, result);
      case Mode.regex:
        return rule;
      case Mode.json:
        final analyzer = _getJsonAnalyzer(result);
        return analyzer.getString(rule);
      case Mode.xpath:
        final analyzer = _getXPathAnalyzer(result);
        return analyzer.getString(rule);
      case Mode.defaultMode:
        final analyzer = _getJsoupAnalyzer(result);
        if (isUrl) {
          return analyzer.getString0(rule);
        }
        return analyzer.getString(rule);
    }
  }

  dynamic _executeRuleElements(dynamic result, SourceRule sourceRule, {bool single = false}) {
    final st = _makeUpRule(sourceRule, result);
    final rule = st.rule;

    switch (sourceRule.mode) {
      case Mode.js:
        final jsResult = _evalJs(rule, result, raw: true);
        // single（getElement / bookInfoInit）：JS 可以返回任意类型，
        // 官方就是把返回值直接 setContent —— 例如 init 的 `{a:'书名'}`。
        // 以前一律返回 [] ⇒ init 的 JS 结果被丢弃，详情页字段全空。
        if (single) return jsResult;
        if (jsResult is List) return jsResult;
        // 列表规则里 JS 返回单个对象：包一层，别静默丢数据
        if (jsResult is Map) return [jsResult];
        // 有些脚本会返回「JSON 字符串」而不是数组/对象（`JSON.stringify(...)`
        // 或接口原始文本），这里解析一次，避免直接判空导致「没有返回任何章节」。
        if (jsResult is String) {
          final t = jsResult.trim();
          if (t.startsWith('[') || t.startsWith('{')) {
            try {
              final decoded = jsonDecode(t);
              if (decoded is List) return decoded;
              if (decoded is Map) return [decoded];
            } catch (_) {
              // 不是合法 JSON ⇒ 按普通字符串规则处理
            }
          }
        }
        return [];
      case Mode.regex:
        if (result is String) {
          return AnalyzeByRegex.getElements(result, rule);
        }
        return [];
      case Mode.json:
        final analyzer = _getJsonAnalyzer(result);
        // single（getElement/init 规则）：返回对象本身；列表规则返回元素数组。
        return single ? analyzer.getObject(rule) : analyzer.getList(rule);
      case Mode.xpath:
        final analyzer = _getXPathAnalyzer(result);
        return analyzer.getElements(rule);
      case Mode.defaultMode:
        final analyzer = _getJsoupAnalyzer(result);
        return analyzer.getElements(rule);
    }
  }

  AnalyzeByJsoup _getJsoupAnalyzer(dynamic content) {
    if (_analyzeByJsoup == null || _analyzeByJsoup!.content != content) {
      _analyzeByJsoup = AnalyzeByJsoup(content);
    }
    return _analyzeByJsoup!;
  }

  AnalyzeByXPath _getXPathAnalyzer(dynamic content) {
    if (_analyzeByXPath == null || _analyzeByXPath!.content != content) {
      _analyzeByXPath = AnalyzeByXPath(content);
    }
    return _analyzeByXPath!;
  }

  AnalyzeByJson _getJsonAnalyzer(dynamic content) {
    if (_analyzeByJson == null || _analyzeByJson!.content != content) {
      _analyzeByJson = AnalyzeByJson(content);
    }
    return _analyzeByJson!;
  }

  dynamic _evalJs(String jsStr, dynamic result,
      {Map<String, dynamic>? extraBindings, bool raw = false}) {
    try {
      _jsEngine ??= JsEngine.shared;
      final expanded = _expandJavaBridge(jsStr);
      // [PATCH-5] 同步重放：legado 的 `java.ajax` 需要**同步**拿到响应体，
      // 而 Dart 常规 HTTP 是异步的。协议见 sync_http_bridge.dart：
      //   JS 查注入的 httpCache → 未命中 throw '__LEGADO_NEED__{...}'
      //   → 本处解析（JsEngine.lastError）→ SyncHttpClient 同步抓取
      //   → 写入 httpCache → 重新 eval。
      // [PATCH-7] 同一套协议再接管**宿主调用**（host_bridge.dart）：
      //   java.getString/get/md5Encode/… 与 source.* → throw '__LEGADO_CALL__{k,o,a}'
      //   → _dispatchHostCall 执行 → 写 hostCache → 重新 eval。
      // 每轮只处理**一个**未命中调用，故轮数上限设为 8（含多个 java.xxx 的脚本要多轮）；
      // 已按 `op+参数` / `URL+方法+body` 缓存，重复调用不会重复执行。
      // ⚠️ ①的同步抓取会阻塞当前 isolate ⇒ 书源求值必须跑在 worker isolate 里
      //    （对应上游 web_book/runner_pool + killable_isolate 的语义）。
      for (var round = 0; round < 8; round++) {
        final bindings = <String, dynamic>{
          // [PATCH-5] 不再绑定 `'java': this` —— 经 _toJsValue 兜底后 JS 里的
          // `java` 只是字符串 "Instance of 'AnalyzeRule'"，任何 java.xxx()
          // 调用都是 TypeError，被 JsEngine.eval 捕获后**静默返回空串**。
          // `java`/`source` 现由 JsEngine 注入的纯 JS 宿主对象提供
          // （legado_java_prelude.dart）。
          'result': result,
          'baseUrl': baseUrl ?? '',
          'src': content?.toString() ?? '',
          'title': chapter?.title ?? '',
          // 同步 HTTP 桥的响应缓存（key → 响应体字符串 / {'__error': msg}）
          'httpCache': SyncHttpBridge.instance.cache,
          // [PATCH-7] 宿主调用结果缓存（key → 结果 / {'__error': msg}）
          'hostCache': HostBridge.instance.cache,
          if (extraBindings != null) ...extraBindings,
        };
        final evalRes = _jsEngine!.evalResult(expanded, bindings: bindings);
        final lastError = _jsEngine!.lastError;
        // ① 同步 HTTP（java.ajax/get/post/…）
        final need = SyncHttpBridge.pendingRequest(lastError);
        if (need != null) {
          AppLog.instance.d(
              '[书源JS] 同步抓取(${round + 1}/8): ${need.method} ${need.url}');
          SyncHttpBridge.instance.fetch(need);
          continue;
        }
        // ② 宿主调用（java.getString/md5Encode/… 与 source.*）
        final call = HostBridge.pendingCall(lastError);
        if (call != null) {
          AppLog.instance.d('[书源JS] 宿主调用(${round + 1}/8): ${call.op}');
          HostBridge.instance.cache[call.key] ??=
              HostBridge.normalize(_dispatchHostCall(call.op, call.args));
          continue;
        }
        if (evalRes == null || evalRes.isError) {
          return raw ? null : '';
        }
        if (raw) return evalRes.rawResult;
        // 数组/对象结果：`stringResult` 是 Dart 的 `[a, b]` / `{k: v}` 形态，
        // 既不是合法 JSON、也没法按行切分 ⇒ 漫画/小说 `@js` 返回图片或
        // 段落数组时会被调用方当成 1 条坏数据（症状：正文 0 图）。
        // 列表按行拼接（调用方 `split('\n')` 即得到原数组元素），对象转 JSON。
        final rawVal = evalRes.rawResult;
        if (rawVal is List) {
          return rawVal
              .map((e) => e == null ? '' : '$e')
              .where((s) => s.isNotEmpty)
              .join('\n');
        }
        if (rawVal is Map) {
          try {
            return jsonEncode(rawVal);
          } catch (_) {
            // 含不可编码值时退回字符串形态
          }
        }
        var out = evalRes.stringResult;
        if (out == 'null' || out == 'undefined') out = '';
        // ── 🔴 失败必须可见（修"静默空串"）──────────────────────────
        //
        // 原实现：走到这里就 `return out`，而 `out` 可能是空串 ——
        // 此时 `lastError` 里的**真实原因被完全丢掉** ✗ ⇒
        // 日志里既没有报错、结果又是空，于是：
        //   · "JS 引擎根本不可用"（如原生库没加载上）
        //   · "规则语法错误 / 找不到变量"
        //   · "规则正常但确实没匹配到内容"
        // 这三件事**看起来一模一样** ✗✗
        //
        // 代价是实测出来的：曾把"缺 quickjs 原生库导致所有 @js 返回空"
        // 误判成"某条 @js 规则没被求值"，白查很久。
        //
        // 现在：**只要 JS 报了错且结果为空，就写一条 warn**（附带规则片段）。
        // ⚠️ 只加日志、**不改返回值**（返回空串维持既有行为，避免影响调用方）。
        if (out.isEmpty && lastError != null && lastError.isNotEmpty) {
          final brief = expanded.replaceAll('\n', ' ').trim();
          AppLog.instance.w('[书源JS] 求值失败，返回空串: '
              '${brief.length > 120 ? '${brief.substring(0, 120)}…' : brief} '
              '→ $lastError');
        }
        // 整数结果带 .0（QuickJS 按 double 返回）时规整，避免 URL 拼接出错。
        if (out.length > 2 && RegExp(r'^-?\d+\.0+$').hasMatch(out)) {
          out = out.substring(0, out.indexOf('.'));
        }
        return out;
      }
      AppLog.instance.w('[书源JS] 宿主调用/同步抓取重放超过 8 轮，放弃');
      return '';
    } catch (e) {
      // JS 引擎调用本身抛异常（极少见）时记录到运行日志，便于真机排查
      // 「书源 JS 规则不生效」。失败返回空串维持既有行为。
      final brief = jsStr.replaceAll('\n', ' ').trim();
      AppLog.instance.w('[书源JS] 调用异常: '
          '${brief.length > 120 ? '${brief.substring(0, 120)}…' : brief} → $e');
      return '';
    }
  }

  // ══════════ [PATCH-7] 宿主调用分发（与 host_bridge.dart 协议成对）══════════

  /// 执行一次 JS 侧抛出的宿主调用，返回值会被注入回 JS。
  ///
  /// 覆盖实测 224 条内置书源中 475 次 `java.*` 调用的绝大多数：
  /// `getString`(122)、`get`/`put`（在 JS 侧实现）、`getElements`(9)、
  /// `getElement`(7)、`md5Encode`(6)、`toNumChapter`(9)、`encodeURI`(5)、
  /// `timeFormatUTC`(3)、`bytesToStr`(3)、`setContent`(3)、`copyText`(4)…
  /// 以及 `source.*` 9 种成员（`getVariable`/`setVariable`/`getKey`/…）。
  ///
  /// ⚠️ 返回值必须 JSON 可编码（会经 `JsEngine._toJsValue` 注入 JS）；
  /// 不可编码的（如 DOM 元素）须先转成普通结构（见 [_elementPayload]）。
  Object? _dispatchHostCall(String op, List<Object?> args) {
    final a0 = (args.isNotEmpty && args[0] != null) ? '${args[0]}' : '';
    switch (op) {
      case 'getString':
        // legado: java.getString(rule) / java.getString(rule, content)
        return getString(a0, mContent: args.length > 1 ? args[1] : null);
      case 'getStringList':
        return getStringList(a0);
      case 'getElement':
        return _elementPayload(getElement(a0));
      case 'getElements':
        return getElements(a0).map(_elementPayload).toList();
      case 'setContent':
        setContent(args.isNotEmpty ? args[0] : null);
        return true;
      case 'md5Encode':
        return md5Encode(a0);
      case 'md5Encode16':
        return md5Encode16(a0);
      case 'encodeURI':
        return _legadoEncodeUri(a0);
      case 'bytesToStr':
        return _bytesToStr(a0);
      case 'toNumChapter':
        return _toNumChapter(a0);
      case 'timeFormatUTC':
        return _timeFormatUtc(args);
      // ── [PATCH-12] 对称加密（句柄通道；实测 10 次调用）──
      case 'createSymmetricCrypto':
        // 返回 {'__handle': id}（与 Dart 侧既有契约一致），JS 侧取 __handle 用
        return createSymmetricCrypto(
          a0,
          args.length > 1 && args[1] != null ? '${args[1]}' : '',
          args.length > 2 && args[2] != null ? '${args[2]}' : null,
          args.length > 3 ? args[3] : null,
        );
      case 'cryptoOp':
        return cryptoOp(
          args.isNotEmpty && args[0] is num
              ? (args[0] as num).toInt()
              : (int.tryParse(a0) ?? -1),
          args.length > 1 ? '${args[1]}' : '',
          args.length > 2 ? '${args[2]}' : '',
        );
      // ── Rhino Java 互操作 polyfill 后端（javax.crypto / MessageDigest）──
      case 'java.crypto':
        return _dispatchCryptoPolyfill(args);
      case 'aesBase64DecodeToString':
        return aesBase64DecodeToString(
          a0,
          args.length > 1 ? '${args[1]}' : '',
          args.length > 2 && args[2] != null ? '${args[2]}' : null,
          args.length > 3 && args[3] != null ? '${args[3]}' : null,
        );
      case 'aesEncodeToString':
        return aesEncodeToString(
          a0,
          args.length > 1 ? '${args[1]}' : '',
          args.length > 2 && args[2] != null ? '${args[2]}' : null,
          args.length > 3 && args[3] != null ? '${args[3]}' : null,
        );
      case 'desBase64DecodeToString':
        return desBase64DecodeToString(
          a0,
          args.length > 1 ? '${args[1]}' : '',
          args.length > 2 && args[2] != null ? '${args[2]}' : null,
          args.length > 3 && args[3] != null ? '${args[3]}' : null,
        );
      case 'copyText':
        AppLog.instance.d('[书源JS] java.copyText: $a0');
        return true;
      case 'open':
        AppLog.instance.w('[书源JS] java.open($a0) —— 宿主未接 UI（P2）');
        return true;
    }
    if (op.startsWith('cookie.')) {
      return _dispatchCookieCall(op.substring('cookie.'.length), args);
    }
    if (op.startsWith('source.')) {
      return _dispatchSourceCall(op.substring('source.'.length), args);
    }
    return HostBridge.unsupported(op);
  }

  /// `cookie.*`（legado 的 CookieStore 全局对象；实测 4 处用法）。
  ///
  /// 对应 `cookie.getCookie(url)` / `cookie.setCookie(url, raw)` /
  /// `cookie.getKey(url)` / `cookie.removeCookie(url, name)`。
  Object? _dispatchCookieCall(String member, List<Object?> args) {
    final url = (args.isNotEmpty && args[0] != null) ? '${args[0]}' : '';
    switch (member) {
      case 'getCookie':
        return SourceCookieStore.instance.getCookie(url);
      case 'setCookie':
        SourceCookieStore.instance
            .setCookie(url, args.length > 1 ? '${args[1]}' : '');
        return true;
      case 'getKey':
        return SourceCookieStore.instance.getKey(url);
      case 'removeCookie':
        SourceCookieStore.instance.removeCookie(url,
            args.length > 1 && args[1] != null ? '${args[1]}' : null);
        return true;
    }
    return HostBridge.unsupported('cookie.$member');
  }

  /// `source.*`（书源级变量与身份）。
  Object? _dispatchSourceCall(String member, List<Object?> args) {
    switch (member) {
      case 'getVariable':
        return _sourceVariables['__value__'] ?? '';
      case 'setVariable':
        _sourceVariables['__value__'] =
            args.isEmpty || args[0] == null ? '' : '${args[0]}';
        return true;
      case 'putConcurrent':
        if (args.length >= 2) {
          _sourceVariables['${args[0]}'] = '${args[1]}';
        }
        return true;
      case 'getLoginInfo':
        return _sourceVariables['__login__'] ?? '';
      case 'putLoginInfo':
        _sourceVariables['__login__'] =
            args.isEmpty || args[0] == null ? '' : '${args[0]}';
        return true;
      case 'removeLoginInfo':
        _sourceVariables.remove('__login__');
        return true;
      // ── 登录请求头（部分源把登录态放在 header 而不是 cookie）──
      case 'getLoginHeader':
        return _sourceVariables['__loginHeader__'] ?? '';
      case 'putLoginHeader':
        _sourceVariables['__loginHeader__'] =
            args.isEmpty || args[0] == null ? '' : '${args[0]}';
        return true;
      case 'removeLoginHeader':
        _sourceVariables.remove('__loginHeader__');
        return true;
      case 'putVariable':
        _sourceVariables['__value__'] =
            args.isEmpty || args[0] == null ? '' : '${args[0]}';
        return true;
      case 'getKey':
        if (bookSourceUrl != null && bookSourceUrl!.isNotEmpty) {
          return bookSourceUrl!;
        }
        return baseUrl ?? '';
      case 'bookSourceUrl':
        return bookSourceUrl ?? '';
      case 'bookSourceComment':
        return bookSourceComment ?? '';
      case 'header':
        // 书源默认请求头（P2：接入书源定义后返回真实 header 表）
        return '';
    }
    return HostBridge.unsupported('source.$member');
  }

  /// 把 HTML 元素序列化成 JS 侧可包装的结构 `{t,h,a}`：
  /// `t`=文本、`h`=outerHtml、`a`=属性表。JS 的 `_wrapElement` 据此提供
  /// `text()/html()/outerHtml()/attr(n)/hasAttr(n)` 等 legado 方法面。
  Map<String, Object?>? _elementPayload(dynamic el) {
    if (el == null) return null;
    if (el is Element) {
      return {
        't': el.text.trim(),
        'h': el.outerHtml,
        'a': el.attributes.map((k, v) => MapEntry('$k', '$v')),
      };
    }
    return {'t': '$el', 'h': '$el', 'a': <String, String>{}};
  }

  /// legado `java.encodeURI`：非 ASCII 字符按 UTF-8 百分号编码，
  /// ASCII 可见字符**原样保留**（含 URL 保留字 —— 这是 `encodeURI` 语义，
  /// 区别于 `encodeURIComponent`）。
  String _legadoEncodeUri(String s) {
    final buf = StringBuffer();
    for (final rune in s.runes) {
      if (rune >= 0x21 && rune <= 0x7E) {
        buf.writeCharCode(rune);
      } else {
        for (final b in utf8.encode(String.fromCharCode(rune))) {
          buf.write('%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
        }
      }
    }
    return buf.toString();
  }

  /// legado `java.bytesToStr`：十六进制串 / 字节数组 → UTF-8 文本。
  ///
  /// `java.getByteArray(url)` 返回的是 JS 字节数组，经宿主协议变成
  /// `"12,34,56"` 这种逗号串 —— 这里一并识别，避免按 hex 解出乱码。
  String _bytesToStr(String s) {
    final bytes = <int>[];
    final csv = s.trim();
    if (csv.contains(',')) {
      for (final p in csv.split(',')) {
        final v = int.tryParse(p.trim());
        if (v == null) {
          bytes.clear();
          break;
        }
        bytes.add(v & 255);
      }
      if (bytes.isNotEmpty) return _decodeUtf8Bytes(bytes);
    }
    final hex = s.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '');
    for (var i = 0; i + 1 < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    if (bytes.isEmpty) return '';
    return _decodeUtf8Bytes(bytes);
  }

  static String _decodeUtf8Bytes(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// legado `java.toNumChapter`：从章节名提取章节序号（支持中文数字）。
  ///
  /// ⚠️ 这是**近似实现**：先累积中文数字（十/百/千/万），若串中出现阿拉伯数字
  /// 则优先返回第一段连续阿拉伯数字；两者都没有返回空串。
  /// （未逐字对齐 legado 的实现，若某源结果不对，请以该源的实际期望值为准调整。）
  String _toNumChapter(String s) {
    if (s.isEmpty) return '';
    const cn = <String, int>{
      '零': 0, '〇': 0, '一': 1, '二': 2, '两': 2, '三': 3, '四': 4,
      '五': 5, '六': 6, '七': 7, '八': 8, '九': 9,
    };
    final arabic = StringBuffer();
    var total = 0, section = 0, number = 0, found = false;
    for (final ch in s.split('')) {
      final unit = ch.codeUnitAt(0);
      if (cn.containsKey(ch)) {
        found = true;
        number = cn[ch]!;
      } else if (ch == '十') {
        found = true;
        section += (number == 0 ? 1 : number) * 10;
        number = 0;
      } else if (ch == '百') {
        found = true;
        section += (number == 0 ? 1 : number) * 100;
        number = 0;
      } else if (ch == '千') {
        found = true;
        section += (number == 0 ? 1 : number) * 1000;
        number = 0;
      } else if (ch == '万') {
        found = true;
        total = (total + section + number) * 10000;
        section = 0;
        number = 0;
      } else if (unit >= 0x30 && unit <= 0x39) {
        found = true;
        arabic.write(ch);
      }
    }
    if (arabic.isNotEmpty) return arabic.toString();
    if (!found) return '';
    return '${total + section + number}';
  }

  /// legado `java.timeFormatUTC(time, format, sh?)`：按 UTC 格式化，
  /// 第三参 `sh` 为额外时区偏移（小时）。
  String _timeFormatUtc(List<Object?> args) {
    final ts = args.isNotEmpty && args[0] != null
        ? int.tryParse('${args[0]}')
        : null;
    if (ts == null) return '';
    final fmt = (args.length > 1 && args[1] != null)
        ? '${args[1]}'
        : 'yyyy-MM-dd HH:mm:ss';
    final offsetHours =
        args.length > 2 && args[2] != null ? (int.tryParse('${args[2]}') ?? 0) : 0;
    final d = DateTime.fromMillisecondsSinceEpoch(ts, isUtc: true)
        .add(Duration(hours: offsetHours));
    String p2(int n) => n < 10 ? '0$n' : '$n';
    return fmt
        .replaceAll('yyyy', '${d.year}')
        .replaceAll('MM', p2(d.month))
        .replaceAll('dd', p2(d.day))
        .replaceAll('HH', p2(d.hour))
        .replaceAll('mm', p2(d.minute))
        .replaceAll('ss', p2(d.second));
  }

  String evalJs(String jsStr, dynamic result, {Map<String, dynamic>? extraBindings}) {
    return _evalJs(jsStr, result, extraBindings: extraBindings);
  }

  // ── 内嵌表达式（{{...}} / @get:{...}）求值期替换 ──

  /// 内嵌表达式与变量引用的切分模式（对齐通用书源格式语义）。
  static final RegExp _evalPattern = RegExp(
    r'@get:\{[^}]+?\}|\{\{[\w\W]*?\}\}',
    caseSensitive: false,
  );

  /// 计算规则的生效状态：替换 `{{...}}` 内嵌表达式与 `@get:{...}` 变量
  /// 引用后，再分割 `##` 正则替换段。
  ///
  /// 不修改缓存的 [SourceRule]（规则列表按规则串缓存、跨元素复用），
  /// 每次求值返回独立的生效状态。
  _RuleState _makeUpRule(SourceRule sourceRule, dynamic result) {
    if (!sourceRule.hasInnerRule) {
      return _RuleState(
        sourceRule.rule,
        sourceRule.replaceRegex,
        sourceRule.replacement,
        sourceRule.replaceFirst,
        sourceRule.templateMode,
      );
    }
    final replaced = _replaceInnerRules(sourceRule.rawRule, result);
    final parts = replaced.split('##');
    if (parts.length == 1) {
      // 内嵌表达式替换后同样要认单 `#` 正则替换（与 SourceRule 判据一致）。
      final single = SourceRule.splitSingleHashReplacement(replaced);
      if (single != null) {
        return _RuleState(
            single.$1, single.$2, single.$3, single.$4, sourceRule.templateMode);
      }
    }
    return _RuleState(
      parts[0].trim(),
      parts.length > 1 ? parts[1] : '',
      parts.length > 2 ? parts[2] : '',
      parts.length > 3,
      sourceRule.templateMode,
    );
  }

  /// 替换规则串中的全部内嵌表达式：
  /// - `@get:{key}` → 变量取值；
  /// - `{{规则}}`（`@`/`$.`/`$[`/`//` 开头）→ 按规则对当前内容求值；
  /// - `{{JS 表达式}}` → JS 求值（绑定 result/baseUrl 等宿主上下文）。
  String _replaceInnerRules(String ruleStr, dynamic result) {
    return ruleStr.replaceAllMapped(_evalPattern, (m) {
      final token = m.group(0)!;
      if (token.length > 6 &&
          token.substring(0, 5).toLowerCase() == '@get:') {
        final key = token.substring(6, token.length - 1);
        return get(key);
      }
      final expr = token.substring(2, token.length - 2).trim();
      if (_isRuleExpr(expr)) {
        return getString(expr);
      }
      return _formatJsNumberText(_evalJs(expr, result));
    });
  }

  /// 内嵌表达式是否为规则（而非 JS 表达式）。
  static bool _isRuleExpr(String expr) {
    return expr.startsWith('@') ||
        expr.startsWith('\$.') ||
        expr.startsWith('\$[') ||
        expr.startsWith('//');
  }

  /// JS 数值结果整型化：引擎把整数算式结果返回为 `19.0` 形式时去掉
  /// 小数位（URL 分页偏移等场景不能带 `.0`）。
  static String _formatJsNumberText(String s) {
    if (s.length > 2 && RegExp(r'^-?\d+\.0+$').hasMatch(s)) {
      return s.substring(0, s.indexOf('.'));
    }
    return s;
  }

  // ── 宿主桥接调用展开 ──

  static final RegExp _javaGetStringSingle =
      RegExp(r"java\.getString\(\s*'([^']*)'\s*\)");
  static final RegExp _javaGetStringDouble =
      RegExp(r'java\.getString\(\s*"([^"]*)"\s*\)');
  static final RegExp _javaGetSingle =
      RegExp(r"java\.get\(\s*'([^']*)'\s*\)");
  static final RegExp _javaGetDouble =
      RegExp(r'java\.get\(\s*"([^"]*)"\s*\)');

  /// 宿主桥接调用展开：JS 沙箱无法直接暴露宿主对象，通用书源常见的
  /// `java.getString('规则')` / `java.get('变量')` 调用在求值前由宿主
  /// 内联为求值结果（JSON 字符串字面量，转义兼容 JS 语法）。
  String _expandJavaBridge(String jsExpr) {
    if (!jsExpr.contains('java.')) return jsExpr;
    var out = jsExpr;
    out = out.replaceAllMapped(
        _javaGetStringSingle, (m) => jsonEncode(getString(m.group(1) ?? '')));
    out = out.replaceAllMapped(
        _javaGetStringDouble, (m) => jsonEncode(getString(m.group(1) ?? '')));
    out = out.replaceAllMapped(
        _javaGetSingle, (m) => jsonEncode(get(m.group(1) ?? '')));
    out = out.replaceAllMapped(
        _javaGetDouble, (m) => jsonEncode(get(m.group(1) ?? '')));
    return out;
  }

  String _replaceRegex(String result, _RuleState st) {
    if (st.replaceRegex.isEmpty) return result;
    try {
      final regex = RegExp(st.replaceRegex);
      String expand(Match m) => _expandReplacement(m, st.replacement);
      if (st.replaceFirst) {
        return result.replaceFirstMapped(regex, expand);
      }
      return result.replaceAllMapped(regex, expand);
    } catch (_) {
      try {
        if (st.replaceFirst) {
          final index = result.indexOf(st.replaceRegex);
          if (index >= 0) {
            return result.substring(0, index) +
                st.replacement +
                result.substring(index + st.replaceRegex.length);
          }
          return '';
        }
        return result.replaceAll(st.replaceRegex, st.replacement);
      } catch (_) {
        return result;
      }
    }
  }

  /// 展开 `##` 正则替换中的 `$1`..`$9` 分组引用（`$0` 为整串）。
  /// Dart 的字符串替换不展开 `$N`，须显式映射。
  static String _expandReplacement(Match m, String replacement) {
    if (!replacement.contains(r'$')) return replacement;
    return replacement.replaceAllMapped(RegExp(r'\$(\d)'), (rm) {
      final idx = int.parse(rm.group(1)!);
      if (idx == 0) return m.group(0) ?? '';
      if (idx <= m.groupCount) return m.group(idx) ?? '';
      return '';
    });
  }

  String _getAbsoluteUrl(String url) {
    if (url.isEmpty) return baseUrl ?? '';
    if (url.startsWith('http')) return url;
    if (baseUrl == null || baseUrl!.isEmpty) return url;
    try {
      final base = Uri.parse(baseUrl!);
      return base.resolve(url).toString();
    } catch (_) {
      return url;
    }
  }

  String _unescapeHtml(String str) {
    return str
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&nbsp;', ' ');
  }

  bool _isJsonString(String str) {
    final trimmed = str.trim();
    return (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
        (trimmed.startsWith('[') && trimmed.endsWith(']'));
  }

  void _putAll(Map<String, String> map) {
    for (final entry in map.entries) {
      put(entry.key, getString(entry.value));
    }
  }
}

/// 规则求值期的生效状态：[SourceRule] 的规则串经内嵌表达式替换、
/// `##` 正则替换段分割后的最终形态。
class _RuleState {
  final String rule;
  final String replaceRegex;
  final String replacement;
  final bool replaceFirst;
  final bool templateMode;

  _RuleState(this.rule, this.replaceRegex, this.replacement, this.replaceFirst,
      this.templateMode);
}

/// 对称加密规格（java.createSymmetricCrypto 句柄背后）。
class _CryptoSpec {
  final bool isDes;
  final Uint8List keyBytes;
  final bool cbc;
  final dkenc.Key? key;
  final dkenc.AESMode mode;
  final String? padding;

  /// [PATCH-14] 句柄里携带的 IV（已按算法补零到 8/16 字节）。
  /// 此前 `createSymmetricCrypto` 的 `iv` 参数被丢弃、`cryptoOp` 恒传
  /// `iv=null` ⇒ 句柄路径永远是零 IV。
  final Uint8List? iv;

  const _CryptoSpec.des(this.keyBytes, this.cbc, [this.iv])
      : isDes = true,
        key = null,
        mode = dkenc.AESMode.cbc,
        padding = null;

  _CryptoSpec.aes(this.key, this.mode, this.padding, [this.iv])
      : isDes = false,
        keyBytes = Uint8List(0),
        cbc = true;
}
