import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../services/music_service.dart';
import 'player_controller.dart';
import 'player_page.dart';
import '../settings/sub/music_source_settings_page.dart';
import 'tabs.dart';

/// 音乐分类的四个子页（底部悬浮菜单里切换）
enum MusicTab {
  rank('榜单', Icons.bar_chart),
  playlist('歌单', Icons.queue_music),
  mine('我的', Icons.favorite_border),
  home('首页', Icons.home_outlined);

  const MusicTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// 音乐主页面
///
/// 结构（按你的要求）：
///   顶栏：左 = 音乐 logo + 音源名 ｜ 右 = 搜索 + 设置
///   内容：榜单 / 歌单 / 我的 / 首页 四个子页
///   底部：悬浮菜单 —— 榜单 歌单 [播放磁盘] 我的 首页
///
/// 磁盘按钮在中间，点击进播放页；正在播放时它跟着转。
class MusicHomePage extends StatefulWidget {
  const MusicHomePage({super.key});

  @override
  State<MusicHomePage> createState() => _MusicHomePageState();
}

class _MusicHomePageState extends State<MusicHomePage> {
  final tab = MusicTab.rank.obs;
  final p = MusicPlayerController.instance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildTopBar(),
            Expanded(
              child: Obx(() => IndexedStack(
                    index: tab.value.index,
                    children: const [
                      MusicRankTab(),
                      MusicPlaylistTab(),
                      MusicMineTab(),
                      MusicHomeTab(),
                    ],
                  )),
            ),
          ],
        ),
      ),
      // 底部悬浮菜单（避开系统手势条）
      bottomNavigationBar: _buildFloatingMenu(),
    );
  }

  // ============================================================
  // 顶栏：左 logo + 音源名 ｜ 右 搜索 + 设置
  // ============================================================

  Widget _buildTopBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AppTheme.spacingLG, AppTheme.spacingMD, AppTheme.spacingMD, 6),
      child: Row(
        children: [
          // 音乐 logo
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.accentColor.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: AppTheme.accentColor.withValues(alpha: 0.24),
                  width: 0.5),
            ),
            child: Icon(Icons.library_music,
                size: 18, color: AppTheme.accentColor),
          ),
          const SizedBox(width: 10),
          // 音源名（点一下进音源设置）
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openSourceSettings,
              child: Obx(() {
                final name = MusicService.instance.displaySourceName;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('音乐',
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: AppTheme.fontSubhead + 1,
                            fontWeight: FontWeight.w600)),
                    const SizedBox(height: 1),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: AppTheme.textTertiary,
                                fontSize: AppTheme.fontCaption)),
                        const SizedBox(width: 3),
                        Icon(Icons.keyboard_arrow_down,
                            size: 13, color: AppTheme.textTertiary),
                      ],
                    ),
                  ],
                );
              }),
            ),
          ),
          // 搜索
          _iconBtn(Icons.search, '搜索', () => Get.to(() => const MusicSearchPage())),
          const SizedBox(width: 4),
          // 设置
          _iconBtn(Icons.settings_outlined, '设置', _openSourceSettings),
        ],
      ),
    );
  }

  Widget _iconBtn(IconData icon, String tip, VoidCallback onTap) {
    return Tooltip(
      message: tip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppTheme.backgroundCard,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: AppTheme.glassBorderSoft, width: 0.6),
          ),
          child: Icon(icon, size: 18, color: AppTheme.textSecondary),
        ),
      ),
    );
  }

  Future<void> _openSourceSettings() async {
    await Get.to(() => const MusicSourceSettingsEntry());
  }

  // ============================================================
  // 底部悬浮菜单：榜单 歌单 [磁盘] 我的 首页
  // ============================================================

  Widget _buildFloatingMenu() {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(
          AppTheme.spacingLG, 0, AppTheme.spacingLG, 8 + bottomInset * 0.4),
      child: Container(
        height: 62,
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(31),
          border: Border.all(color: AppTheme.glassBorder, width: 0.8),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            // 左两项
            Expanded(child: _menuItem(MusicTab.rank)),
            Expanded(child: _menuItem(MusicTab.playlist)),
            // 中间：播放磁盘
            _discButton(),
            // 右两项
            Expanded(child: _menuItem(MusicTab.mine)),
            Expanded(child: _menuItem(MusicTab.home)),
          ],
        ),
      ),
    );
  }

  Widget _menuItem(MusicTab t) {
    return Obx(() {
      final active = tab.value == t;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => tab.value = t,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(t.icon,
                size: 20,
                color: active ? AppTheme.accentColor : AppTheme.textTertiary),
            const SizedBox(height: 3),
            Text(t.label,
                style: TextStyle(
                    color:
                        active ? AppTheme.accentColor : AppTheme.textTertiary,
                    fontSize: 10,
                    fontWeight:
                        active ? FontWeight.w600 : FontWeight.normal)),
          ],
        ),
      );
    });
  }

  /// 中间的播放磁盘：有歌时显示旋转封面，无歌时显示占位
  Widget _discButton() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (p.hasTrack) {
          Get.to(() => const MusicPlayerPage());
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('还没有在播放的歌曲')));
        }
      },
      child: SizedBox(
        width: 66,
        height: 66,
        child: Center(
          child: Obx(() {
            final t = p.current;
            return AnimatedContainer(
              duration: AppTheme.motionBase,
              curve: AppTheme.motionCurve,
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppTheme.accentColor.withValues(alpha: 0.95),
                    AppTheme.accentColor.withValues(alpha: 0.55),
                  ],
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.accentColor.withValues(alpha: 0.4),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: t == null
                  ? const Icon(Icons.play_arrow,
                      size: 24, color: Colors.white)
                  : ClipOval(
                      child: t.coverUrl.isEmpty
                          ? const Icon(Icons.music_note,
                              size: 22, color: Colors.white)
                          : Image.network(
                              t.coverUrl,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(
                                  Icons.music_note,
                                  size: 22,
                                  color: Colors.white),
                            ),
                    ),
            );
          }),
        ),
      ),
    );
  }
}

/// 音源设置入口（转发到设置页，避免 home_page 再 import 设置目录）
class MusicSourceSettingsEntry extends StatelessWidget {
  const MusicSourceSettingsEntry({super.key});

  @override
  Widget build(BuildContext context) => const MusicSourceSettingsPage();
}
