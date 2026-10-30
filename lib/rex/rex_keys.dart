/// REX **加密模块**（`REXENC` 容器）的主密钥。
///
/// 社区里有一部分模块不是明文 JS，长这样：
///
/// ```
/// REXENC
/// {"v":2,"mkv":"rex-1","alg":"A256GCM","iv":"…","kb":"…"}
/// <base64 密文>
/// ```
///
/// `kb` 里封着这个模块的 32 字节内容密钥，要用名叫 `rex-1` 的**主密钥**
/// 才能拆开。主密钥属于发布方（Rex 客户端自带一份），App 这边不内置、
/// 也不去猜 —— 由用户自己填一次，存在本地，之后所有加密模块共用。
///
/// 填法见 [normalize]：64 位 hex、44 位 base64、或 32 字节原文都认。
library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class RexKeys {
  RexKeys._();

  static const _kMaster = 'rex.master.key.v1';

  /// 内存缓存：每次调模块都要用，别每次都去敲 SharedPreferences
  static String _cached = '';
  static bool _loaded = false;

  /// 当前主密钥；没填过返回空串
  static Future<String> master() async {
    if (_loaded) return _cached;
    try {
      final sp = await SharedPreferences.getInstance();
      _cached = sp.getString(_kMaster) ?? '';
    } catch (_) {
      _cached = '';
    }
    _loaded = true;
    return _cached;
  }

  /// 同步读上次 [master] 的结果（没读过就是空串）
  static String get cached => _cached;

  /// 保存主密钥（空串 = 清除）
  static Future<void> save(String raw) async {
    final v = normalize(raw);
    // 认不出来的写法原样存：用户可能是新版格式，别在这里拦死
    final out = v ?? raw.trim();
    _cached = out;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      if (out.isEmpty) {
        await sp.remove(_kMaster);
      } else {
        await sp.setString(_kMaster, out);
      }
    } catch (_) {}
  }

  /// 把用户贴进来的东西洗成统一形式（hex 小写）；认不出来返回 null。
  ///
  /// 从别处复制常带空格/换行/引号/`0x`，先洗一遍再判断。
  static String? normalize(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return '';
    s = s.replaceAll(RegExp(r'[\s"`\u2018\u2019\u201c\u201d]'), '');
    if (s.toLowerCase().startsWith('0x')) s = s.substring(2);
    if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(s)) return s.toLowerCase();
    // base64：44 位（32 字节 + 一个 '='）
    if (RegExp(r'^[A-Za-z0-9+/]{43}=?$').hasMatch(s)) {
      return s.endsWith('=') ? s : '$s=';
    }
    // 32 字节原文
    if (s.length == 32) return s;
    return null;
  }

  /// 给界面看的形态：只露头尾，避免截图/录屏把密钥带走
  static String mask(String v) {
    if (v.isEmpty) return '';
    if (v.length <= 12) return '•' * v.length;
    return '${v.substring(0, 4)}${'•' * 8}${v.substring(v.length - 4)}';
  }
}

/// 加密容器的**只读**解析（不解密）。
///
/// 放在 Dart 侧是为了「导入前就能说清楚这是什么」：用户拖进来一个加密模块
/// 而没填主密钥时，直接告诉他去填，而不是等 Node 编译失败后回一句
/// 「模块代码无法解析：Unexpected token」。
///
/// 两种魔数布局**完全一致**（2026-10-31 实测：`iv` 12 字节、`kb` 60 字节，
/// 头部字段同名），只有 `mkv`（主密钥标识）不同：
///   · `REXENC` → `rex-1`（Rex 客户端自带）
///   · `FWENC2` → `1`（ForwardWidget 官方，widgetencrypt.inchmade.ai）
///
/// 拆封规则与 `assets/nodejs-project/src/rex_engine.js` 的
/// `parseRexEncHeader` / `decodeRexEnc` 保持完全一致。
class RexEnvelope {
  const RexEnvelope({
    required this.magic,
    required this.version,
    required this.masterKeyId,
    required this.algorithm,
  });

  /// 命中的魔数（`REXENC` / `FWENC2` / `FWENC1`）
  final String magic;

  /// 容器版本（当前只有 2）
  final int version;

  /// 主密钥标识（`rex-1` / `1`）
  final String masterKeyId;

  /// 算法（`A256GCM`）
  final String algorithm;

  /// 认得的魔数，**长串在前**（`FWENC` 是 `FWENC2` 的前缀）
  static const magics = ['REXENC', 'FWENC2', 'FWENC1', 'FWENC'];

  static String _stripBom(String code) =>
      code.startsWith('\uFEFF') ? code.substring(1) : code;

  /// 这段源码是不是加密容器（容忍 UTF-8 BOM）
  static bool isEncrypted(String code) {
    final s = _stripBom(code);
    return magics.any(s.startsWith);
  }

  /// 解析头部；不是加密容器 / 头部坏了都返回 null
  static RexEnvelope? tryParse(String code) {
    final src = _stripBom(code);
    String? magic;
    for (final m in magics) {
      if (src.startsWith(m)) {
        magic = m;
        break;
      }
    }
    if (magic == null) return null;
    final nl1 = src.indexOf('\n');
    if (nl1 < 0) return null;
    final nl2 = src.indexOf('\n', nl1 + 1);
    if (nl2 < 0) return null;
    final raw = src.substring(nl1 + 1, nl2).trim();
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      return RexEnvelope(
        magic: magic,
        version: _asInt(j['v']),
        masterKeyId: '${j['mkv'] ?? ''}',
        algorithm: '${j['alg'] ?? ''}',
      );
    } catch (_) {
      return null;
    }
  }

  /// 是不是我们能解的版本 / 算法
  bool get supported => version == 2 && algorithm.toUpperCase() == 'A256GCM';

  /// 给人看的一句话
  String get label {
    final alg = algorithm.isEmpty ? '未知算法' : algorithm;
    final id = masterKeyId.isEmpty ? '未知主密钥' : masterKeyId;
    return '$magic v$version · $alg · $id';
  }
}

int _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse('${v ?? ''}') ?? 0;
}
