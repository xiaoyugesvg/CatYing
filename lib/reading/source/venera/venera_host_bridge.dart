/// Venera `ComicSource` 兼容层 —— Dart 宿主桥。
///
/// JS 侧（`venera_js_prelude.dart`）通过 `sendMessage('venera', json)` 把
/// `{method: ...}` 交给这里。返回值直接由 `_dartToJs` 转成 JS 值：
///   · `Map` / `List` / `Uint8List` → 普通对象 / 数组 / ArrayBuffer
///   · `Future<T>` → JS Promise（网络请求走这条，不阻塞 UI）
///
/// 能力范围：
///   convert  —— utf8/base64/gbk/gzip/md5/sha1/sha256/sha512/hmac/aes-*
///   html     —— package:html 同步解析 + CSS 选择器（元素用 id 句柄引用）
///   storage  —— SharedPreferences（load_data/save_data/delete_data/load_setting）
///   cookie   —— 按 host 的内存 CookieJar
///   http     —— Dio（走全局代理；自动识别 GBK；自动回写 Set-Cookie）
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:encrypt/encrypt.dart' as enc;
import 'package:flutter/foundation.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:shared_preferences/shared_preferences.dart';

import '../global_proxy.dart';

const String _kDefaultUa =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
    'Mobile/15E148 Safari/604.1';

/// 单个 Venera 源实例的宿主桥。
class VeneraHostBridge {
  VeneraHostBridge({
    required this.sourceKey,
    required this.prefs,
    this.onToast,
    this.onLaunchUrl,
  });

  final String sourceKey;
  final SharedPreferences prefs;
  final void Function(String message)? onToast;
  final void Function(String url)? onLaunchUrl;

  late final Dio _dio = _createDio();

  static Dio _createDio() {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 30),
        sendTimeout: const Duration(seconds: 30),
        responseType: ResponseType.bytes,
        followRedirects: true,
        validateStatus: (_) => true,
      ),
    );
    // 与漫画源/书源一致：未配单源代理时回退「通用设置 → 网络代理」
    applyGlobalProxy(dio);
    return dio;
  }

  // ── HTML 句柄表（LinkedHashMap + 上限淘汰，避免长会话内存膨胀）──
  static const int _maxNodes = 20000;
  // 文档本身也限量：源脚本每抓一页就 new HtmlDocument，长时间浏览会累积
  // 整棵 DOM（几十 KB~几 MB），iOS 上会被系统杀。官方实现只留 8 个，这里放宽到 16。
  static const int _maxDocs = 16;
  final LinkedHashMap<int, dom.Document> _docs = LinkedHashMap();
  final LinkedHashMap<int, dom.Node> _nodes = LinkedHashMap();
  int _seq = 1;

  // ── Cookie：host -> name -> value ──
  final Map<String, Map<String, String>> _cookies = {};

  int _nextId() => _seq++;

  void _trim() {
    while (_nodes.length > _maxNodes) {
      _nodes.remove(_nodes.keys.first);
    }
  }

  // ══════════════════════════════════════════════════════════════
  // 入口
  // ══════════════════════════════════════════════════════════════

  /// 处理一条 JS 请求；同步能力直接返回，网络能力返回 Future。
  Object? handle(dynamic raw) {
    if (raw is! Map) {
      throw Exception('Venera 宿主请求格式错误');
    }
    final m = raw.map((k, v) => MapEntry('$k', v));
    final method = '${m['method'] ?? ''}';
    switch (method) {
      case 'http':
        return _http(m);
      case 'convert':
        return _convert(m);
      case 'html':
        return _html(m);
      case 'load_data':
        return _loadData(m);
      case 'save_data':
        _saveData(m);
        return null;
      case 'delete_data':
        _deleteData(m);
        return null;
      case 'load_setting':
        return _loadSetting(m);
      case 'isLogged':
        return _loadData({'data_key': '_logged'}) == true;
      case 'cookie':
        return _cookie(m);
      case 'ui':
        return _ui(m);
      case 'log':
        _log('${m['title'] ?? ''}: ${m['content'] ?? ''}');
        return null;
      default:
        throw Exception('Venera 兼容层未实现的宿主能力: $method');
    }
  }

  // ══════════════════════════════════════════════════════════════
  // convert
  // ══════════════════════════════════════════════════════════════

  Object? _convert(Map<String, dynamic> m) {
    final type = '${m['type'] ?? ''}'.toLowerCase();
    final isEncode = m['isEncode'] != false;

    if (type == 'utf8') {
      if (isEncode)
        return Uint8List.fromList(utf8.encode('${m['value'] ?? ''}'));
      return utf8.decode(_bytesOf(m['value']), allowMalformed: true);
    }
    if (type == 'base64') {
      if (isEncode) return base64Encode(_bytesOf(m['value']));
      return base64Decode('${m['value'] ?? ''}'.trim());
    }
    if (type == 'gbk') {
      if (isEncode) {
        return Uint8List.fromList(gbk_bytes.encode('${m['value'] ?? ''}'));
      }
      return gbk_bytes.decode(_bytesOf(m['value']));
    }
    if (type == 'gzip') {
      if (isEncode)
        return Uint8List.fromList(gzip.encode(_bytesOf(m['value'])));
      final out = gzip.decode(_bytesOf(m['value']));
      return Uint8List.fromList(out);
    }
    if (type == 'md5' ||
        type == 'sha1' ||
        type == 'sha256' ||
        type == 'sha512') {
      final input = _bytesOf(m['value']);
      final digest = switch (type) {
        'md5' => crypto.md5.convert(input),
        'sha1' => crypto.sha1.convert(input),
        'sha256' => crypto.sha256.convert(input),
        _ => crypto.sha512.convert(input),
      };
      return Uint8List.fromList(digest.bytes);
    }
    if (type == 'hmac') {
      final key = _bytesOf(m['key']);
      final input = _bytesOf(m['value']);
      final hash = '${m['hash'] ?? 'sha256'}'.toLowerCase();
      final algo = switch (hash) {
        'md5' => crypto.md5,
        'sha1' => crypto.sha1,
        'sha512' => crypto.sha512,
        _ => crypto.sha256,
      };
      final digest = crypto.Hmac(algo, key).convert(input);
      if (m['isString'] == true) return digest.toString();
      return Uint8List.fromList(digest.bytes);
    }
    if (type.startsWith('aes-')) {
      return _aes(type, m, isEncode);
    }
    if (type == 'rsa') {
      throw Exception('Venera 兼容层暂不支持 RSA 解密');
    }
    throw Exception('未知的转换类型: $type');
  }

  Object? _aes(String type, Map<String, dynamic> m, bool isEncode) {
    final keyBytes = _bytesOf(m['key']);
    final ivBytes = m['iv'] == null ? null : _bytesOf(m['iv']);
    final mode = switch (type) {
      'aes-ecb' => enc.AESMode.ecb,
      'aes-cbc' => enc.AESMode.cbc,
      'aes-cfb' => enc.AESMode.cfb64,
      _ => enc.AESMode.ofb64,
    };
    final padded = mode == enc.AESMode.ecb || mode == enc.AESMode.cbc;
    final aes = enc.AES(
      enc.Key(keyBytes),
      mode: mode,
      padding: padded ? 'PKCS7' : null,
    );
    final encrypter = enc.Encrypter(aes);
    final input = _bytesOf(m['value']);
    final iv = ivBytes == null ? null : enc.IV(ivBytes);
    if (isEncode) {
      if (iv == null) {
        return Uint8List.fromList(encrypter.encryptBytes(input).bytes);
      }
      return Uint8List.fromList(
        encrypter.encryptBytes(input, iv: iv).bytes,
      );
    }
    final encrypted = enc.Encrypted(input);
    if (iv == null) {
      return Uint8List.fromList(encrypter.decryptBytes(encrypted));
    }
    return Uint8List.fromList(encrypter.decryptBytes(encrypted, iv: iv));
  }

  Uint8List _bytesOf(Object? value) {
    if (value == null) return Uint8List(0);
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    if (value is List) {
      return Uint8List.fromList(
        value.map((e) => int.tryParse('$e') ?? 0).toList(),
      );
    }
    if (value is Map && value['__bytes'] != null) {
      try {
        return base64Decode('${value['__bytes']}');
      } catch (_) {
        return Uint8List(0);
      }
    }
    return Uint8List.fromList(utf8.encode('$value'));
  }

  // ══════════════════════════════════════════════════════════════
  // HTML
  // ══════════════════════════════════════════════════════════════

  Object? _html(Map<String, dynamic> m) {
    final fn = '${m['function'] ?? ''}';
    final key = (m['key'] as num?)?.toInt() ?? 0;
    if (fn == 'parse') {
      final doc = html_parser.parse('${m['data'] ?? ''}');
      final id = _nextId();
      _docs[id] = doc;
      while (_docs.length > _maxDocs) {
        _docs.remove(_docs.keys.first);
      }
      return id;
    }
    if (fn == 'dispose') {
      _docs.remove(key);
      return null;
    }

    final doc = _docs[key];
    switch (fn) {
      case 'querySelector':
        if (doc == null) return null;
        return _putNode(
          _queryOne(() => doc.querySelector('${m['query'] ?? ''}')),
        );
      case 'querySelectorAll':
        if (doc == null) return <int>[];
        return [
          for (final e in _queryAll(
            () => doc.querySelectorAll('${m['query'] ?? ''}'),
          ))
            _putNode(e),
        ];
      case 'getElementById':
        if (doc == null) return null;
        return _putNode(doc.getElementById('${m['id'] ?? ''}'));
      case 'domQuerySelector':
        final el = _element(key);
        return _putNode(
          _queryOne(() => el?.querySelector('${m['query'] ?? ''}')),
        );
      case 'domQuerySelectorAll':
        final el = _element(key);
        if (el == null) return <int>[];
        return [
          for (final e in _queryAll(
            () => el.querySelectorAll('${m['query'] ?? ''}'),
          ))
            _putNode(e),
        ];
      case 'getText':
        return _element(key)?.text.trim() ?? '';
      case 'getAttributes':
        final el = _element(key);
        if (el == null) return <String, String>{};
        return Map<String, String>.from(el.attributes);
      case 'getInnerHTML':
        return _element(key)?.innerHtml ?? '';
      case 'getChildren':
        final el = _element(key);
        if (el == null) return <int>[];
        return [for (final e in el.children) _putNode(e)];
      case 'getNodes':
        final node = _nodes[key];
        if (node == null) return <int>[];
        return [for (final n in node.nodes) _putNode(n)];
      case 'getParent':
        final parent = _element(key)?.parent;
        return parent is dom.Element ? _putNode(parent) : null;
      case 'getClassNames':
        return _element(key)?.classes.toList() ?? <String>[];
      case 'getId':
        return _element(key)?.id;
      case 'getLocalName':
        return _element(key)?.localName ?? '';
      case 'getPreviousSibling':
        return _putNode(_element(key)?.previousElementSibling);
      case 'getNextSibling':
        return _putNode(_element(key)?.nextElementSibling);
      case 'node_text':
        return (_nodes[key]?.text ?? '').trim();
      case 'node_type':
        final node = _nodes[key];
        if (node is dom.Element) return 'element';
        if (node is dom.Text) return 'text';
        if (node is dom.Comment) return 'comment';
        if (node is dom.Document) return 'document';
        return 'unknown';
      case 'node_toElement':
        final node = _nodes[key];
        return node is dom.Element ? _putNode(node) : null;
      default:
        throw Exception('未实现的 HTML 操作: $fn');
    }
  }

  dom.Element? _element(int key) {
    final node = _nodes[key];
    return node is dom.Element ? node : null;
  }

  /// 选择器语法错误（源脚本写错）不应让整条链路崩掉 —— 与浏览器行为一致：查不到。
  dom.Element? _queryOne(dom.Element? Function() fn) {
    try {
      return fn();
    } catch (_) {
      return null;
    }
  }

  List<dom.Element> _queryAll(List<dom.Element> Function() fn) {
    try {
      return fn();
    } catch (_) {
      return const [];
    }
  }

  int? _putNode(dom.Node? node) {
    if (node == null) return null;
    final id = _nextId();
    _nodes[id] = node;
    _trim();
    return id;
  }

  // ══════════════════════════════════════════════════════════════
  // storage
  // ══════════════════════════════════════════════════════════════

  String _dataKey(String k) => 'venera_data_${sourceKey}_$k';
  String _settingKey(String k) => 'venera_setting_${sourceKey}_$k';

  Object? _loadData(Map<String, dynamic> m) {
    final raw = prefs.getString(_dataKey('${m['data_key'] ?? ''}'));
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  void _saveData(Map<String, dynamic> m) {
    final key = _dataKey('${m['data_key'] ?? ''}');
    final data = m['data'];
    prefs.setString(key, jsonEncode(data)).catchError((_) => false);
  }

  void _deleteData(Map<String, dynamic> m) {
    prefs.remove(_dataKey('${m['data_key'] ?? ''}')).catchError((_) => false);
  }

  Object? _loadSetting(Map<String, dynamic> m) {
    final raw = prefs.getString(_settingKey('${m['setting_key'] ?? ''}'));
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return raw;
    }
  }

  // ══════════════════════════════════════════════════════════════
  // cookie
  // ══════════════════════════════════════════════════════════════

  Object? _cookie(Map<String, dynamic> m) {
    final fn = '${m['function'] ?? ''}';
    final url = '${m['url'] ?? ''}';
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isEmpty) return <Map<String, String>>[];
    if (fn == 'set') {
      final list = m['cookies'];
      if (list is List) {
        final jar = _cookies.putIfAbsent(host, () => {});
        for (final c in list) {
          if (c is! Map) continue;
          final name = '${c['name'] ?? ''}';
          if (name.isEmpty) continue;
          jar[name] = '${c['value'] ?? ''}';
        }
      }
      return null;
    }
    if (fn == 'delete') {
      _cookies.remove(host);
      return null;
    }
    final jar = _cookies[host] ?? const <String, String>{};
    return [
      for (final e in jar.entries)
        {'name': e.key, 'value': e.value, 'domain': host},
    ];
  }

  // ══════════════════════════════════════════════════════════════
  // ui
  // ══════════════════════════════════════════════════════════════

  Object? _ui(Map<String, dynamic> m) {
    final fn = '${m['function'] ?? ''}';
    if (fn == 'showMessage' || fn == 'showDialog') {
      final text = '${m['message'] ?? m['title'] ?? ''}'.trim();
      if (text.isNotEmpty) onToast?.call(text);
      return null;
    }
    if (fn == 'launchUrl') {
      onLaunchUrl?.call('${m['url'] ?? ''}');
      return null;
    }
    return null;
  }

  // ══════════════════════════════════════════════════════════════
  // http
  // ══════════════════════════════════════════════════════════════

  Future<Map<String, dynamic>> _http(Map<String, dynamic> m) async {
    final method = '${m['http_method'] ?? 'GET'}'.toUpperCase();
    final url = '${m['url'] ?? ''}';
    final headers = _stringMap(m['headers']);
    if (!headers.keys.any((k) => k.toLowerCase() == 'user-agent')) {
      headers['User-Agent'] = _kDefaultUa;
    }
    final host = Uri.tryParse(url)?.host ?? '';
    if (host.isNotEmpty &&
        !headers.keys.any((k) => k.toLowerCase() == 'cookie')) {
      final jar = _cookies[host];
      if (jar != null && jar.isNotEmpty) {
        headers['Cookie'] = jar.entries
            .map((e) => '${e.key}=${e.value}')
            .join('; ');
      }
    }
    try {
      final res = await _dio.request<List<int>>(
        url,
        data: _httpData(m['data']),
        options: Options(
          method: method,
          headers: headers,
          responseType: ResponseType.bytes,
          validateStatus: (_) => true,
          followRedirects: true,
        ),
      );
      final bytes = res.data ?? const <int>[];
      _ingestCookies(host, res.headers['set-cookie']);
      final respHeaders = <String, String>{};
      res.headers.forEach((k, v) => respHeaders[k] = v.join(', '));
      final isBinary = m['bytes'] == true;
      return {
        'status': res.statusCode ?? 0,
        'headers': respHeaders,
        'body': isBinary
            ? Uint8List.fromList(bytes)
            : _decodeText(bytes, respHeaders),
      };
    } catch (e) {
      return {'error': '$e'};
    }
  }

  Object? _httpData(Object? data) {
    if (data == null) return null;
    if (data is Map && data['__bytes'] != null) {
      try {
        return base64Decode('${data['__bytes']}');
      } catch (_) {
        return null;
      }
    }
    if (data is String || data is List<int> || data is Uint8List) return data;
    if (data is Map || data is List) return jsonEncode(data);
    return '$data';
  }

  void _ingestCookies(String host, Object? setCookie) {
    if (host.isEmpty || setCookie == null) return;
    final list = setCookie is List ? setCookie : [setCookie];
    final jar = _cookies.putIfAbsent(host, () => {});
    for (final raw in list) {
      final text = '$raw';
      final first = text.split(';').first;
      final idx = first.indexOf('=');
      if (idx <= 0) continue;
      final name = first.substring(0, idx).trim();
      final value = first.substring(idx + 1).trim();
      if (name.isNotEmpty) jar[name] = value;
    }
  }

  String _decodeText(List<int> bytes, Map<String, String> headers) {
    if (bytes.isEmpty) return '';
    var charset = '';
    for (final e in headers.entries) {
      if (e.key.toLowerCase() == 'content-type') {
        final m = RegExp(
          r'charset=([\w-]+)',
          caseSensitive: false,
        ).firstMatch(e.value);
        if (m != null) charset = m.group(1)!.toLowerCase();
        break;
      }
    }
    if (charset.isEmpty) {
      // 从 HTML 头部 meta 猜编码（只扫前 2KB）
      final head = ascii
          .decode(
            bytes.length > 2048 ? bytes.sublist(0, 2048) : bytes,
            allowInvalid: true,
          )
          .toLowerCase();
      final m = RegExp(
        r'charset=["'
        r"']?([\w-]+)",
      ).firstMatch(head);
      if (m != null) charset = m.group(1)!.toLowerCase();
    }
    if (charset.contains('gbk') ||
        charset.contains('gb2312') ||
        charset.contains('gb18030')) {
      return gbk_bytes.decode(bytes);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static Map<String, String> _stringMap(Object? raw) {
    if (raw is! Map) return <String, String>{};
    return raw.map((k, v) => MapEntry('$k', '$v'));
  }

  void _log(String message) {
    if (kDebugMode) debugPrint('[Venera:$sourceKey] $message');
  }
}
