import 'dart:io';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'app_log.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../common/theme.dart' show AppBrightness;

/// 背景选择类型
enum BackgroundChoice {
  /// 4 个内置渐变(1-4) + 皎月白
  builtin1,
  builtin2,
  builtin3,
  builtin4,
  moonWhite,

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
  static const String _lightOverlayKey = 'wallpaper_light_overlay';
  static const String _appearanceKey = 'appearance_mode';
  static const String _manualKey = 'appearance_manual_override';

  final ImagePicker _picker = ImagePicker();

  /// 当前背景选择
  final choice = BackgroundChoice.builtin1.obs;

  /// 自定义背景图片路径(仅 choice == custom 时有效)
  final customPath = RxnString();

  // ============================================================
  // 第 1 期：壁纸设置
  // ============================================================

  /// 壁纸总开关（关闭则回到纯内置渐变，忽略图片与效果参数）
  final enabled = true.obs;

  /// 壁纸来源类型
  final sourceType = WallpaperSourceType.gradient.obs;

  /// 网络壁纸 URL（原图，实际渲染用）
  final networkUrl = ''.obs;

  /// 网络壁纸的列表缩略图 URL。
  ///
  /// 单独存一份的原因：在线壁纸库的原图常见 1600×2400 甚至 5000×3333，
  /// 网格里若直接用它做缩略图，iOS 会同时解码几十张大图 → OOM。
  /// 为空时回退用 [networkUrl]。
  final networkThumbUrl = ''.obs;

  /// 用户自建壁纸库 API 地址（在线壁纸库 → 自建源用）
  final customApiUrl = ''.obs;

  /// 壁纸不透明度 0.2 ~ 1.0
  final opacity = 1.0.obs;

  /// 模糊程度（sigma）0 ~ 30
  final blur = 0.0.obs;

  /// 深色遮罩 0 ~ 0.8（深色界面用：压暗壁纸，保证浅色文字可读）
  final overlay = 0.3.obs;

  /// 浅色遮罩 0 ~ 0.8（浅色界面用：提亮壁纸，保证深色文字可读）
  ///
  /// 默认 0.45：浅色场景下文字是深色、壁纸多为浅色，需要更强的干预才够对比；
  /// 深色场景默认 0.3 即可（浅色文字在暗背景上对比天然充足）。
  final lightOverlay = 0.45.obs;

  /// 外观模式（文字明暗）
  final appearanceMode = AppearanceMode.dark.obs;

  /// 是否手动覆盖文字明暗；false = 由背景自动推导（方案 A）
  final manualAppearance = false.obs;

  /// 外观变化回调 —— 由 App 层注入，避免服务层直接依赖
  /// ThemeModeStore 造成循环依赖。
  void Function(bool isLight)? onAppearanceChanged;

  /// 启动时调用 - 从 SharedPreferences 加载
  @override
  void onInit() {
    super.onInit();
    _loadFromPrefs();
  }

  /// 异步加载 SharedPreferences 中的背景选择 + 自定义图片路径 + 壁纸参数
  Future<void> _loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_choiceKey);
    if (saved != null) {
      choice.value = BackgroundChoice.values.firstWhere(
        (e) => e.name == saved,
        orElse: () => BackgroundChoice.builtin1,
      );
    }
    customPath.value = prefs.getString(_customPathKey);

    // ---- 第 1 期参数（缺省值保证老用户行为不变）----
    enabled.value = prefs.getBool(_enabledKey) ?? true;
    final st = prefs.getString(_sourceTypeKey);
    sourceType.value = WallpaperSourceType.values.firstWhere(
      (e) => e.name == st,
      orElse: () => WallpaperSourceType.gradient,
    );
    networkUrl.value = prefs.getString(_networkUrlKey) ?? '';
    networkThumbUrl.value = prefs.getString(_networkThumbKey) ?? '';
    customApiUrl.value = prefs.getString(_customApiKey) ?? '';
    opacity.value = (prefs.getDouble(_opacityKey) ?? 1.0).clamp(0.2, 1.0);
    blur.value = (prefs.getDouble(_blurKey) ?? 0.0).clamp(0.0, 30.0);
    overlay.value = (prefs.getDouble(_overlayKey) ?? 0.3).clamp(0.0, 0.8);
    lightOverlay.value =
        (prefs.getDouble(_lightOverlayKey) ?? 0.45).clamp(0.0, 0.8);

    // 外观：手动值优先；否则由背景自动推导（方案 A）
    manualAppearance.value = prefs.getBool(_manualKey) ?? false;
    final ap = prefs.getString(_appearanceKey);
    if (ap != null) {
      appearanceMode.value = ap == 'light'
          ? AppearanceMode.light
          : AppearanceMode.dark;
    }
    if (!manualAppearance.value) {
      final derived = choiceIsLight(choice.value);
      appearanceMode.value =
          derived ? AppearanceMode.light : AppearanceMode.dark;
    }
    _notifyAppearance();

    AppLog.instance.log('[BackgroundService] 已加载: choice=${choice.value}, '
        'source=${sourceType.value}, enabled=${enabled.value}, '
        'appearance=${appearanceMode.value}, manual=${manualAppearance.value}, '
        'customPath=${customPath.value}');
  }

  // ============================================================
  // 外观联动（方案 A）
  // ============================================================

  /// 该背景是否属于「浅色底」→ 需要深色文字
  static bool choiceIsLight(BackgroundChoice c) =>
      c == BackgroundChoice.moonWhite;

  /// 把当前外观推给 App 层（注入的回调）
  void _notifyAppearance() {
    onAppearanceChanged?.call(appearanceMode.value == AppearanceMode.light);
  }

  /// 背景变化后按方案 A 自动推导外观（手动覆盖时不生效）
  Future<void> _applyDerivedAppearance() async {
    if (manualAppearance.value) return;
    appearanceMode.value =
        choiceIsLight(choice.value) ? AppearanceMode.light : AppearanceMode.dark;
    _notifyAppearance();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _appearanceKey, appearanceMode.value == AppearanceMode.light ? 'light' : 'dark');
  }

  /// 手动设置外观模式（会打开手动覆盖标记）
  Future<void> setAppearanceMode(AppearanceMode m, {bool manual = true}) async {
    appearanceMode.value = m;
    manualAppearance.value = manual;
    _notifyAppearance();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appearanceKey, m == AppearanceMode.light ? 'light' : 'dark');
    await prefs.setBool(_manualKey, manual);
    AppLog.instance.log('[BackgroundService] setAppearanceMode: $m manual=$manual');
  }

  /// 恢复「跟随背景自动决定文字颜色」
  Future<void> clearAppearanceOverride() async {
    manualAppearance.value = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_manualKey, false);
    await _applyDerivedAppearance();
    AppLog.instance.log('[BackgroundService] 已恢复自动外观推导');
  }

  // ============================================================
  // 壁纸参数 setter
  // ============================================================

  Future<void> setEnabled(bool v) async {
    enabled.value = v;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_enabledKey, v);
  }

  Future<void> setSourceType(WallpaperSourceType t) async {
    sourceType.value = t;
    // 类型切换时同步 choice，保证外观推导与旧字段一致
    if (t == WallpaperSourceType.gradient) {
      // 渐变背景明暗可推导（如皎月白=浅色底）→ 重新套用推导结果。
      // 必须显式调用：从图片类切回来时，外观还停在图片的"深色假设"上。
      await _applyDerivedAppearance();
    } else if (t == WallpaperSourceType.local) {
      choice.value = BackgroundChoice.custom;
    } else {
      choice.value = BackgroundChoice.custom;
      // 网络壁纸明暗未知 → 默认浅色文字（深色界面），用户可手动覆盖
      await _applyDerivedAppearanceForImage();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sourceTypeKey, t.name);
    await prefs.setString(_choiceKey, choice.value.name);
  }

  /// 图片类壁纸的默认外观：深色底假设（浅色文字），避免选中亮图后白底白字
  Future<void> _applyDerivedAppearanceForImage() async {
    if (manualAppearance.value) return;
    appearanceMode.value = AppearanceMode.dark;
    _notifyAppearance();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_appearanceKey, 'dark');
  }

  Future<void> setCustomApiUrl(String url) async {
    customApiUrl.value = url.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_customApiKey, customApiUrl.value);
  }

  Future<void> setNetworkUrl(String url, {String thumbUrl = ''}) async {
    networkUrl.value = url.trim();
    networkThumbUrl.value = thumbUrl.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_networkUrlKey, networkUrl.value);
    await prefs.setString(_networkThumbKey, networkThumbUrl.value);
  }

  Future<void> setOpacity(double v) async {
    opacity.value = v.clamp(0.2, 1.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_opacityKey, opacity.value);
  }

  Future<void> setBlur(double v) async {
    blur.value = v.clamp(0.0, 30.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_blurKey, blur.value);
  }

  Future<void> setOverlay(double v) async {
    overlay.value = v.clamp(0.0, 0.8);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_overlayKey, overlay.value);
  }

  Future<void> setLightOverlay(double v) async {
    lightOverlay.value = v.clamp(0.0, 0.8);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_lightOverlayKey, lightOverlay.value);
  }

  /// 设置内置背景（渐变）
  Future<void> setBuiltin(BackgroundChoice c) async {
    choice.value = c;
    sourceType.value = WallpaperSourceType.gradient;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_choiceKey, c.name);
    await prefs.setString(_sourceTypeKey, WallpaperSourceType.gradient.name);
    await _applyDerivedAppearance();
    AppLog.instance.log('[BackgroundService] setBuiltin: $c');
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

      // 删除旧的自定义背景
      final oldPath = customPath.value;
      if (oldPath != null && oldPath != destPath) {
        try {
          final f = File(oldPath);
          if (f.existsSync()) f.deleteSync();
        } catch (e) { /* ignore */ }
      }

      customPath.value = destPath;
      choice.value = BackgroundChoice.custom;
      sourceType.value = WallpaperSourceType.local;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_choiceKey, BackgroundChoice.custom.name);
      await prefs.setString(_sourceTypeKey, WallpaperSourceType.local.name);
      await prefs.setString(_customPathKey, destPath);
      await _applyDerivedAppearanceForImage();
      AppLog.instance.log('[BackgroundService] setCustomImage: $destPath');
      return true;
    } catch (e) {
      AppLog.instance.log('[BackgroundService] setCustomImage 失败: $e');
      return false;
    }
  }

  /// 清除自定义背景 - 回到默认(builtin1)
  Future<void> clearCustom() async {
    final oldPath = customPath.value;
    if (oldPath != null) {
      try {
        final f = File(oldPath);
        if (f.existsSync()) f.deleteSync();
      } catch (e) { /* ignore */ }
    }
    customPath.value = null;
    await setBuiltin(BackgroundChoice.builtin1);
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

  /// 皎月白
  static const List<Color> _moonWhite = [
    Color(0xFFF7F4EF),
    Color(0xFFE8E4DC),
    Color(0xFFD9D4C8),
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
    return Obx(() {
      final isLight = AppBrightness.isLight.value;
      // 遮罩要跟着明暗走：
      // - 深色界面 → 黑色遮罩（压暗壁纸，保证浅色文字可读）
      // - 浅色界面 → 白色遮罩（提亮壁纸，保证深色文字可读）
      //
      // 只用黑色遮罩是之前的缺陷：浅色壁纸 + 浅色界面时，壁纸原样铺满，
      // 深色文字压在花哨的图片上同样看不清。
      final ov = isLight
          ? (lightOverlay.value > 0 ? lightOverlay.value : 0.45)
          : (overlay.value > 0 ? overlay.value : overlayAlpha);
      final overlayColor =
          isLight ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
      final enabledNow = enabled.value;

      // ---- 图片类壁纸（本地 / 网络）----
      if (enabledNow) {
        Widget? image;
        if (sourceType.value == WallpaperSourceType.local &&
            customPath.value != null) {
          final file = File(customPath.value!);
          if (file.existsSync()) {
            // 用 LayoutBuilder 取实际可用宽度做解码降采样：
            // 选图时允许 4096×4096（约 64MB 位图），按原尺寸常驻内存叠加
            // 视频播放器在 iOS 上有 OOM 风险。
            image = LayoutBuilder(
              builder: (context, constraints) {
                final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
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
        } else if (sourceType.value == WallpaperSourceType.network &&
            networkUrl.value.isNotEmpty) {
          image = CachedNetworkImage(
            imageUrl: networkUrl.value,
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
                opacity: opacity.value.clamp(0.2, 1.0),
                child: _applyBlur(image),
              ),
              if (ov > 0)
                Container(color: overlayColor.withValues(alpha: ov)),
              if (child != null) child,
            ],
          );
        }
      }

      // ---- 内置渐变（也是图片加载失败/关闭壁纸时的兜底）----
      return _buildGradientBackground(
        colors: _getGradientForChoice(choice.value),
        overlayAlpha: ov,
        child: child,
      );
    });
  }

  /// 模糊程度 0 时不做任何包装（省一次 saveLayer，iOS 上开销明显）
  Widget _applyBlur(Widget w) {
    final b = blur.value;
    if (b <= 0.1) return w;
    return ImageFiltered(
      imageFilter: ImageFilter.blur(sigmaX: b, sigmaY: b),
      child: w,
    );
  }

  Widget _buildGradientBackground({
    required List<Color> colors,
    double overlayAlpha = 0.3,
    Widget? child,
  }) {
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
            color: Colors.white.withValues(alpha: 0.04),
          ),
        ),
        Positioned(
          bottom: -220,
          left: -140,
          child: _buildCircle(
            size: 420,
            color: Colors.white.withValues(alpha: 0.02),
          ),
        ),
        Positioned(
          top: 200,
          right: -60,
          child: _buildCircle(
            size: 220,
            color: Colors.white.withValues(alpha: 0.05),
          ),
        ),
        // 蒙版 (保证文字可读)
        if (overlayAlpha > 0)
          Container(color: Colors.black.withValues(alpha: overlayAlpha)),
        if (child != null) child,
      ],
    );
  }

  Widget _buildGradientFallback({required double overlayAlpha}) {
    return _buildGradientBackground(
      colors: _getGradientForChoice(BackgroundChoice.builtin1),
      overlayAlpha: overlayAlpha,
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
      case BackgroundChoice.custom:
        return '自定义图片';
    }
  }

  /// 获取所有内置背景的 preview 色 (用于设置页的预览小方块)
  static List<({String name, BackgroundChoice choice, List<Color> colors})>
      get builtinPreviews {
    return [
      (
        name: '深邃黑',
        choice: BackgroundChoice.builtin1,
        colors: _builtin1,
      ),
      (
        name: '极光紫',
        choice: BackgroundChoice.builtin2,
        colors: _builtin2,
      ),
      (
        name: '赛博蓝',
        choice: BackgroundChoice.builtin3,
        colors: _builtin3,
      ),
      (
        name: '暖阳橙',
        choice: BackgroundChoice.builtin4,
        colors: _builtin4,
      ),
      (
        name: '皎月白',
        choice: BackgroundChoice.moonWhite,
        colors: _moonWhite,
      ),
    ];
  }
}
