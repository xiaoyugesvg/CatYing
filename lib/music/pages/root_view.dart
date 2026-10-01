import 'package:flutter/material.dart';

import '../services/player_manager.dart';
import '../services/settings_store.dart';
import '../theme/music_theme.dart';
import '../widgets/mini_player.dart';
import 'discover_page.dart';
import 'library_page.dart';
import 'profile_page.dart';
import 'search_page.dart';

/// 音乐模块的 App 骨架 —— 移植自 Beans 的 `RootView.swift`。
///
/// ── 结构（与 Beans 一致）──────────────────────────────────────
///   4 个 tab：主页(发现) / 搜索 / 音乐库 / 我的
///   底部自绘悬浮导航栏（Beans 旧系统走自绘胶囊底栏）
///   迷你播放器**浮在导航栏之上**，有正在播放的歌才显示
///
/// ── 为什么自绘导航栏 ─────────────────────────────────────────
/// Beans 用的是系统 TabView + accessory；猫影自己已有悬浮栏视觉
/// （`JellyNavBar` 风格），这里保持同样手感，也方便把迷你播放器
/// 叠在栏上方。
///
/// ⚠️ 本模块**完全独立**：自己的主题（MusicTheme）、自己的播放器
/// （MusicPlayerManager）、自己的设置（SettingsStore），
/// 不与影视侧共用任何状态。
class MusicRootView extends StatefulWidget {
  const MusicRootView({super.key});

  @override
  State<MusicRootView> createState() => _MusicRootViewState();
}

class _MusicRootViewState extends State<MusicRootView> {
  int _tab = 0;

  static const _tabs = <({String label, IconData icon, IconData active})>[
    (label: '主页', icon: Icons.home_outlined, active: Icons.home_rounded),
    (label: '搜索', icon: Icons.search_rounded, active: Icons.search_rounded),
    (
      label: '音乐库',
      icon: Icons.library_music_outlined,
      active: Icons.library_music_rounded
    ),
    (
      label: '我的',
      icon: Icons.person_outline_rounded,
      active: Icons.person_rounded
    ),
  ];

  @override
  void initState() {
    super.initState();
    // 进音乐 tab 就把数据预热起来（失败静默，不挡界面）
    warmUpMusicData();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      // 主题切换（强调色/明暗）要立刻反映到整个音乐模块
      animation: Listenable.merge([
        MusicThemeStore.instance.revision,
        SettingsStore.instance.audioQuality,
      ]),
      builder: (context, _) {
        return Theme(
          data: MusicTheme.themeData(),
          child: Scaffold(
            backgroundColor: MusicTheme.background,
            body: Stack(
              children: [
                // tab 内容（用 IndexedStack 保留各页滚动位置）
                Positioned.fill(
                  child: IndexedStack(
                    index: _tab,
                    children: const [
                      DiscoverPage(),
                      SearchPage(),
                      LibraryPage(),
                      ProfilePage(),
                    ],
                  ),
                ),
                // 底部：迷你播放器 + 悬浮导航栏
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedBuilder(
                        animation: MusicPlayerManager.instance,
                        builder: (context, _) {
                          if (MusicPlayerManager.instance.currentSong == null) {
                            return const SizedBox.shrink();
                          }
                          return MiniPlayer(
                            onOpen: () => openMusicPlayer(context),
                          );
                        },
                      ),
                      _navBar(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _navBar() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: MusicTheme.card.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: MusicTheme.label.withValues(alpha: 0.06),
          width: 0.5,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.10),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        bottom: true,
        child: Row(
          children: List.generate(_tabs.length, (i) {
            final t = _tabs[i];
            final active = i == _tab;
            return Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _tab = i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  decoration: BoxDecoration(
                    color: active
                        ? MusicTheme.tint.withValues(alpha: 0.14)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        active ? t.active : t.icon,
                        size: 21,
                        color: active ? MusicTheme.tint : MusicTheme.secondary,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        t.label,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w400,
                          color:
                              active ? MusicTheme.tint : MusicTheme.secondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}

/// 供外部（如影视侧跳转）切到指定 tab
class MusicTabController {
  MusicTabController._();
  static final instance = MusicTabController._();
  final tab = ValueNotifier<int>(0);
}
