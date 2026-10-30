import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:rfw/formats.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// RFW（Remote Flutter Widgets）主题 = 用 `.rfwtxt` 文本描述的**影视首页皮肤**。
///
/// ⚠️ 作用域：**只管影视模块的首页**（分类/筛选/推荐/片单网格）。
/// 音乐、阅读、直播、设置等页面不受影响 —— 主题文件里能用的只有
/// `core.widgets` 与 `peek.home` 两个库，而 `peek.home` 提供的
/// （PeekStickyGrid / PeekCarousel / PeekGlass / PeekImmersiveScaffold …）
/// 全是为「首页片单」设计的，套到别的模块没有意义。
class RfwThemeEntry {
  const RfwThemeEntry({
    required this.id,
    required this.name,
    required this.isBuiltin,
    this.asset,
    this.fileName,
    this.followsPalette = true,
  });

  final String id;
  final String name;
  final bool isBuiltin;
  final String? asset;
  final String? fileName;

  /// 这套主题是否**跟随软件配色**（颜色全部从 `data.home.theme.*` 取）。
  ///
  ///   · true（默认）：换「外观 → 配色」时首页跟着变。
  ///     内置的晨光 / 素影 / 星河都是这一类。
  ///   · false：主题自带完整配色方案（用户提供的 PeekPro 风格主题）。
  ///     这类主题的颜色就是它的设计本身，硬改成跟随调色板等于把它拆了。
  ///
  /// 加这个字段是因为 `test/rfw_theme_test.dart` 有一条"主题文件里不许出现
  /// 写死色值"的守护测试 —— 不区分这两类的话，用户自己导入的风格主题
  /// 会被误判成回归（2026-10-30 内置蓝魔凝光 / 春日记忆时踩到）。
  final bool followsPalette;
}

const List<RfwThemeEntry> builtinRfwThemes = [
  RfwThemeEntry(
    id: 'chenguang',
    name: '晨光网格',
    isBuiltin: true,
    asset: 'assets/rfw_themes/chenguang_grid.rfwtxt',
  ),
  RfwThemeEntry(
    id: 'suyu',
    name: '素影列表',
    isBuiltin: true,
    asset: 'assets/rfw_themes/suyu_list.rfwtxt',
  ),
  RfwThemeEntry(
    id: 'xinghe',
    name: '星河横幅',
    isBuiltin: true,
    asset: 'assets/rfw_themes/xinghe_banner.rfwtxt',
  ),
  // 2026-10-30 用户提供并内置的两套「PeekPro」主题。
  //
  // 它们和上面三套用的是**同一份数据契约**（data.home.icons / classes /
  // filterPanelHeight …），额外只多用了两个 PeekPro 的便捷组件：
  //   · SizedBoxShrink()        → 空占位
  //   · AnimationDefaults(...)  → 动画包装（静态渲染时直接透传 child）
  // 这两个已在 `createPeekHomeLibrary()` 里补上，所以不用改主题文件本身。
  RfwThemeEntry(
    id: 'lanmo',
    name: '蓝魔凝光·琥珀玻璃',
    isBuiltin: true,
    asset: 'assets/rfw_themes/lanmo_amber.rfwtxt',
    // 自带琥珀玻璃配色方案，不跟「外观 → 配色」走（见 followsPalette 注释）
    followsPalette: false,
  ),
  RfwThemeEntry(
    id: 'chunri',
    name: '春日记忆',
    isBuiltin: true,
    asset: 'assets/rfw_themes/chunri_memory.rfwtxt',
    followsPalette: false,
  ),
];

const String rfwThemeModeKey = 'rfwThemeMode';
const String rfwThemeIdKey = 'rfwThemeId';
const String rfwDisplayStyleKey = 'rfwDisplayStyle';

/// 是否用 RFW 主题渲染影视首页（默认关，保持原生首页）。
final ValueNotifier<bool> rfwThemeModeNotifier = ValueNotifier(false);

/// 选中的主题 id（null = 用第一个内置主题）。
final ValueNotifier<String?> rfwThemeIdNotifier = ValueNotifier(null);

/// 当前**实际生效**的主题 id。
///
/// 存的是 null（从没选过）或某个已被删掉的自定义主题时，
/// 渲染层会回落到第一个内置主题 —— 色板也必须跟着回落，
/// 否则会出现「布局是晨光、配色却按自定义主题算」的错位。
String effectiveRfwThemeId(String? id) {
  if (id == null || id.isEmpty) return builtinRfwThemes.first.id;
  final builtin = builtinRfwThemes.where((e) => e.id == id);
  if (builtin.isNotEmpty) return builtin.first.id;
  // 自定义主题：色板按「跟随软件配色」处理（见 RfwThemePalette.of 的 default 分支）
  return id;
}

/// 主题内的「显示样式」：grid / largeGrid / banner / list / list2 / textList / card
final ValueNotifier<String> rfwDisplayStyleNotifier = ValueNotifier('grid');

Future<void> loadRfwThemePreferences() async {
  final prefs = await SharedPreferences.getInstance();
  rfwThemeModeNotifier.value = prefs.getBool(rfwThemeModeKey) ?? false;
  rfwThemeIdNotifier.value = prefs.getString(rfwThemeIdKey);
  rfwDisplayStyleNotifier.value = prefs.getString(rfwDisplayStyleKey) ?? 'grid';
}

Future<void> saveRfwThemeMode(bool enabled) async {
  rfwThemeModeNotifier.value = enabled;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool(rfwThemeModeKey, enabled);
}

Future<void> saveRfwThemeId(String? id) async {
  rfwThemeIdNotifier.value = id;
  final prefs = await SharedPreferences.getInstance();
  if (id == null) {
    await prefs.remove(rfwThemeIdKey);
  } else {
    await prefs.setString(rfwThemeIdKey, id);
  }
}

Future<void> saveRfwDisplayStyle(String style) async {
  rfwDisplayStyleNotifier.value = style;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(rfwDisplayStyleKey, style);
}

class RfwThemeValidation {
  const RfwThemeValidation({required this.ok, this.reason = ''});

  final bool ok;
  final String reason;
}

/// 主题文件校验：能解析、有 `root`、只 import 允许的库。
///
/// 这三条是安全边界：`.rfwtxt` 是**可执行的数据**，允许任意 import
/// 等于允许它拿宿主的一切 widget 和回调。
RfwThemeValidation validateRfwThemeText(String text) {
  if (text.trim().isEmpty) {
    return const RfwThemeValidation(ok: false, reason: '主题文件为空');
  }
  late final RemoteWidgetLibrary library;
  try {
    library = parseLibraryFile(text);
  } on ParserException catch (error) {
    return RfwThemeValidation(ok: false, reason: '主题解析失败：$error');
  } catch (error) {
    return RfwThemeValidation(ok: false, reason: '主题解析失败：$error');
  }
  if (!library.widgets.any((widget) => widget.name == 'root')) {
    return const RfwThemeValidation(ok: false, reason: '主题缺少 root 定义');
  }
  const allowedImports = {'core.widgets', 'peek.home'};
  for (final import in library.imports) {
    final name = import.name.parts.join('.');
    if (!allowedImports.contains(name)) {
      return RfwThemeValidation(
        ok: false,
        reason: '主题引用了不支持的库：$name',
      );
    }
  }
  return const RfwThemeValidation(ok: true);
}

Future<Directory> rfwThemeDirectory() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/rfw_themes');
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

String rfwThemeFileName(String originalName) {
  final base = originalName.split('/').last.split('\\').last;
  // 也接受 .txt（用户可能把 .rfwtxt 存成 txt 传过来），统一落成 .rfwtxt
  final lower = base.toLowerCase();
  final withoutExtension = lower.endsWith('.rfwtxt')
      ? base.substring(0, base.length - 7)
      : (lower.endsWith('.txt') ? base.substring(0, base.length - 4) : base);
  final cleaned = withoutExtension.replaceAll(RegExp('[\\x00-\\x1F]'), '').trim();
  return '${cleaned.isEmpty ? 'theme' : cleaned}.rfwtxt';
}

Future<List<RfwThemeEntry>> loadRfwThemeEntries({Directory? directory}) async {
  final dir = directory ?? await rfwThemeDirectory();
  final entries = <RfwThemeEntry>[...builtinRfwThemes];
  if (await dir.exists()) {
    final files = await dir
        .list()
        .where((entity) => entity is File)
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final fileName = file.path.split(Platform.pathSeparator).last;
      if (!fileName.toLowerCase().endsWith('.rfwtxt')) continue;
      entries.add(
        RfwThemeEntry(
          id: 'imported:$fileName',
          name: fileName.substring(0, fileName.length - 7),
          isBuiltin: false,
          fileName: fileName,
        ),
      );
    }
  }
  return entries;
}

Future<String?> loadRfwThemeText(
  RfwThemeEntry entry, {
  Directory? directory,
}) async {
  if (entry.isBuiltin) {
    final asset = entry.asset;
    if (asset == null) return null;
    try {
      return await rootBundle.loadString(asset);
    } catch (_) {
      return null;
    }
  }
  final fileName = entry.fileName;
  if (fileName == null) return null;
  final dir = directory ?? await rfwThemeDirectory();
  final file = File('${dir.path}/$fileName');
  if (!await file.exists()) return null;
  return file.readAsString();
}

class RfwThemeImportResult {
  const RfwThemeImportResult({
    required this.ok,
    required this.message,
    this.entry,
  });

  final bool ok;
  final String message;
  final RfwThemeEntry? entry;
}

Future<RfwThemeImportResult> importRfwThemeText(
  String originalName,
  String text, {
  Directory? directory,
}) async {
  final validation = validateRfwThemeText(text);
  if (!validation.ok) {
    return RfwThemeImportResult(ok: false, message: validation.reason);
  }
  final dir = directory ?? await rfwThemeDirectory();
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  final fileName = rfwThemeFileName(originalName);
  var target = File('${dir.path}/$fileName');
  if (await target.exists()) {
    final existing = await target.readAsString();
    if (existing == text) {
      return RfwThemeImportResult(
        ok: false,
        message: '主题已存在：${fileName.substring(0, fileName.length - 7)}',
      );
    }
    var suffix = 2;
    while (await target.exists()) {
      final stem = fileName.substring(0, fileName.length - 7);
      target = File('${dir.path}/$stem-$suffix.rfwtxt');
      suffix += 1;
    }
  }
  await target.writeAsString(text);
  final savedName = target.path.split(Platform.pathSeparator).last;
  return RfwThemeImportResult(
    ok: true,
    message: '主题已导入：${savedName.substring(0, savedName.length - 7)}',
    entry: RfwThemeEntry(
      id: 'imported:$savedName',
      name: savedName.substring(0, savedName.length - 7),
      isBuiltin: false,
      fileName: savedName,
    ),
  );
}

Future<bool> deleteImportedRfwTheme(
  RfwThemeEntry entry, {
  Directory? directory,
}) async {
  if (entry.isBuiltin) return false;
  final fileName = entry.fileName;
  if (fileName == null) return false;
  final dir = directory ?? await rfwThemeDirectory();
  final file = File('${dir.path}/$fileName');
  if (!await file.exists()) return false;
  await file.delete();
  return true;
}

/// 让用户挑一个 `.rfwtxt` 导入。返回 null = 用户取消。
///
/// 本项目 `FilePicker.pickFiles` 是静态 API、返回 `List<PlatformFile>`。
Future<RfwThemeImportResult?> pickAndImportRfwTheme() async {
  final List<PlatformFile> picked;
  try {
    picked = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['rfwtxt', 'txt'],
    );
  } catch (e) {
    return RfwThemeImportResult(ok: false, message: '打开文件选择器失败：$e');
  }
  if (picked.isEmpty) return null;
  final f = picked.first;
  Uint8List? bytes;
  try {
    bytes = await f.readAsBytes();
  } catch (_) {
    final p = f.path;
    if (p != null) {
      try {
        bytes = await File(p).readAsBytes();
      } catch (_) {}
    }
  }
  if (bytes == null || bytes.isEmpty) {
    return const RfwThemeImportResult(ok: false, message: '读不出这个文件');
  }
  if (bytes.length > 1024 * 1024) {
    return const RfwThemeImportResult(ok: false, message: '主题文件过大（超过 1MB）');
  }
  late final String text;
  try {
    text = utf8.decode(bytes);
  } catch (_) {
    return const RfwThemeImportResult(ok: false, message: '主题文件不是有效 UTF-8 文本');
  }
  return importRfwThemeText(f.name, text);
}
