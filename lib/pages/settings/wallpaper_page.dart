import 'dart:io';

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../services/background_service.dart';
import '../../services/wallpaper_api_service.dart';
import '../../widgets/common_widgets.dart';

/// 壁纸设置页
///
/// 与旧「应用背景」弹窗的区别：
/// - 旧弹窗只选背景图/渐变，文字明暗由「外观模式」另外单独管 ——
///   于是能选到「白字 + 皎月白」这种白字白底、什么都看不见的组合。
/// - 本页把两者绑定（方案 A）：选背景时自动决定文字明暗，另给手动覆盖开关
///   （自定义/网络壁纸明暗不确定，必须能手动切）。
/// - 并补齐壁纸效果：不透明度 / 模糊 / 深色遮罩。
/// - 网络壁纸提供在线壁纸库（Bing 每日 / Picsum / 自建 API）。
class WallpaperSettingsPage extends StatefulWidget {
  const WallpaperSettingsPage({super.key});

  static const String routeName = '/wallpaper-settings';

  @override
  State<WallpaperSettingsPage> createState() => _WallpaperSettingsPageState();
}

class _WallpaperSettingsPageState extends State<WallpaperSettingsPage> {
  BackgroundService get _bg => BackgroundService.instance;

  // ---- 在线壁纸库状态 ----
  WallpaperProvider _provider = WallpaperProvider.bingDaily;
  List<WallpaperItem> _items = const [];
  bool _loading = false;
  bool _loadFailed = false;
  int _page = 1;
  /// 分页是否还有更多（Bing 只有几天的图，Picsum 可翻页）
  bool _hasMore = false;
  bool _fetchedOnce = false;

  @override
  void initState() {
    super.initState();
    // 进入页面时若已是网络壁纸模式，直接拉一次列表，省掉"再点一下"
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_bg.sourceType.value == WallpaperSourceType.network) {
        _loadWallpapers(reset: true);
      }
    });
  }

  Future<void> _loadWallpapers({bool reset = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      if (reset) {
        _page = 1;
        _loadFailed = false;
      }
    });
    final list = await WallpaperApiService.instance.fetch(
      _provider,
      page: _page,
      customUrl: _bg.customApiUrl.value,
    );
    if (!mounted) return;
    setState(() {
      _loading = false;
      _fetchedOnce = true;
      _loadFailed = list.isEmpty;
      if (reset) {
        _items = list;
      } else {
        _items = [..._items, ...list];
      }
      // Picsum 可翻页；Bing 每日只有固定几张，不提供"加载更多"
      _hasMore = _provider == WallpaperProvider.picsum && list.isNotEmpty;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        elevation: 0,
        title: Text('壁纸设置',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        actions: [
          TextButton(
            onPressed: _resetAll,
            child: Text('重置', style: TextStyle(color: AppTheme.accentColor)),
          ),
        ],
      ),
      body: Obx(() {
        final bg = _bg;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // ---------- 总开关 ----------
            AppCard(
              child: SettingsRow(
                icon: Icons.wallpaper_outlined,
                title: '启用壁纸背景',
                value: bg.enabled.value ? '已开启' : '已关闭',
                trailingSwitch: true,
                switchValue: bg.enabled.value,
                onSwitchChanged: (v) => bg.setEnabled(v),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                '关闭后使用内置渐变背景，不加载图片与效果',
                style: TextStyle(
                    color: AppTheme.textTertiary, fontSize: AppTheme.fontCaption),
              ),
            ),

            // ---------- 壁纸类型 ----------
            const SectionHeader(title: '壁纸类型'),
            Row(
              children: [
                _typeTile(
                  label: '本地图片',
                  icon: Icons.photo_library_outlined,
                  type: WallpaperSourceType.local,
                ),
                const SizedBox(width: 10),
                _typeTile(
                  label: '网络图片',
                  icon: Icons.cloud_outlined,
                  type: WallpaperSourceType.network,
                ),
                const SizedBox(width: 10),
                _typeTile(
                  label: '渐变色',
                  icon: Icons.gradient_outlined,
                  type: WallpaperSourceType.gradient,
                ),
              ],
            ),
            const SizedBox(height: 16),

            // ---------- 类型对应的选择区 ----------
            if (bg.sourceType.value == WallpaperSourceType.local)
              _buildLocalPicker(bg),
            if (bg.sourceType.value == WallpaperSourceType.network)
              _buildNetworkInput(bg),
            if (bg.sourceType.value == WallpaperSourceType.gradient)
              _buildGradientPicker(bg),

            // ---------- 效果调整 ----------
            if (bg.enabled.value) ...[
              const SizedBox(height: 20),
              const SectionHeader(title: '效果调整'),
              _slider(
                label: '壁纸不透明度',
                valueText: '${(bg.opacity.value * 100).round()}%',
                value: bg.opacity.value,
                min: 0.2,
                max: 1.0,
                divisions: 16,
                onChanged: bg.setOpacity,
              ),
              _slider(
                label: '模糊程度',
                valueText: '${bg.blur.value.round()}',
                value: bg.blur.value,
                min: 0,
                max: 30,
                divisions: 30,
                onChanged: bg.setBlur,
              ),
              _slider(
                label: '遮罩强度',
                valueText: '${(bg.overlay.value * 100).round()}%',
                value: bg.overlay.value,
                min: 0,
                max: 0.8,
                divisions: 16,
                onChanged: bg.setOverlay,
              ),
              Padding(
                padding: const EdgeInsets.only(left: 4, top: 2),
                child: Text(
                  '浅色/深色各有独立的遮罩值：浅色模式用白色遮罩提亮壁纸，'
                  '深色模式用黑色遮罩压暗壁纸，都是为了让文字清晰。',
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                      height: 1.5),
                ),
              ),
            ],

            // ---------- 当前正在编辑哪一套 ----------
            // 外观模式是主导者，所以这里不再让用户单独选"文字颜色"，
            // 而是明确告知"你正在编辑的是浅色/深色模式那一套背景"。
            const SizedBox(height: 20),
            _buildCurrentSceneBanner(bg),
          ],
        );
      }),
    );
  }

  // ============================================================
  // 本地图片
  // ============================================================

  Widget _buildLocalPicker(BackgroundService bg) {
    final hasImage =
        bg.customPath.value != null && bg.customPath.value!.isNotEmpty;
    return AppCard(
      child: Column(
        children: [
          OutlinedButton.icon(
            onPressed: () async {
              final ok = await bg.pickFromGallery();
              if (!mounted) return;
              if (!ok) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('未选择图片')),
                );
              }
            },
            icon: const Icon(Icons.add_photo_alternate_outlined, size: 18),
            label: Text(hasImage ? '更换图片' : '选择图片'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.accentColor,
              side: BorderSide(color: AppTheme.accentColor.withValues(alpha: 0.5)),
              minimumSize: const Size.fromHeight(44),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppTheme.radiusMD)),
            ),
          ),
          if (hasImage) ...[
            const SizedBox(height: 10),
            _buildPreview(bg, isFile: true),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: () async {
                await bg.clearCustom();
                if (mounted) setState(() {});
              },
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('移除当前图片'),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            ),
          ],
        ],
      ),
    );
  }

  // ============================================================
  // 网络图片
  // ============================================================

  Widget _buildNetworkInput(BackgroundService bg) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---------- 在线壁纸库 ----------
        const SectionHeader(title: '在线壁纸库'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 源选择
              Row(
                children: [
                  _providerChip('精选', WallpaperProvider.bingDaily),
                  const SizedBox(width: 8),
                  _providerChip('随机', WallpaperProvider.picsum),
                  const SizedBox(width: 8),
                  _providerChip('自建', WallpaperProvider.custom),
                  const Spacer(),
                  IconButton(
                    onPressed:
                        _loading ? null : () => _loadWallpapers(reset: true),
                    icon: Icon(Icons.refresh,
                        size: 20, color: AppTheme.textSecondary),
                    tooltip: '刷新',
                  ),
                ],
              ),
              if (_provider == WallpaperProvider.custom) ...[
                const SizedBox(height: 8),
                _customApiField(bg),
              ],
              const SizedBox(height: 10),

              // 列表
              if (_loading && _items.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 28),
                  child: Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    ),
                  ),
                )
              else if (_items.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Column(
                    children: [
                      Icon(Icons.image_not_supported_outlined,
                          size: 34, color: AppTheme.textTertiary),
                      const SizedBox(height: 8),
                      Text(
                        _loadFailed && _fetchedOnce
                            ? '壁纸加载失败，检查网络后点刷新'
                            : '点右上角刷新加载壁纸',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontCaption),
                      ),
                    ],
                  ),
                )
              else ...[
                GridView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                    childAspectRatio: 0.66,
                  ),
                  itemCount: _items.length,
                  itemBuilder: (_, i) => _wallpaperTile(_items[i]),
                ),
                if (_hasMore)
                  Center(
                    child: TextButton(
                      onPressed: _loading
                          ? null
                          : () {
                              _page += 1;
                              _loadWallpapers();
                            },
                      child: Text(_loading ? '加载中…' : '加载更多',
                          style: TextStyle(color: AppTheme.accentColor)),
                    ),
                  ),
              ],
            ],
          ),
        ),

        // ---------- 或直接粘贴图片直链 ----------
        const SizedBox(height: 16),
        const SectionHeader(title: '自定义图片直链'),
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: TextEditingController(text: bg.networkUrl.value),
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'https://example.com/wallpaper.jpg',
                  hintStyle: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption),
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                  ),
                ),
                onSubmitted: (v) async {
                  await bg.setNetworkUrl(v);
                  if (mounted) setState(() {});
                },
              ),
              const SizedBox(height: 8),
              Text(
                '粘贴图片直链后按回车确认',
                style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption),
              ),
              if (bg.networkUrl.value.isNotEmpty) ...[
                const SizedBox(height: 10),
                _buildPreview(bg, isFile: false),
                const SizedBox(height: 6),
                TextButton.icon(
                  onPressed: () async {
                    await bg.setNetworkUrl('');
                    if (mounted) setState(() {});
                  },
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('清除网络壁纸'),
                  style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 壁纸源切换 chip
  Widget _providerChip(String label, WallpaperProvider p) {
    final selected = _provider == p;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_provider == p) return;
        setState(() {
          _provider = p;
          _items = const [];
          _fetchedOnce = false;
        });
        _loadWallpapers(reset: true);
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.accentColor.withValues(alpha: 0.18)
              : AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? AppTheme.accentColor : Colors.transparent,
          ),
        ),
        child: Text(label,
            style: TextStyle(
                color:
                    selected ? AppTheme.textPrimary : AppTheme.textSecondary,
                fontSize: 12.5)),
      ),
    );
  }

  /// 自建壁纸 API 地址输入
  Widget _customApiField(BackgroundService bg) {
    return TextField(
      controller: TextEditingController(text: bg.customApiUrl.value),
      style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
      decoration: InputDecoration(
        hintText: 'https://your-api/wallpapers?page={page}',
        hintStyle:
            TextStyle(color: AppTheme.textTertiary, fontSize: 11.5),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppTheme.radiusMD),
        ),
      ),
      onSubmitted: (v) async {
        await bg.setCustomApiUrl(v);
        if (mounted) _loadWallpapers(reset: true);
      },
    );
  }

  /// 壁纸格子：缩略图用 thumbUrl（小图），点击设为大图
  Widget _wallpaperTile(WallpaperItem item) {
    final selected = _bg.networkUrl.value == item.fullUrl;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        // 缩略图与原图分开存：原图动辄 1600×2400，几十张同时解码会 OOM
        await _bg.setNetworkUrl(item.fullUrl, thumbUrl: item.thumbUrl);
        await _bg.setSourceType(WallpaperSourceType.network);
        if (!mounted) return;
        setState(() {});
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('已设为壁纸'),
            duration: Duration(milliseconds: 900),
          ),
        );
      },
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppTheme.radiusMD),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CachedNetworkImage(
              imageUrl: item.thumbUrl,
              fit: BoxFit.cover,
              memCacheWidth: 400,
              placeholder: (_, __) =>
                  Container(color: AppTheme.backgroundTertiary),
              errorWidget: (_, __, ___) => Container(
                color: AppTheme.backgroundTertiary,
                alignment: Alignment.center,
                child: Icon(Icons.broken_image_outlined,
                    size: 20, color: AppTheme.textTertiary),
              ),
            ),
            if (item.title.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(6, 10, 6, 4),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.transparent,
                        Colors.black.withValues(alpha: 0.65),
                      ],
                    ),
                  ),
                  child: Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 10.5),
                  ),
                ),
              ),
            if (selected)
              Container(
                decoration: BoxDecoration(
                  border: Border.all(color: AppTheme.accentColor, width: 2.5),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                ),
                child: const Align(
                  alignment: Alignment.topRight,
                  child: Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.check_circle,
                        color: AppTheme.accentColor, size: 18),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ============================================================
  // 内置渐变
  // ============================================================

  Widget _buildGradientPicker(BackgroundService bg) {
    return AppCard(
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 4,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 0.82,
        ),
        itemCount: BackgroundService.builtinPreviews.length,
        itemBuilder: (_, i) {
          final p = BackgroundService.builtinPreviews[i];
          final selected = bg.choice.value == p.choice;
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () async {
              await bg.setBuiltin(p.choice);
              if (mounted) setState(() {});
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: p.colors,
                      ),
                      borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                      border: Border.all(
                        color: selected
                            ? AppTheme.accentColor
                            : Colors.white.withValues(alpha: 0.12),
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: selected
                        ? const Center(
                            child: Icon(Icons.check_circle,
                                color: Colors.white, size: 22))
                        : null,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  p.name,
                  style: TextStyle(
                      color: selected
                          ? AppTheme.textPrimary
                          : AppTheme.textSecondary,
                      fontSize: 11),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ============================================================
  // 预览
  // ============================================================

  Widget _buildPreview(BackgroundService bg, {required bool isFile}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusMD),
      child: SizedBox(
        height: 120,
        width: double.infinity,
        child: isFile
            ? Image.file(
                _fileOf(bg.customPath.value!),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _previewError(),
              )
            : Image.network(
                bg.networkUrl.value,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _previewError(),
              ),
      ),
    );
  }

  Widget _previewError() => Container(
        color: AppTheme.backgroundTertiary,
        alignment: Alignment.center,
        child: Text('图片无法加载',
            style: TextStyle(color: AppTheme.textTertiary, fontSize: 12)),
      );

  // ============================================================
  // 当前模式提示
  // ============================================================

  /// 顶部提示：当前模式 + 在哪里切换
  Widget _buildCurrentSceneBanner(BackgroundService bg) {
    final isLight = bg.appearanceMode.value == AppearanceMode.light;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.accentColor.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppTheme.radiusMD),
        border: Border.all(
            color: AppTheme.accentColor.withValues(alpha: 0.25), width: 0.8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(isLight ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
              size: 18, color: AppTheme.accentColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isLight ? '正在编辑：浅色模式的背景' : '正在编辑：深色模式的背景',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(
                  '浅色和深色各有一套独立背景，切到另一种外观会自动换成那套。\n'
                  '外观模式在「设置 → 外观 → 外观模式」里切换。',
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                      height: 1.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
  // ============================================================
  // 壁纸类型磁贴
  // ============================================================

  Widget _typeTile({
    required String label,
    required IconData icon,
    required WallpaperSourceType type,
  }) {
    final selected = _bg.sourceType.value == type;
    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          await _bg.setSourceType(type);
          if (mounted) setState(() {});
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.accentColor.withValues(alpha: 0.16)
                : AppTheme.backgroundSecondary,
            borderRadius: BorderRadius.circular(AppTheme.radiusMD),
            border: Border.all(
              color: selected
                  ? AppTheme.accentColor
                  : Colors.transparent,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 22,
                  color: selected ? AppTheme.accentColor : AppTheme.textSecondary),
              const SizedBox(height: 6),
              Text(label,
                  style: TextStyle(
                      color: selected
                          ? AppTheme.textPrimary
                          : AppTheme.textSecondary,
                      fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 带刻度的滑条
  // ============================================================

  Widget _slider({
    required String label,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required Future<void> Function(double) onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 10),
        Row(
          children: [
            Text(label,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
            const Spacer(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: AppTheme.accentColor.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(valueText,
                  style: TextStyle(
                      color: AppTheme.accentColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            activeColor: AppTheme.accentColor,
            inactiveColor: Colors.white.withValues(alpha: 0.14),
            onChanged: (v) => onChanged(v),
          ),
        ),
      ],
    );
  }

  // ============================================================
  // 重置
  // ============================================================

  /// 重置**当前模式**那一套背景（不动另一种模式的配置）
  Future<void> _resetAll() async {
    final bg = _bg;
    final isLight = bg.appearanceMode.value == AppearanceMode.light;
    await bg.setEnabled(true);
    await bg.clearCustom(); // 清图片/网络，回到渐变
    await bg.setBuiltin(
        isLight ? BackgroundChoice.moonWhite : BackgroundChoice.builtin1);
    await bg.setOpacity(1.0);
    await bg.setBlur(0);
    // 浅色模式默认遮罩更重（白遮罩提亮壁纸）
    await bg.setOverlay(isLight ? 0.35 : 0.3);
    if (mounted) {
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(isLight ? '浅色模式背景已重置' : '深色模式背景已重置')),
      );
    }
  }
}

/// dart:io File 的薄包装，避免在本文件顶部引入 dart:io 只为构造 File。
File _fileOf(String path) => File(path);
