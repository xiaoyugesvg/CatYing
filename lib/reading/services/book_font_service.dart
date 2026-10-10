import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

void _log(String message) {
  if (kDebugMode) debugPrint('[BookFont] $message');
}

/// 用户导入的字体
class UserFont {
  /// FontLoader 注册名（= 文件名去后缀）
  final String family;

  /// UI 显示名
  final String displayName;

  /// 源 ttf/otf/ttc 路径
  final String path;

  const UserFont({
    required this.family,
    required this.displayName,
    required this.path,
  });
}

/// 阅读器字体管理。
///
/// ── 与 cmbok 原版的差异 ────────────────────────────────────────
/// 原版用 `file_picker` 选字体文件。本项目是 **iOS TrollStore 侧载**，
/// 硬约束是"不新增原生插件"（flutter_tts 未 pod install 导致过 SIGABRT 闪退），
/// 所以这里改成：
///   · 启动时扫描沙盒 `Documents/book_fonts/` 目录自动注册字体
///   · 导入走**纯 Dart 文件浏览**（见 `font_import_page.dart`），不依赖任何插件
///
/// 用户把 ttf/otf/ttc 放进该目录（或从文件浏览页拷入）即可被识别。
class BookFontService extends ChangeNotifier {
  BookFontService._();
  static final BookFontService _instance = BookFontService._();
  factory BookFontService() => _instance;

  static const systemFamily = 'system';
  static const autoFamily = '__auto__';

  /// 内置字体选项（系统字体 + 自动）
  static const builtinOptions = <(String, String)>[
    (autoFamily, '跟随主题'),
    (systemFamily, '系统默认'),
    // 随包内置字体（已在 pubspec 的 `fonts:` 段注册 ⇒ 装完就能选 ✓）
    ('MiSans', 'MiSans（内置）'),
  ];

  final Map<String, UserFont> _fontByFamily = {};
  bool _ready = false;
  bool get ready => _ready;

  /// 已注册用户字体的 family 列表（排序后）。UI 用它渲染字体选项。
  List<String> _userFamilies = const [];
  List<String> get userFamilies => List.unmodifiable(_userFamilies);

  /// family -> 用户字体描述
  Map<String, UserFont> get fontByFamily =>
      Map<String, UserFont>.unmodifiable(_fontByFamily);

  /// 已注册的用户字体
  List<UserFont> get userFonts => _fontByFamily.values.toList();

  Future<Directory> _fontsDir() async {
    final appDir = await getApplicationDocumentsDirectory();
    final d = Directory('${appDir.path}/book_fonts');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 字体目录的绝对路径（设置页展示给用户，方便往里面放文件）
  Future<String> fontsDirPath() async => (await _fontsDir()).path;

  Future<void> init() async {
    try {
      final dir = await _fontsDir();
      final files = <File>[];
      for (final e in dir.listSync(followLinks: false)) {
        if (e is File && _isFontFile(e.path)) files.add(e);
      }
      if (files.isEmpty) {
        _ready = true;
        _log('未发现用户字体（目录：${dir.path}）');
        notifyListeners();
        return;
      }

      final list = <UserFont>[];
      for (final e in files) {
        final name = e.uri.pathSegments.last;
        final base = _stripExt(name);
        try {
          final bytes = await e.readAsBytes();
          // 🔴 必须**每个字体一个 family**（family 名 = 文件名去后缀）✗✓：
          //   原来把所有文件都塞进同一个 `FontLoader('book_fonts')` ✗ ⇒
          //   Flutter 会把这些字体**全注册成 family = `book_fonts`** ✓，
          //   而 UI 里选的是 `MiSans` 这种**文件名** ⇒ 永远匹配不上 ✗
          //   ⇒ 表现为"选了自定义字体，正文却没变"（静默回落默认字体）。
          final loader = FontLoader(base);
          loader.addFont(Future.value(ByteData.sublistView(bytes)));
          await loader.load();
          list.add(UserFont(
            family: base,
            displayName: base,
            path: e.path,
          ));
        } catch (err) {
          _log('字体 $name 加载失败: $err');
        }
      }
      if (list.isNotEmpty) {
        for (final f in list) {
          _fontByFamily[f.family] = f;
        }
        _userFamilies = list.map((f) => f.family).toList()..sort();
        _log('已注册 ${list.length} 个用户字体');
      }
    } catch (e) {
      _log('字体初始化失败: $e');
    } finally {
      _ready = true;
      notifyListeners();
    }
  }

  /// 重新扫描（用户手动往目录放了文件之后调用）
  Future<void> rescan() async {
    _fontByFamily.clear();
    _ready = false;
    await init();
  }

  static bool _isFontFile(String path) {
    final p = path.toLowerCase();
    return p.endsWith('.ttf') || p.endsWith('.otf') || p.endsWith('.ttc');
  }

  static String _stripExt(String name) {
    final i = name.lastIndexOf('.');
    return i > 0 ? name.substring(0, i) : name;
  }

  /// 把外部字体文件复制进字体目录并重新注册。
  ///
  /// 原版是 `importFont()` 内部弹 `file_picker`；这里**不用插件**，
  /// 由调用方先用纯 Dart 文件浏览器选好路径再传进来
  /// （见 `utils/file_browser.dart`）。
  Future<bool> importFrom(String sourcePath) async {
    try {
      final src = File(sourcePath);
      if (!await src.exists()) return false;
      final name = src.uri.pathSegments.last;
      if (!_isFontFile(name)) return false;
      final dir = await _fontsDir();
      await src.copy('${dir.path}/$name');
      await rescan();
      return true;
    } catch (e) {
      _log('导入字体失败: $e');
      return false;
    }
  }

  /// 兼容原版调用名：返回新字体的 family（失败返回 null）。
  Future<String?> importFont(String sourcePath) async {
    final ok = await importFrom(sourcePath);
    if (!ok) return null;
    final base = _stripExt(sourcePath.split(Platform.pathSeparator).last);
    _log('importFont $base');
    return base;
  }

  /// 删除用户字体
  Future<void> remove(String family) async {
    final f = _fontByFamily[family];
    if (f == null) return;
    try {
      final file = File(f.path);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    _fontByFamily.remove(family);
    notifyListeners();
  }
}
