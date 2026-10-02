import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import '../common/theme.dart';
import 'app_log.dart';
import 'wallpaper_random_service.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// 背景选择类型
enum BackgroundChoice {
  /// 4 个**深色**内置渐变（深邃黑/极光紫/赛博蓝/暖阳橙）
  builtin1,
  builtin2,
  builtin3,
  builtin4,

  /// ── 浅色内置渐变（#5：原来只有「皎月白」1 套，深色有 4 套）──
  /// ⚠️ `moonWhite` 的名字**不能改** —— 它已经写进用户 prefs 了
  /// （`wallpaper_scene_light` 里存的 choice 名字），改名会让老配置读不回来。
  moonWhite,
  mistBlue,
  sageGreen,
  sandBeige,

  /// 用户上传的自定义图片
  custom,
}

/// 壁纸来源类型（决定「壁纸设置」页显示哪一组控件）
enum WallpaperSourceType {
  /// 本地相册图片
  local,

  /// 网络图片 URL（后续可扩展为在线壁纸库）
  network,

  /// 内置渐变色
  gradient,
}

/// 外观模式。与背景联动时，由背景自动决定文字明暗；
/// 手动覆盖时用户可强制浅色/深色文字（自定义壁纸明暗不确定，必须能手动切）。
enum AppearanceMode {
  /// 深色界面（浅色文字）
  dark,

  /// 浅色界面（深色文字）
  light,
}

/// 全局背景服务 - 对应 TV-release CustomWallView
///
/// 4 个内置渐变(深邃黑/极光紫/赛博蓝/暖阳橙) + 皎月白 + 自定义图片 + 网络图片
class BackgroundService extends GetxService {
  static BackgroundService get instance => Get.find<BackgroundService>();

  static const String _choiceKey = 'background_choice';
  static const String _customPathKey = 'background_custom_path';

  // ---- 第 1 期新增持久化 key（不改旧 key 语义，保证老用户升级后行为稳定）----
  static const String _enabledKey = 'wallpaper_enabled';
  static const String _sourceTypeKey = 'wallpaper_source_type';
  static const String _networkUrlKey = 'wallpaper_network_url';
  static const String _networkThumbKey = 'wallpaper_network_thumb';
  static const String _customApiKey = 'wallpaper_custom_api';
  static const String _opacityKey = 'wallpaper_opacity';
  static const String _blurKey = 'wallpaper_blur';
  static const String _overlayKey = 'wallpaper_overlay';
  static const String _appearanceKey = 'appearance_mode';

  /// 每模式场景的持久化前缀：wallpaper_scene_dark / wallpaper_scene_light
  static const String _sceneKeyPrefix = 'wallpaper_scene_';

  final ImagePicker _picker = ImagePicker();

  // ============================================================
  // 每模式背景（外观模式主导）
  // ============================================================
  //
  // 设计：**外观模式是主导者**。
  //   深色模式 → 用「深色那套」背景 + 浅色文字 + 黑遮罩
  //   浅色模式 → 用「浅色那套」背景 + 深色文字 + 白遮罩
  //
  // 与旧实现方向相反：旧的是"背景决定文字颜色"，能选出
  // 「浅色界面 + 深色壁纸」这种不搭的组合。
  //
  // 每套配置独立含：背景选择 / 类型 / 图片路径 / 网络URL / 不透明度 /
  // 模糊 / 遮罩强度。
  final _scenes = <String, WallpaperConfig>{
    'dark': const WallpaperConfig(),
    // 浅色默认皎月白 + 更重的白遮罩（浅色壁纸上深色文字才够对比）
    'light': const WallpaperConfig(
      choice: BackgroundChoice.moonWhite,
      overlay: 0.35,
    ),
  }.obs;

  /// 场景版本号：改动配置后自增，让依赖它的 UI 重建
  final _sceneVersion = 0.obs;

  /// 「当前是不是浅色」—— **唯一判据**，所有调用方都用它。
  ///
  /// ── 🔴 为什么读 [AppBrightness] 而不是 [appearanceMode] ─────────
  /// [appearanceMode] 是 `BackgroundService` 自己的枚举，**只有三处会写它**：
  /// `main.dart` 启动、音乐页的「外观模式」、以及「设置 → 明暗模式」页。
  /// 而用户在**「设置 → 主题与外观 → 明暗模式」**切浅色时
  /// **只改 `ThemeModeStore`** —— 两者会不同步。
  ///
  /// 后果（修复前的真实 bug）：背景层一直按 dark 那套渲染
  /// （深色壁纸 + **黑遮罩**），而那些 Scaffold 是 `Colors.transparent`
  /// 的页面（11 个设置子页 + 阅读各页）**全被罩成黑底** ——
  /// 用户实测："全是浅色模式下的真实情况，底色是黑色的"。
  ///
  /// [AppBrightness.isLight] 由 `ThemeModeStore` 统一驱动（含"跟随系统"
  /// 与壁纸联动），是真正的单一事实来源。
  bool get isLight => AppBrightness.isLight.value;

  /// 当前外观模式对应的场景 key
  ///
  /// ── 🔴 必须读全局真源 [AppBrightness]，不能读 [appearanceMode] ──────
  ///
  /// 原来这里判的是 `appearanceMode.value == AppearanceMode.light`，
  /// 而那个枚举**只有音乐页的「外观模式」会推**（`profile_page.dart` 里
  /// 调 `setAppearanceMode`）；用户在**「设置 → 主题与外观 → 明暗模式」**
  /// 切浅色时**只改 `ThemeModeStore`，从不碰这个枚举** ——
  /// 两者不同步 → 背景层一直按 **dark 那套场景**渲染（深色壁纸 + 黑遮罩）。
  ///
  /// 而所有设置子页 / 阅读页的 Scaffold 都是 `Colors.transparent`
  /// （见 `settings_shared.dart` 的说明："透出全局壁纸层"），
  /// 于是**透明页面全被这层黑背景罩住** ——
  /// 用户实测："全是浅色模式下的真实情况，底色是黑色的"。
  /// 壁纸设置页锁定"正在编辑哪一套场景"用的临时覆盖。
  ///
  /// 为什么需要：写入目标原来按**当前明暗**反推
  /// （[updateActiveScene] → `_saveScene(editingSceneKey)`）。
  /// 用户在壁纸页调滑块期间若明暗发生翻转（系统亮暗变化、别的入口写入），
  /// 后续写入会静默落到**另一套场景**里 —— 表现为"我在浅色下调的模糊，
  /// 切到深色发现被改了"。进入设置页时 [pinEditScene] 固定住目标即可。
  String? _pinnedSceneKey;

  /// 壁纸设置页进入时调用：按进入时的明暗锁定本次编辑的目标场景。
  String pinEditScene() {
    _pinnedSceneKey = isLight ? 'light' : 'dark';
    return _pinnedSceneKey!;
  }

  /// 壁纸设置页退出时调用：解除锁定，恢复"跟随当前明暗"。
  void unpinEditScene() => _pinnedSceneKey = null;

  /// 当前正在编辑/读取的场景 key（受 [pinEditScene] 影响）
  String get editingSceneKey => _pinnedSceneKey ?? (isLight ? 'light' : 'dark');

  /// 正在编辑的场景是否为浅色。
  /// 壁纸页里凡是要按"当前这套场景"取默认值的地方都必须用它，
  /// **不要**用 [isLight]（那是"此刻实际显示的明暗"，编辑期间可能已漂移）。
  bool get editingSceneIsLight => editingSceneKey == 'light';

  String get _sceneKeyForCurrentAppearance => editingSceneKey;

  /// 当前模式那套配置
  WallpaperConfig get activeScene =>
      _scenes[_sceneKeyForCurrentAppearance] ?? const WallpaperConfig();

  /// 取指定模式的配置（设置页切换预览用）
  WallpaperConfig sceneOf(String modeKey) =>
      _scenes[modeKey] ?? const WallpaperConfig();

  /// 写入指定模式的配置
  Future<void> _saveScene(String modeKey, WallpaperConfig cfg) async {
    _scenes[modeKey] = cfg;
    _sceneVersion.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_sceneKeyPrefix$modeKey', jsonEncode(cfg.toJson()));
    AppLog.instance.log(
      '[BackgroundService] 保存 $modeKey 背景: '
      'choice=${cfg.choice.name} source=${cfg.sourceType.name}',
    );
  }

  /// 改当前模式那套配置
  Future<void> updateActiveScene(WallpaperConfig cfg) =>
      _saveScene(_sceneKeyForCurrentAppearance, cfg);

  // ---- 兼容桥接：让旧的 .value 读法仍可用，并建立 Obx 依赖 ----
  void _touch() => _sceneVersion.value;

  _WallpaperValue<BackgroundChoice> get choice {
    _touch();
    return _WallpaperValue(activeScene.choice);
  }

  _WallpaperValue<WallpaperSourceType> get sourceType {
    _touch();
    return _WallpaperValue(activeScene.sourceType);
  }

  _WallpaperValue<String> get networkUrl {
    _touch();
    return _WallpaperValue(activeScene.networkUrl);
  }

  _WallpaperValue<String> get networkThumbUrl {
    _touch();
    return _WallpaperValue(activeScene.networkThumbUrl);
  }

  _WallpaperValue<double> get opacity {
    _touch();
    return _WallpaperValue(activeScene.opacity);
  }

  _WallpaperValue<double> get blur {
    _touch();
    return _WallpaperValue(activeScene.blur);
  }

  _WallpaperValue<double> get overlay {
    _touch();
    return _WallpaperValue(activeScene.overlay);
  }

  _WallpaperValue<String?> get customPath {
    _touch();
    final p = activeScene.customPath;
    return _WallpaperValue(p.isEmpty ? null : p);
  }

  /// 壁纸总开关（全局，不分模式）
  final enabled = true.obs;

  /// 用户自建壁纸库 API 地址（全局）
  final customApiUrl = ''.obs;

  /// 外观模式（**历史遗留，已不再驱动明暗**）。
  ///
  /// 明暗的唯一真源是 `ThemeModeStore` / `AppBrightness`，本服务只**读**它
  /// （见 [isLight] / [editingSceneKey]）来决定渲染哪一套场景。
  /// 这个枚举与 `appearance_mode` 持久化键仅为兼容旧数据保留：
  /// 读它不改变任何行为，写它也不再有任何回调。
  ///
  /// ⚠️ 历史：这里曾有一个 `onAppearanceChanged` 回调，由 `app.dart` 接到
  /// `ThemeModeStore.applyLightFromBackground`，于是壁纸反过来决定全 App 明暗，
  /// 并永久闩死「跟随系统」。详见 `common/theme_mode_store.dart` 顶部说明。
  final appearanceMode = AppearanceMode.dark.obs;

  /// 启动时调用 - 从 SharedPreferences 加载
  @override
  void onInit() {
    super.onInit();
    _loadFromPrefs();
  }

  /// 异步加载：每模式背景配置 + 外观模式 + 全局开关
  ///
  /// 迁移策略：老版本把背景存在一组扁平的 key 里（不分明暗）。
  /// 首次升级时把这组值**当作深色模式的配置**写进新结构 ——
  /// 老用户看到的仍是自己原来那套背景，只是浅色模式有了一套独立默认值。
  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();

    // ---- 外观模式（主导者）----
    final ap = prefs.getString(_appearanceKey);
    appearanceMode.value = ap == 'light'
        ? AppearanceMode.light
        : AppearanceMode.dark;

    // ---- 全局 ----
    enabled.value = prefs.getBool(_enabledKey) ?? true;
    customApiUrl.value = prefs.getString(_customApiKey) ?? '';

    // ---- 每模式配置 ----
    for (final key in const ['dark', 'light']) {
      final raw = prefs.getString('$_sceneKeyPrefix$key');
      if (raw != null && raw.isNotEmpty) {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            _scenes[key] = WallpaperConfig.fromJson(
              decoded.cast<String, Object?>(),
            );
            continue;
          }
        } catch (e) {
          AppLog.instance.log('[BackgroundService] 解析 $key 背景失败: $e');
        }
      }
      // 没有新结构 → 从旧扁平 key 迁移（只对深色做，浅色保留默认皎月白）
      if (key == 'dark' && prefs.getString(_choiceKey) != null) {
        _scenes['dark'] = WallpaperConfig(
          choice: BackgroundChoice.values.firstWhere(
            (e) => e.name == prefs.getString(_choiceKey),
            orElse: () => BackgroundChoice.builtin1,
          ),
          sourceType: WallpaperSourceType.values.firstWhere(
            (e) => e.name == prefs.getString(_sourceTypeKey),
            orElse: () => WallpaperSourceType.gradient,
          ),
          customPath: prefs.getString(_customPathKey) ?? '',
          networkUrl: prefs.getString(_networkUrlKey) ?? '',
          networkThumbUrl: prefs.getString(_networkThumbKey) ?? '',
          opacity: (prefs.getDouble(_opacityKey) ?? 1.0).clamp(0.2, 1.0),
          blur: (prefs.getDouble(_blurKey) ?? 0.0).clamp(0.0, 30.0),
          overlay: (prefs.getDouble(_overlayKey) ?? 0.3).clamp(0.0, 0.8),
        );
        AppLog.instance.log('[BackgroundService] 旧背景配置已迁移为深色模式');
      }
    }

    _sceneVersion.value++;

    AppLog.instance.log(
      '[BackgroundService] 已加载: '
      'appearance=${appearanceMode.value} enabled=${enabled.value} '
      'dark(choice=${sceneOf('dark').choice.name}/'
      '${sceneOf('dark').sourceType.name}) '
      'light(choice=${sceneOf('light').choice.name}/'
      '${sceneOf('light').sourceType.name})',
    );
  }

  // ============================================================
  // 外观模式（主导）
  // ============================================================

  /// 切换外观模式：文字明暗跟着变，**背景也换成该模式自己那套**。
  Future<void> setAppearanceMode(AppearanceMode m) async {
    // 只记录，**不再**回调全局明暗 —— 方向已统一为「外观 → 壁纸」：
    // 渲染哪一套场景由 [isLight] / [editingSceneKey] 决定，本枚举不再参与决策。
    appearanceMode.value = m;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _appearanceKey,
      m == AppearanceMode.light ? 'light' : 'dark',
    );
    AppLog.instance.log('[BackgroundService] 外观模式 → $m（背景随之切换）');
  }

  // ============================================================
  // 壁纸参数 setter（都只影响当前模式那一套）
  // ============================================================

  Future<void> setEnabled(bool v) async {
    enabled.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, v);
  }

  Future<void> setSourceType(WallpaperSourceType t) async {
    final cur = activeScene;
    // 切到图片类时把 choice 归为 custom，保证渲染分支走对
    final nextChoice = t == WallpaperSourceType.gradient
        ? cur.choice
        : BackgroundChoice.custom;
    await updateActiveScene(cur.copyWith(sourceType: t, choice: nextChoice));
  }

  Future<void> setCustomApiUrl(String url) async {
    customApiUrl.value = url.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customApiKey, customApiUrl.value);
  }

  Future<void> setNetworkUrl(String url, {String thumbUrl = ''}) async {
    await updateActiveScene(
      activeScene.copyWith(
        networkUrl: url.trim(),
        networkThumbUrl: thumbUrl.trim(),
        // 切成固定 URL 时清掉随机源，避免两个来源打架
        randomSourceId: '',
        sourceType: WallpaperSourceType.network,
        choice: BackgroundChoice.custom,
      ),
    );
  }

  // ============================================================
  // 随机图源（每次取一张，所以存 id + 内存里放当前这张的字節）
  // ============================================================

  /// 当前随机源取回来的图片字节（**只放内存**）。
  ///
  /// ── 为什么要有这个缓存 ────────────────────────────────────────
  /// `buildBackground()` 是**每次重建都会跑**的（它包在
  /// `ValueListenableBuilder` + `Obx` 里）。如果在那里直接发网络请求，
  /// 会变成"每帧一个请求"。所以取图在**设置时/启动时**做一次，
  /// 结果放这里，`buildBackground` 只读内存。
  Uint8List? _randomImageBytes;

  /// 当前随机源 id（与 [WallpaperConfig.randomSourceId] 对应）
  String _randomSourceId = '';

  /// 取图中
  bool _randomLoading = false;
  bool get randomLoading => _randomLoading;

  /// 当前这张随机图（设置页预览用；null = 还没取到）
  Uint8List? get randomImagePreview => _randomImageBytes;

  /// 选一个随机图源：设好类型，并**立刻取一张**。
  /// 返回是否取图成功（UI 据此提示）。
  Future<bool> setRandomSource(String sourceId) async {
    _randomSourceId = sourceId;
    await updateActiveScene(
      activeScene.copyWith(
        randomSourceId: sourceId,
        sourceType: WallpaperSourceType.network,
        choice: BackgroundChoice.custom,
        networkUrl: '',
        networkThumbUrl: '',
      ),
    );
    return refreshRandomImage();
  }

  /// 重新取一张随机图（切源 / 用户点"换一张" / 启动时调用）
  Future<bool> refreshRandomImage() async {
    final id =
        _randomSourceId.isNotEmpty ? _randomSourceId : activeScene.randomSourceId;
    if (id.isEmpty) return false;
    final src = RandomImageCatalog.byId(id);
    if (src == null) {
      AppLog.instance.log('[Background] 未知随机源 id=$id');
      return false;
    }
    _randomLoading = true;
    _sceneVersion.value++;
    try {
      final r = await WallpaperRandomService.instance.fetchOne(src);
      if (r.ok && r.bytes != null) {
        _randomImageBytes = r.bytes;
        _randomSourceId = id;
        AppLog.instance.log(
            '[Background] 随机源 ${src.name} 取图成功 ${r.bytes!.length} bytes');
        return true;
      }
      AppLog.instance.log('[Background] 随机源 ${src.name} 取图失败: ${r.error}');
      // 失败**保留上一张**（不清空），避免背景突然变空
      return false;
    } finally {
      _randomLoading = false;
      _sceneVersion.value++;
    }
  }

  /// 启动时调用：若当前场景配的是随机源，取一张新的
  ///（于是每次冷启动背景都不一样）
  Future<void> warmUpRandomImageIfNeeded() async {
    final id = activeScene.randomSourceId;
    if (id.isEmpty) return;
    _randomSourceId = id;
    await refreshRandomImage();
  }

  Future<void> setOpacity(double v) async {
    await updateActiveScene(activeScene.copyWith(opacity: v.clamp(0.2, 1.0)));
  }

  Future<void> setBlur(double v) async {
    await updateActiveScene(activeScene.copyWith(blur: v.clamp(0.0, 30.0)));
  }

  /// 遮罩：不再分「深色/浅色遮罩」两个字段，各模式各自存一个值
  ///（浅色模式默认更重，见 _scenes 初始值）
  Future<void> setOverlay(double v) async {
    await updateActiveScene(activeScene.copyWith(overlay: v.clamp(0.0, 0.8)));
  }

  /// 设置内置背景（渐变）
  Future<void> setBuiltin(BackgroundChoice c) async {
    await updateActiveScene(
      activeScene.copyWith(
        choice: c,
        sourceType: WallpaperSourceType.gradient,
      ),
    );
    AppLog.instance.log(
      '[BackgroundService] setBuiltin: $c '
      '(${_sceneKeyForCurrentAppearance} 模式)',
    );
  }

  /// 设置自定义背景 - 复制到应用文档目录并保存路径
  Future<bool> setCustomImage(String sourcePath) async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final wallDir = Directory('${docs.path}/wallpaper');
      if (!wallDir.existsSync()) wallDir.createSync(recursive: true);
      final ext = sourcePath.contains('.')
          ? sourcePath.substring(sourcePath.lastIndexOf('.'))
          : '.jpg';
      final destPath =
          '${wallDir.path}/bg_${DateTime.now().millisecondsSinceEpoch}$ext';
      await File(sourcePath).copy(destPath);

      // 删除旧图（只删当前模式那套引用的，避免误删另一模式还在用的图）
      final oldPath = activeScene.customPath;
      if (oldPath.isNotEmpty && oldPath != destPath) {
        try {
          final f = File(oldPath);
          if (f.existsSync()) f.deleteSync();
        } catch (e) {
          /* ignore */
        }
      }

      await updateActiveScene(
        activeScene.copyWith(
          customPath: destPath,
          choice: BackgroundChoice.custom,
          sourceType: WallpaperSourceType.local,
        ),
      );
      AppLog.instance.log('[BackgroundService] setCustomImage: $destPath');
      return true;
    } catch (e) {
      AppLog.instance.log('[BackgroundService] setCustomImage 失败: $e');
      return false;
    }
  }

  /// 清除当前模式的自定义背景 - 回到默认(builtin1)
  Future<void> clearCustom() async {
    final oldPath = activeScene.customPath;
    if (oldPath.isNotEmpty) {
      try {
        final f = File(oldPath);
        if (f.existsSync()) f.deleteSync();
      } catch (e) {
        /* ignore */
      }
    }
    await updateActiveScene(
      activeScene.copyWith(
        customPath: '',
        // 🔴 必须按当前明暗选默认渐变。
        // 原来这里无条件写 `builtin1`（深邃黑 #0A0A0F 系），于是**浅色模式**下
        // 点「移除当前图片」会把背景换成近黑底，叠 35% 白遮罩仍是深灰，
        // 而文字是深色 → 整页基本不可读。`_resetAll` 里有补偿，这里漏了。
        choice: isLight ? BackgroundChoice.moonWhite : BackgroundChoice.builtin1,
        sourceType: WallpaperSourceType.gradient,
        networkUrl: '',
        networkThumbUrl: '',
      ),
    );
  }

  /// 弹出图片选择器 - 选完图后自动 setCustomImage
  Future<bool> pickFromGallery() async {
    try {
      final picked = await _picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 4096,
        maxHeight: 4096,
        imageQuality: 92,
      );
      if (picked == null) return false;
      return await setCustomImage(picked.path);
    } catch (e) {
      AppLog.instance.log('[BackgroundService] pickFromGallery 失败: $e');
      return false;
    }
  }

  // ============================================================
  // 4 个内置渐变定义 (深色系)
  // ============================================================

  /// 深邃黑
  static const List<Color> _builtin1 = [
    Color(0xFF0A0A0F),
    Color(0xFF14141C),
    Color(0xFF0A0A0F),
  ];

  /// 极光紫
  static const List<Color> _builtin2 = [
    Color(0xFF1A0A2E),
    Color(0xFF4A1B6B),
    Color(0xFF7B2C8C),
  ];

  /// 赛博蓝
  static const List<Color> _builtin3 = [
    Color(0xFF0A1230),
    Color(0xFF1E3A8A),
    Color(0xFF2563EB),
  ];

  /// 暖阳橙
  static const List<Color> _builtin4 = [
    Color(0xFF2A0E0A),
    Color(0xFF7C2D12),
    Color(0xFFEA580C),
  ];

  /// 皎月白 —— 已统一为「宣纸色系」（跟随水墨书香调色板，浅色底色不再发灰）
  /// #F7F5F1 宣纸米白 → #F1EDE3 → #E9E3D6，与 JellyPalette.backgroundLight 同源观感。
  static const List<Color> _moonWhite = [
    Color(0xFFF7F5F1),
    Color(0xFFF1EDE3),
    Color(0xFFE9E3D6),
  ];

  /// 晨雾蓝：#5 补的浅色渐变之一
  static const List<Color> _mistBlue = [
    Color(0xFFF2F6FA),
    Color(0xFFE2EBF3),
    Color(0xFFCFDCE8),
  ];

  /// 竹青：#5 补的浅色渐变之二
  static const List<Color> _sageGreen = [
    Color(0xFFF3F7F1),
    Color(0xFFE4EDE0),
    Color(0xFFD2DFCC),
  ];

  /// 暖沙：#5 补的浅色渐变之三
  static const List<Color> _sandBeige = [
    Color(0xFFFAF6F0),
    Color(0xFFF0E8DB),
    Color(0xFFE2D6C3),
  ];

  List<Color> _getGradientForChoice(BackgroundChoice c) {
    switch (c) {
      case BackgroundChoice.builtin1:
        return _builtin1;
      case BackgroundChoice.builtin2:
        return _builtin2;
      case BackgroundChoice.builtin3:
        return _builtin3;
      case BackgroundChoice.builtin4:
        return _builtin4;
      case BackgroundChoice.moonWhite:
        return _moonWhite;
      case BackgroundChoice.mistBlue:
        return _mistBlue;
      case BackgroundChoice.sageGreen:
        return _sageGreen;
      case BackgroundChoice.sandBeige:
        return _sandBeige;
      case BackgroundChoice.custom:
        return _builtin1;
    }
  }

  /// 构建背景 widget - 对应 TV-release CustomWallView
  ///
  /// 第 1 期：壁纸的不透明度 / 模糊 / 深色遮罩改由服务自身的响应式字段控制
  /// （设置页可调），不再依赖调用方传入的固定值。
  ///
  /// [overlayAlpha]: 兼容旧调用方的兜底遮罩值；仅当服务字段尚未初始化时使用。
  Widget buildBackground({
    double overlayAlpha = 0.3,
    Widget? child,
  }) {
    // ── ⚠️ 这里原来是 `Obx(() { ... })`，换成 ValueListenableBuilder ──
    //
    // 原因：明暗现在读 [AppBrightness.isLight]，它是**普通 `ValueNotifier`**
    // 而不是 GetX observable。`Obx` 读不到任何 `.obs` 时会抛
    // "[Get] the improper use of a GetX has been detected"，
    // 整棵子树会变成 ErrorWidget（整个背景层消失）。
    //
    // 场景数据（`_scenes`）仍由 `_sceneVersion` 驱动，所以两层嵌套：
    // 外层听明暗、内层听场景版本。
    return ValueListenableBuilder<bool>(
      valueListenable: AppBrightness.isLight,
      builder: (context, isLightNow, __) => Obx(() {
        // 当前模式那套配置（外观主导：浅色/深色各有独立的墙纸与效果参数）
        final scene = activeScene;
        final isLight = isLightNow;
        // 遮罩色跟着明暗走：
        // - 深色界面 → 黑色遮罩（压暗壁纸，保证浅色文字可读）
        // - 浅色界面 → 白色遮罩（提亮壁纸，保证深色文字可读）
        //
        // 遮罩值取自当前模式那套配置（浅色默认更重），
        // 所以「浅色界面 + 亮壁纸」不会再出现深色文字看不清。
        final ov = scene.overlay;
        final overlayColor = isLight
            ? const Color(0xFFFFFFFF)
            : const Color(0xFF000000);
        final enabledNow = enabled.value;

        // ---- 图片类壁纸（本地 / 网络）----
        if (enabledNow) {
          Widget? image;
          if (scene.sourceType == WallpaperSourceType.local &&
              scene.customPath.isNotEmpty) {
            final file = File(scene.customPath);
            if (file.existsSync()) {
              // 用 LayoutBuilder 取实际可用宽度做解码降采样：
              // 选图时允许 4096×4096（约 64MB 位图），按原尺寸常驻内存叠加
              // 视频播放器在 iOS 上有 OOM 风险。
              image = LayoutBuilder(
                builder: (context, constraints) {
                  final dpr =
                      MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
                  final budget = (constraints.maxWidth * dpr).round();
                  return Image.file(
                    file,
                    fit: BoxFit.cover,
                    cacheWidth: budget > 0 ? budget : null,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  );
                },
              );
            }
          } else if (_randomImageBytes != null &&
              _randomImageBytes!.isNotEmpty &&
              scene.randomSourceId.isNotEmpty) {
            // ── 随机图源：用内存里那张（取图在设置时/启动时做过）────────
            // ⚠️ 这里**绝不能**发网络请求：buildBackground 每次重建都会跑，
            // 发了就是"每帧一个请求"。所以只读内存里的字节。
            image = Image.memory(
              _randomImageBytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true, // 换图时不留白
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
            );
          } else if (scene.sourceType == WallpaperSourceType.network &&
              scene.networkUrl.isNotEmpty) {
            // 同样必须走场景字段（见上面 scene.choice 的说明）
            image = CachedNetworkImage(
              imageUrl: scene.networkUrl,
              fit: BoxFit.cover,
              placeholder: (_, __) => const SizedBox.shrink(),
              errorWidget: (_, __, ___) => const SizedBox.shrink(),
            );
          }

          if (image != null) {
            return Stack(
              fit: StackFit.expand,
              children: [
                Opacity(
                  // 用场景的 opacity（不再用全局 opacity.value）
                  opacity: scene.opacity.clamp(0.2, 1.0),
                  child: _applyBlur(image, scene.blur),
                ),
                if (ov > 0)
                  Container(color: overlayColor.withValues(alpha: ov)),
                if (child != null) child,
              ],
            );
          }
        }

        // ---- 内置渐变（也是图片加载失败/关闭壁纸时的兜底）----
        //
        // 🔴 必须用 `scene.choice`（当前场景自己的），**不能用 `choice.value`**：
        // 那几个 `.value` 是"兼容桥接"的全局字段，只反映**最近一次保存的
        // 那套场景**。于是"深色下选了某壁纸 → 切浅色"时，
        // 浅色场景里存的 `moonWhite` 根本读不到，浅色背景就错了
        //（用户实测："浅色模式的皎月白壁纸没生效"）。
        return _buildGradientBackground(
          colors: _getGradientForChoice(scene.choice),
          overlayAlpha: ov,
          overlayColor: overlayColor,
          child: child,
        );
      }),
    );
  }

  /// 模糊程度 0 时不做任何包装（省一次 saveLayer，iOS 上开销明显）
  Widget _applyBlur(Widget w, [double? sceneBlur]) {
    final b = sceneBlur ?? blur.value;
    if (b <= 0.1) return w;
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: b, sigmaY: b),
      child: w,
    );
  }

  Widget _buildGradientBackground({
    required List<Color> colors,
    double overlayAlpha = 0.3,

    /// 遮罩色：**浅色模式必须传白色**。
    ///
    /// 🔴 原来这里写死 `Colors.black`，于是浅色模式（皎月白这类亮壁纸）
    /// 被压了一层 35% 黑遮罩 → **整页发灰**，而文字又是深色的，
    /// 结果"灰蒙蒙、什么都看不清"。
    /// `buildBackground` 里其实已经算好了 `overlayColor`
    /// （浅色白 / 深色黑），只是**没传进来**。
    required Color overlayColor,
    Widget? child,
  }) {
    // 装饰圆的基色：浅色壁纸（皎月白/晨雾蓝…）上白圆完全不可见，
    // 装饰效果丢失；按明暗换成"深色阴影 / 白色高光"。
    final decoBase = AppBrightness.isLight.value ? Colors.black : Colors.white;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 主渐变
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: colors,
            ),
          ),
        ),
        // 装饰圆形（弱化底部，避免像一截背景压住内容）
        Positioned(
          top: -120,
          right: -80,
          child: _buildCircle(
            size: 420,
            color: decoBase.withValues(alpha: 0.04),
          ),
        ),
        Positioned(
          bottom: -220,
          left: -140,
          child: _buildCircle(
            size: 420,
            color: decoBase.withValues(alpha: 0.02),
          ),
        ),
        Positioned(
          top: 200,
          right: -60,
          child: _buildCircle(
            size: 220,
            color: decoBase.withValues(alpha: 0.05),
          ),
        ),
        // 蒙版 (保证文字可读)：颜色跟随明暗 —— 浅色白、深色黑
        if (overlayAlpha > 0)
          Container(color: overlayColor.withValues(alpha: overlayAlpha)),
        if (child != null) child,
      ],
    );
  }

  Widget _buildCircle({required double size, required Color color}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
      ),
    );
  }

  /// 当前选择的内置背景名 (用于设置页展示)
  /// 设置页展示用：当前实际生效的壁纸名称。
  ///
  /// 与 [currentDisplayName] 的区别：图片类壁纸的 choice 都是 custom，
  /// 只看 choice 无法区分「本地图片」和「网络图片」，会误导用户。
  String get wallpaperDisplayName {
    if (!enabled.value) return '已关闭';
    switch (sourceType.value) {
      case WallpaperSourceType.local:
        return customPath.value?.isNotEmpty == true ? '本地图片' : '未选择图片';
      case WallpaperSourceType.network:
        return networkUrl.value.isNotEmpty ? '网络图片' : '未设置链接';
      case WallpaperSourceType.gradient:
        return currentDisplayName;
    }
  }

  String get currentDisplayName {
    switch (choice.value) {
      case BackgroundChoice.builtin1:
        return '深邃黑';
      case BackgroundChoice.builtin2:
        return '极光紫';
      case BackgroundChoice.builtin3:
        return '赛博蓝';
      case BackgroundChoice.builtin4:
        return '暖阳橙';
      case BackgroundChoice.moonWhite:
        return '皎月白';
      case BackgroundChoice.mistBlue:
        return '晨雾蓝';
      case BackgroundChoice.sageGreen:
        return '竹青';
      case BackgroundChoice.sandBeige:
        return '暖沙';
      case BackgroundChoice.custom:
        return '自定义图片';
    }
  }

  static final List<({String name, BackgroundChoice choice, List<Color> colors})>
      _lightPreviews = [
    (name: '皎月白', choice: BackgroundChoice.moonWhite, colors: _moonWhite),
    (name: '晨雾蓝', choice: BackgroundChoice.mistBlue, colors: _mistBlue),
    (name: '竹青', choice: BackgroundChoice.sageGreen, colors: _sageGreen),
    (name: '暖沙', choice: BackgroundChoice.sandBeige, colors: _sandBeige),
  ];

  static final List<({String name, BackgroundChoice choice, List<Color> colors})>
      _darkPreviews = [
    (name: '深邃黑', choice: BackgroundChoice.builtin1, colors: _builtin1),
    (name: '极光紫', choice: BackgroundChoice.builtin2, colors: _builtin2),
    (name: '赛博蓝', choice: BackgroundChoice.builtin3, colors: _builtin3),
    (name: '暖阳橙', choice: BackgroundChoice.builtin4, colors: _builtin4),
  ];

  /// 内置背景的预览色（设置页的预览小方块用）。
  ///
  /// #5：按**当前明暗**只列出对应那 4 套 ——
  /// 深色列深邃黑/极光紫/赛博蓝/暖阳橙，浅色列皎月白/晨雾蓝/竹青/暖沙。
  /// 混着列没意义：浅色界面套一个深色壁纸，文字对比会很难看。
  static List<({String name, BackgroundChoice choice, List<Color> colors})>
      get builtinPreviews =>
          AppBrightness.isLight.value ? _lightPreviews : _darkPreviews;

  /// 按**正在编辑的场景**取那 4 套 —— 壁纸设置页必须用这个。
  ///
  /// 用 [builtinPreviews] 的话，编辑期间明暗一旦翻转，选图列表会跟着
  /// 换成另一套，用户会把浅色渐变选进深色场景（见 [pinEditScene]）。
  List<({String name, BackgroundChoice choice, List<Color> colors})>
      get builtinPreviewsForEditing =>
          editingSceneIsLight ? _lightPreviews : _darkPreviews;
}

/// 单个外观模式下的壁纸配置。
///
/// 深浅两套各自独立，所以「切换外观 → 背景整组跟着换」不需要额外分支。
class WallpaperConfig {
  final BackgroundChoice choice;
  final WallpaperSourceType sourceType;
  final String customPath;
  final String networkUrl;
  final String networkThumbUrl;

  /// **随机图源 id**（见 `RandomImageCatalog`）。
  ///
  /// 随机图 API 每次请求返回不同的图，所以不能把 URL 存下来当结果 ——
  /// 存的是"源 id"，每次启动/点刷新时重新取一张，于是每次开 App
  /// 背景都不一样。
  final String randomSourceId;
  final double opacity;
  final double blur;
  final double overlay;

  const WallpaperConfig({
    this.choice = BackgroundChoice.builtin1,
    this.sourceType = WallpaperSourceType.gradient,
    this.customPath = '',
    this.networkUrl = '',
    this.networkThumbUrl = '',
    this.randomSourceId = '',
    this.opacity = 1.0,
    this.blur = 0.0,
    this.overlay = 0.3,
  });

  WallpaperConfig copyWith({
    BackgroundChoice? choice,
    WallpaperSourceType? sourceType,
    String? customPath,
    String? networkUrl,
    String? networkThumbUrl,
    String? randomSourceId,
    double? opacity,
    double? blur,
    double? overlay,
  }) {
    return WallpaperConfig(
      choice: choice ?? this.choice,
      sourceType: sourceType ?? this.sourceType,
      customPath: customPath ?? this.customPath,
      networkUrl: networkUrl ?? this.networkUrl,
      networkThumbUrl: networkThumbUrl ?? this.networkThumbUrl,
      randomSourceId: randomSourceId ?? this.randomSourceId,
      opacity: opacity ?? this.opacity,
      blur: blur ?? this.blur,
      overlay: overlay ?? this.overlay,
    );
  }

  Map<String, Object?> toJson() => {
    'choice': choice.name,
    'sourceType': sourceType.name,
    'customPath': customPath,
    'networkUrl': networkUrl,
    'networkThumbUrl': networkThumbUrl,
    'randomSourceId': randomSourceId,
    'opacity': opacity,
    'blur': blur,
    'overlay': overlay,
  };

  static WallpaperConfig fromJson(Map<String, Object?>? json) {
    if (json == null) return const WallpaperConfig();
    double d(Object? v, double fallback) => v is num ? v.toDouble() : fallback;
    String s(Object? v) => v is String ? v : '';
    return WallpaperConfig(
      choice: BackgroundChoice.values.firstWhere(
        (e) => e.name == s(json['choice']),
        // 兜底也要按明暗选：浅色场景解析失败/choice 名变更时不能退回深色渐变，
        // 否则会出现"浅色界面 + 深邃黑背景"（`moonWhite` 改名踩过一次）。
        orElse: () => AppBrightness.isLight.value
            ? BackgroundChoice.moonWhite
            : BackgroundChoice.builtin1,
      ),
      sourceType: WallpaperSourceType.values.firstWhere(
        (e) => e.name == s(json['sourceType']),
        orElse: () => WallpaperSourceType.gradient,
      ),
      customPath: s(json['customPath']),
      networkUrl: s(json['networkUrl']),
      networkThumbUrl: s(json['networkThumbUrl']),
      randomSourceId: s(json['randomSourceId']),
      opacity: d(json['opacity'], 1.0).clamp(0.2, 1.0),
      blur: d(json['blur'], 0.0).clamp(0.0, 30.0),
      overlay: d(json['overlay'], 0.3).clamp(0.0, 0.8),
    );
  }
}

/// 「只读 Rx 外观」包装。
///
/// 目的：让壁纸设置页里 `bg.opacity.value` 这类旧写法继续可用，
/// 而不必把每模式配置整组换成 Rx（那会让序列化很啰嗦）。
/// 读取前 BackgroundService 已 `_touch()` 过版本号，所以 Obx 能建立依赖。
class _WallpaperValue<T> {
  final T value;
  const _WallpaperValue(this.value);
}
