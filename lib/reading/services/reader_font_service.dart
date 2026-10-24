import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个已导入的自定义字体。
class ReaderFont {
  const ReaderFont({
    required this.id,
    required this.name,
    required this.path,
    required this.family,
  });

  final String id;

  /// 界面上显示的名字（一般取文件名）
  final String name;

  /// 字体文件落盘路径
  final String path;

  /// 注册到 Flutter 引擎的 family（全局唯一，`ReaderFont_xx`）
  final String family;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'path': path,
    'family': family,
  };

  static ReaderFont? fromJson(Map<String, dynamic> j) {
    final id = (j['id'] as String?) ?? '';
    final path = (j['path'] as String?) ?? '';
    final family = (j['family'] as String?) ?? '';
    if (id.isEmpty || path.isEmpty || family.isEmpty) return null;
    return ReaderFont(
      id: id,
      name: (j['name'] as String?) ?? '自定义字体',
      path: path,
      family: family,
    );
  }
}

/// 自定义字体：导入（文件 / 字节）、落盘、注册到引擎、列表持久化。
///
/// 为什么用 `FontLoader`：Flutter 只能渲染**已注册到引擎**的 family；运行期
/// 导入的字体必须先 `FontLoader.load()` 一次，`TextStyle(fontFamily: …)` 才生效。
/// 注册是进程级的 —— 同一 family 只需注册一次（这里用 [_registered] 去重）。
class ReaderFontService {
  ReaderFontService._();

  static final ReaderFontService instance = ReaderFontService._();

  static const _kFonts = 'reading.fonts';

  final List<ReaderFont> fonts = [];
  final Set<String> _registered = {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kFonts);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List;
      for (final e in list) {
        if (e is! Map) continue;
        final f = ReaderFont.fromJson(Map<String, dynamic>.from(e));
        if (f == null) continue;
        // 文件被系统清掉了就跳过（不删记录，避免"重装后自动消失"）
        if (!File(f.path).existsSync()) continue;
        fonts.add(f);
      }
    } catch (_) {}
  }

  /// 取某个字体 id 对应的 family（会确保已注册）；不存在/加载失败返回 null
  Future<String?> familyOf(String? id) async {
    if (id == null || id.isEmpty) return null;
    await load();
    ReaderFont? f;
    for (final e in fonts) {
      if (e.id == id) {
        f = e;
        break;
      }
    }
    if (f == null) return null;
    if (!File(f.path).existsSync()) return null;
    await _ensureRegistered(f);
    return _registered.contains(f.family) ? f.family : null;
  }

  /// 只查**已注册**的字体（同步）：套用样式时先用它，省一次重排
  String? familyOfSync(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final f in fonts) {
      if (f.id != id) continue;
      return _registered.contains(f.family) ? f.family : null;
    }
    return null;
  }

  Future<void> _ensureRegistered(ReaderFont f) async {
    if (_registered.contains(f.family)) return;
    try {
      final bytes = await File(f.path).readAsBytes();
      final loader = FontLoader(f.family)
        ..addFont(Future.value(ByteData.sublistView(Uint8List.fromList(bytes))));
      await loader.load();
      _registered.add(f.family);
    } catch (_) {}
  }

  /// 导入字体字节（ttf / otf / ttc）。成功返回 [ReaderFont]，失败返回 null。
  Future<ReaderFont?> importBytes(
    List<int> bytes, {
    String? name,
    String? ext,
  }) async {
    if (bytes.isEmpty) return null;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final d = Directory('${dir.path}/reader_fonts');
      if (!d.existsSync()) d.createSync(recursive: true);
      final id = 'font:${DateTime.now().millisecondsSinceEpoch}';
      final safeExt = (ext == null || ext.trim().isEmpty)
          ? 'ttf'
          : ext.trim().toLowerCase();
      final path = '${d.path}/$id.$safeExt';
      await File(path).writeAsBytes(bytes, flush: true);
      final family = 'ReaderFont_${id.replaceAll(':', '_')}';
      final f = ReaderFont(
        id: id,
        name: (name == null || name.trim().isEmpty) ? '自定义字体' : name.trim(),
        path: path,
        family: family,
      );
      await _ensureRegistered(f);
      if (!_registered.contains(f.family)) {
        // 引擎放不进去（不是有效字体）⇒ 删掉文件，不污染列表
        try {
          File(path).deleteSync();
        } catch (_) {}
        return null;
      }
      fonts.add(f);
      await _persist();
      return f;
    } catch (_) {
      return null;
    }
  }

  /// 从文件路径导入
  Future<ReaderFont?> importFile(String path, {String? name}) async {
    try {
      final bytes = await File(path).readAsBytes();
      final ext = path.contains('.') ? path.split('.').last : 'ttf';
      return await importBytes(bytes, name: name, ext: ext);
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(ReaderFont f) async {
    fonts.removeWhere((e) => e.id == f.id);
    _registered.remove(f.family);
    try {
      final file = File(f.path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _kFonts,
        jsonEncode([for (final f in fonts) f.toJson()]),
      );
    } catch (_) {}
  }
}
