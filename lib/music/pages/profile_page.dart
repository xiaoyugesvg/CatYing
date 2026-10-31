import 'package:file_picker/file_picker.dart';
import 'package:get/get.dart';
import 'package:tvbox/music/widgets/music_sheet.dart';
import 'package:flutter/material.dart';

import 'package:tvbox/music/models/models.dart';
import 'package:tvbox/music/models/third_party_source.dart';
import 'package:tvbox/music/services/settings_store.dart';
import 'package:tvbox/music/theme/music_theme.dart';
import 'package:tvbox/music/widgets/floating_play_button.dart';
import 'package:tvbox/music/pages/music_log_page.dart';
import 'package:tvbox/music/pages/local_music_page.dart';
import 'package:tvbox/music/widgets/mo_lv_pages.dart';
import 'package:tvbox/music/pages/music_source_settings_page.dart';
import 'package:tvbox/music/pages/plugin_market_page.dart';
import 'package:tvbox/music/pages/plugin_subscription_page.dart';
import 'package:tvbox/music/pages/source_manager_page.dart';
import 'package:tvbox/common/module_theme_store.dart';
import 'package:tvbox/common/module_theme_sync.dart';
import 'package:tvbox/common/theme_mode_store.dart';
import 'package:tvbox/services/main_tab_controller.dart';
import 'package:tvbox/reading/theme/jelly_palette.dart';
import 'package:tvbox/common/theme.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/theme_preset_row.dart';

/// 「我的」页 —— 移植自 Beans 的 `ProfileView.swift`（3350 行，取其主干）。
///
/// ── 保留的 Beans 分区 ─────────────────────────────────────────
///   1. **个性化外观**：明暗模式 / 9 种强调色 / 自定义色
///   2. **播放设置**：音质 / 封面形态 / 背景氛围（在播放器设置里也有）
///   3. **音源管理**：导入/启用/删除第三方音源（Beans 的"音源"入口）
///
/// ── 裁掉的部分（说明理由）────────────────────────────────────
/// Beans 的 ProfileView 里最大一块是**账号**（登录/会员/云盘/等级），
/// 还有下载管理、更新检查、日志查看。本项目不做账号，
/// 下载/更新也依赖额外原生能力，故未纳入。
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = SettingsStore.instance;
    final themeStore = MusicThemeStore.instance;

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 170),
        children: [
          // ⚠️ 这里原来有一个大标题「我的」+ 一行小字
          //（「外观 / 播放 / 音源 · 全部存在本机」）。
          // 用户 2026-10-30：「我的上面那个我的和小字都去掉」——
          // 底栏 tab 已经写着「我的」，页内再顶一个大标题纯属重复；
          // 那行小字也是废话（下面三个分组标题已经说明了内容）。
          // 所以整块**删掉**，直接从「个性化外观」开始。
          // 留一点顶部呼吸感（原来靠 header 的 padding 撑着）。
          const SizedBox(height: 12),

          // ── 本地模式卡（设计稿 `08_我的.png` 顶部那张）──────────────
          //
          // 设计稿这里是一个账号头像 + 昵称，本项目没有账号，
          // 所以换成本项目的真实形态：**本地模式**（收藏 / 歌单都在本机）。
          // 点它去「本地音乐」—— 比弹一个假登录框诚实。
          MoLvUserCard(
            title: '本地模式',
            subtitle: '不需要账号，收藏与歌单都存在本机',
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              settings: const RouteSettings(name: 'music:page'),
              builder: (_) => Theme(
                data: MusicTheme.themeData(),
                child: const LocalMusicPage(),
              ),
            )),
          ),

          // ── 外观 ────────────────────────────────────────────
          const _GroupTitle('个性化外观'),
          _groupCard([
          _ModeTile(store: themeStore),
          _AccentPicker(),
          _coverStyleTile(),
          _dustTile(),
          _floatingBallTile(),
          ]),

          // ── 播放 ────────────────────────────────────────────
          const _GroupTitle('播放'),
          _groupCard([
          _qualityTile(store),
          _pluginEngineTile(store),
          _switchTile(
            // 不叫"第三方音源" —— 用户导入的就是"洛雪音乐源"和"MusicFree 源"，
            // 统称"导入的音乐源"更贴近他的心智模型
            label: '使用导入的音乐源',
            subtitle: '关闭后只用内置的公开接口',
            value: store.useThirdPartySources.value,
            listen: store.useThirdPartySources,
            onChanged: (v) => store.setUseThirdPartySources(v),
          ),
          // ── 子页面的播放条（用户 2026 定稿）────────────────────
          //
          // 用户原话：「去掉那个子页面也有悬浮导航栏呢？只是显示播放栏呢？
          //            播放的时候显示，不播放就不显示呢」
          //
          // 所以**只有一个开关**，管的也只是"子页面要不要播放条"：
          //   · 子页面**永远没有导航栏**（那会把内容和"返回"语义都搞乱）
          //   · 播放条**只在真的在播放时**出现（暂停/没歌就收起来）
          //（原来那个"子页面显示迷你播放条"的子开关因此**删掉了** ——
          //  它表达的就是这一件事，留着就是两个开关说同一句话。）
          _switchTile(
            label: '子页面显示播放条',
            subtitle: '在歌单详情等子页面，播放时显示迷你播放条',
            value: store.bottomBarOnSubPages.value,
            listen: store.bottomBarOnSubPages,
            onChanged: (v) => store.setBottomBarOnSubPages(v),
          ),
          _switchTile(
            label: '启动自动播放',
            subtitle: '打开 App 后自动接着上次的歌继续播放',
            value: store.autoPlayOnLaunch.value,
            listen: store.autoPlayOnLaunch,
            onChanged: (v) => store.setAutoPlayOnLaunch(v),
          ),
          // ⚠️ 「跨平台匹配」开关**已移除**（用户 2026 决定：不要跨平台）。
          //
          // 实测它救不了 VIP 歌（QQ《晴天》在酷狗同名 9 条全 no_free_source，
          // 能播的只有片段/翻唱），而且会让"点歌"多几秒等待。
          // 保留开关只会让人误以为"开了就能听 VIP"，所以直接不给入口。
          //
          // `CrossPlatformMatcher` 实现**保留**（没删代码），
          // `SettingsStore.crossPlatformMatch` 也保留（默认 false）——
          // 以后想恢复只需把上面那个开关加回来。
          ]),

          // ── 音源 ────────────────────────────────────────────
          const _GroupTitle('音源'),
          _groupCard([
            // 按平台固定源（音乐 → 我的 → 按平台固定第三方源）
            ListTile(
              leading: _iconBox(Icons.tune_rounded),
              title: Text('按平台固定源',
                  style: TextStyle(
                      color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
              subtitle: Text('网易 / QQ / 酷狗… 各绑几个第三方源，优先自动试用',
                  style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: AppTheme.fontFootnote)),
              trailing: Icon(Icons.chevron_right,
                  size: 18, color: MusicTheme.secondary),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                settings: const RouteSettings(name: 'music:page'),
                builder: (_) => const MusicSourceSettingsPage(),
              )),
            ),
            // 源管理（导入/启用/删除第三方音源）
            ValueListenableBuilder<int>(
              valueListenable: ThirdPartySourceStore.instance.revision,
              builder: (context, _, __) {
                final all = ThirdPartySourceStore.instance.all;
                final lx = all.where((s) => !s.isMusicFree).length;
                final mf = all.where((s) => s.isMusicFree).length;
                final sub = all.isEmpty
                    ? '还没有导入音乐源'
                    : [
                        if (lx > 0) '洛雪 $lx',
                        if (mf > 0) 'MusicFree $mf',
                      ].join(' · ');
                return ListTile(
                  leading: _iconBox(Icons.extension_rounded),
                  title: Text('音乐源管理',
                      style: TextStyle(
                          color: MusicTheme.label,
                          fontSize: AppTheme.fontHeadline)),
                  subtitle: Text(sub,
                      style: TextStyle(
                          color: MusicTheme.secondary,
                          fontSize: AppTheme.fontFootnote)),
                  trailing: Icon(Icons.chevron_right,
                      size: 18, color: MusicTheme.secondary),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    settings: const RouteSettings(name: 'music:page'),
                    builder: (_) => const SourceManagerPage(),
                  )),
                );
              },
            ),
            // ── 插件市场 / 插件订阅（2026-10-21 第三期）──────────────
            ListTile(
              leading: _iconBox(Icons.storefront_rounded),
              title: Text('插件市场',
                  style: TextStyle(
                      color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
              subtitle: Text('浏览订阅里的 MusicFree 插件，按需安装 / 更新 / 卸载',
                  style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: AppTheme.fontFootnote)),
              trailing: Icon(Icons.chevron_right,
                  size: 18, color: MusicTheme.secondary),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                settings: const RouteSettings(name: 'music:page'),
                builder: (_) => const PluginMarketPage(),
              )),
            ),
            ListTile(
              leading: _iconBox(Icons.rss_feed_rounded),
              title: Text('插件订阅',
                  style: TextStyle(
                      color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
              subtitle: Text('管理插件清单地址（registry.json / plugins.json）',
                  style: TextStyle(
                      color: MusicTheme.secondary,
                      fontSize: AppTheme.fontFootnote)),
              trailing: Icon(Icons.chevron_right,
                  size: 18, color: MusicTheme.secondary),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                settings: const RouteSettings(name: 'music:page'),
                builder: (_) => const PluginSubscriptionPage(),
              )),
            ),
          // ── 音乐运行日志（用户 2026 要求）────────────────────────
          //
          // 「源切换过程中源不能用的日志在哪看呢？"详情见日志"在哪呢？」
          // 日志一直在写，但入口原来只在**阅读模块**的设置里 →
          // 音乐这边报错让用户"见日志"，用户找不到 ✗
          // 所以音乐「我的」页里也放一个，出错时一句话就能到。
          ListTile(
            leading: _iconBox(Icons.receipt_long_rounded),
            title: Text('音乐运行日志',
                style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: AppTheme.fontHeadline)),
            subtitle: Text(
              '音源为什么失败、锁屏控制状态等（可复制）',
              style: TextStyle(
                  color: MusicTheme.secondary,
                  fontSize: AppTheme.fontFootnote),
            ),
            trailing: Icon(Icons.chevron_right,
                size: 18, color: MusicTheme.secondary),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(settings: const RouteSettings(name: 'music:page'),
              builder: (_) => const MusicLogPage(),
            )),
          ),
          ]),
        ],
      ),
    );
  }

  /// 悬浮球样式：默认图标 / **自定义图片或 GIF**（用户要求能在设置里换）
  Widget _floatingBallTile() => ValueListenableBuilder<String>(
        valueListenable: MusicFloatingBallStyle.instance.imagePath,
        builder: (context, path, _) => ListTile(
          leading: _iconBox(Icons.bubble_chart_rounded),
          title: Text('悬浮球样式',
              style: TextStyle(
                  color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
          subtitle: Text(path.isEmpty ? '默认图标' : '自定义图片 / GIF',
              style: TextStyle(
                  color: MusicTheme.secondary,
                  fontSize: AppTheme.fontFootnote)),
          trailing: Icon(Icons.chevron_right,
              size: 18, color: MusicTheme.secondary),
          onTap: () => _pickFloatingBallStyle(context),
        ),
      );

  Future<void> _pickFloatingBallStyle(BuildContext context) async {
    final style = MusicFloatingBallStyle.instance;
    final act = await showMusicSheet<String>(
      context: context,
      backgroundColor: MusicTheme.card,
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.image_rounded, color: MusicTheme.tint),
              title: Text('选择图片 / GIF',
                  style: TextStyle(color: MusicTheme.label)),
              onTap: () => Navigator.pop(ctx, 'pick'),
            ),
            ListTile(
              leading:
                  Icon(Icons.restart_alt_rounded, color: MusicTheme.tint),
              title: Text('恢复默认图标',
                  style: TextStyle(color: MusicTheme.label)),
              onTap: () => Navigator.pop(ctx, 'reset'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (act == 'reset') {
      await style.clear();
      AppToast.show('已恢复默认悬浮球', '');
      return;
    }
    if (act != 'pick') return;
    try {
      // ⚠️ file_picker **13.x** 的 API（项目里早有记录，见
      // `book_source_repo_page.dart:1576`）：
      //   · `FilePicker.pickFiles(...)` 是**静态方法**（旧版是 `.platform.pickFiles`）
      //   · 返回 **`List<PlatformFile>`**（旧版返回 `FilePickerResult?`）
      final files = await FilePicker.pickFiles(type: FileType.image);
      final p = files.isEmpty ? null : files.first.path;
      if (p == null || p.isEmpty) return;
      await style.setImage(p);
      AppToast.show('悬浮球样式已更新', '');
    } catch (e) {
      AppToast.show('选择图片失败', '$e');
    }
  }

  /// 把一组行包成 Beans 式的**分组圆角卡片**（对齐截图④：每组一张卡）。
  ///
  /// ⚠️ 必须用 `Material` 而不是 `Container(color:)`：
  /// `ListTile` 需要 **Material 祖先**来画背景与水波纹，否则框架会抛
  /// "ListTile background color or ink splashes may be invisible."
  /// （这正是 `music_root_view_test` 那 3 个失败的原因 —— IndexedStack 会
  ///   构建所有 tab，一构建到本页就抛断言。）
  /// `clipBehavior: Clip.antiAlias` 让水波纹被圆角裁掉。
  ///
  /// 注意：内部行**保留原有缩进**（Dart 不看缩进），这样这次改动是
  /// "组首组尾各插一行"的最小 diff，不动那一大段既有代码 —— 降低改崩的风险。
  Widget _groupCard(List<Widget> rows) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 2, 16, 12),
        child: Material(
          color: MusicTheme.card,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: Column(children: rows),
        ),
      );

  static Widget _iconBox(IconData icon) => Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: MusicTheme.tint.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, size: 17, color: MusicTheme.tint),
      );

  /// 开关行。
  ///
  /// 🔴 原来用 `StatefulBuilder` + `setLocal(() {})`：那只重建**本行**，
  /// 而 `value` 是**调用时捕获的旧值** → 拨动开关后它立刻**弹回原位** ✗
  ///（设置其实**已经保存**，只是显示不动 → 用户以为"第三方源没打开"）。
  /// 这里改成直接跟随 `SettingsStore.useThirdPartySources` 这个 Notifier，
  /// 拨动后由它推新值，不会再回弹。（本页只有这一个开关，所以直接绑定。）
  /// 一个开关行。
  ///
  /// ── 🔴 修的真 bug：原来**写死**监听 `useThirdPartySources` ────────
  /// 旧实现是：
  /// ```dart
  /// ValueListenableBuilder<bool>(
  ///   valueListenable: SettingsStore.instance.useThirdPartySources,  // ← 写死
  ///   builder: (context, v, _) => SwitchListTile(value: v, ...),
  /// )
  /// ```
  /// 传进来的 `value` / `onChanged` **全都没被用** —— 它永远显示
  /// "使用导入的音乐源"那个值。
  ///
  /// 只有一个开关时看不出来（恰好就是它）；一旦加第二个开关，
  /// 两个会**显示同一个状态、点一个另一个也变** ✗。
  ///
  /// 修法：加一个 [listen] 参数指定要监听哪个 notifier，
  /// 并且**以 [value] 为准**（调用方传的是它自己那份的状态）。
  /// 开关行。
  ///
  /// 用户 2026-10-30：「音乐里面的小字也不要，然后加？来说明」——
  /// 原来每行下面挂一行灰色小字（"关闭后只用内置的公开接口"这种），
  /// 一屏下来小字比标题还多、扫读时全是噪音。现在改成：
  ///   · 小字**不显示**；
  ///   · 标题后面跟一个淡淡的「？」，点一下才弹出这句说明。
  /// 状态型的副标题（音质=无损、封面形态=方形…）**不在此列** —— 那是当前值，
  /// 不是解释，去掉了用户就不知道现在是哪个档。
  Widget _switchTile({
    required String label,
    String? subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    ValueNotifier<bool>? listen,
  }) =>
      ValueListenableBuilder<bool>(
        valueListenable: listen ?? SettingsStore.instance.useThirdPartySources,
        builder: (context, v, _) => SwitchListTile(
          // ⚠️ 用 notifier 的当前值（`v`）而不是参数 `value` ——
          // 参数是调用时**快照**，开关变化后不会更新，会"点了又弹回去"。
          value: v,
          activeThumbColor: MusicTheme.tint,
          contentPadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Row(
            children: [
              Flexible(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: MusicTheme.label,
                        fontSize: AppTheme.fontHeadline)),
              ),
              if (subtitle != null && subtitle.trim().isNotEmpty) ...[
                const SizedBox(width: 6),
                _HelpDot(text: subtitle),
              ],
            ],
          ),
          onChanged: onChanged,
        ),
      );

  Widget _qualityTile(SettingsStore store) => ValueListenableBuilder(
        valueListenable: store.audioQuality,
        builder: (context, q, _) => ListTile(
          leading: _iconBox(Icons.high_quality_rounded),
          title:
              Text('音质', style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
          subtitle: Text(q.displayName,
              style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
          trailing: Icon(Icons.chevron_right,
              size: 18, color: MusicTheme.secondary),
          onTap: () async {
            final picked = await showMusicSheet<dynamic>(
              context: context,
              backgroundColor: MusicTheme.card,
              builder: (ctx) => SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    // ⚠️ **不要**写死档位数量。原来这里是
                    //     `List.generate(5, (i) => AudioQuality.values[i])` ——
                    //     今天 `AudioQuality` 恰好 5 个所以看不出问题，但：
                    //       · 少一个档位 → `values[4]` 抛 RangeError，弹层直接崩
                    //       · 多一个档位 → 新档位**静默消失**，用户永远选不到
                    //     遍历 `values` 本身，加档位就自动出现。
                    ...AudioQuality.values.map((e) {
                      return ListTile(
                        title: Text(e.displayName,
                            style: TextStyle(
                                color: e == q
                                    ? MusicTheme.tint
                                    : MusicTheme.label)),
                        trailing: e == q
                            ? Icon(Icons.check,
                                color: MusicTheme.tint, size: 18)
                            : null,
                        onTap: () => Navigator.pop(ctx, e),
                      );
                    }),
                  ],
                ),
              ),
            );
            if (picked is AudioQuality) await store.setAudioQuality(picked);
          },
        ),
      );

  /// 插件执行引擎（2026-10-21）：自动 / Node / QuickJS。
  ///
  /// 「自动」= 先试 QuickJS（只支持 axios/he 的插件），跑不了自动回退 Node；
  /// 想排查兼容问题时可固定成 Node，想对比性能可固定成 QuickJS。
  Widget _pluginEngineTile(SettingsStore store) => ValueListenableBuilder(
        valueListenable: store.pluginEngine,
        builder: (context, v, _) {
          final label = switch (v) {
            'node' => 'Node（兼容性最好）',
            'quickjs' => 'QuickJS（实验）',
            _ => '自动（QuickJS 优先，失败回退 Node）',
          };
          return ListTile(
            leading: _iconBox(Icons.memory_rounded),
            title: Text('插件引擎',
                style: TextStyle(
                    color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
            subtitle: Text(label,
                style: TextStyle(
                    color: MusicTheme.secondary,
                    fontSize: AppTheme.fontFootnote)),
            trailing: Icon(Icons.chevron_right,
                size: 18, color: MusicTheme.secondary),
            onTap: () async {
              final picked = await showMusicSheet<String>(
                context: context,
                backgroundColor: MusicTheme.card,
                builder: (ctx) => SafeArea(
                  top: false,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 12),
                      for (final e in const [
                        ('auto', '自动（推荐）', 'QuickJS 优先，插件不支持时自动回退 Node'),
                        ('node', 'Node', '全部插件走 Node，兼容性最好'),
                        ('quickjs', 'QuickJS', '实验引擎：仅支持 axios / he 类插件'),
                      ])
                        ListTile(
                          title: Text(e.$2,
                              style: TextStyle(
                                  color: v == e.$1
                                      ? MusicTheme.tint
                                      : MusicTheme.label)),
                          subtitle: Text(e.$3,
                              style: TextStyle(
                                  color: MusicTheme.secondary,
                                  fontSize: AppTheme.fontFootnote)),
                          trailing: v == e.$1
                              ? Icon(Icons.check,
                                  color: MusicTheme.tint, size: 18)
                              : null,
                          onTap: () => Navigator.pop(ctx, e.$1),
                        ),
                    ],
                  ),
                ),
              );
              if (picked is String) await store.setPluginEngine(picked);
            },
          );
        },
      );

  Widget _coverStyleTile() => ValueListenableBuilder(
        valueListenable: MusicPlayerSkin.instance.coverStyle,
        builder: (context, v, _) => ListTile(
          leading: _iconBox(Icons.album_rounded),
          title: Text('封面形态',
              style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
          subtitle: Text(v.label,
              style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
          onTap: () async {
            final picked = await showMusicSheet<MusicCoverStyle>(
              context: context,
              backgroundColor: MusicTheme.card,
              builder: (ctx) => SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    ...MusicCoverStyle.values.map((e) => ListTile(
                          title: Text(e.label,
                              style: TextStyle(
                                  color: e == v
                                      ? MusicTheme.tint
                                      : MusicTheme.label)),
                          trailing: e == v
                              ? Icon(Icons.check,
                                  color: MusicTheme.tint, size: 18)
                              : null,
                          onTap: () => Navigator.pop(ctx, e),
                        )),
                  ],
                ),
              ),
            );
            if (picked != null) {
              await MusicPlayerSkin.instance.setCoverStyle(picked);
            }
          },
        ),
      );

  Widget _dustTile() => ValueListenableBuilder(
        valueListenable: MusicPlayerSkin.instance.dustMode,
        builder: (context, v, _) => ListTile(
          leading: _iconBox(Icons.blur_on_rounded),
          title: Text('背景氛围',
              style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
          subtitle: Text(v.label,
              style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
          onTap: () async {
            final picked = await showMusicSheet<MusicDustMode>(
              context: context,
              backgroundColor: MusicTheme.card,
              builder: (ctx) => SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    ...MusicDustMode.values.map((e) => ListTile(
                          title: Text(e.label,
                              style: TextStyle(
                                  color: e == v
                                      ? MusicTheme.tint
                                      : MusicTheme.label)),
                          trailing: e == v
                              ? Icon(Icons.check,
                                  color: MusicTheme.tint, size: 18)
                              : null,
                          onTap: () => Navigator.pop(ctx, e),
                        )),
                  ],
                ),
              ),
            );
            if (picked != null) {
              await MusicPlayerSkin.instance.setDustMode(picked);
            }
          },
        ),
      );
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 22, 16, 6),
        child: Text(text,
            style: TextStyle(
                color: MusicTheme.tint,
                fontSize: AppTheme.fontSubhead,
                fontWeight: FontWeight.w700)),
      );
}

/// 明暗模式切换（跟随系统 / 浅色 / 深色）
///
/// 直接读/写全局 ThemeModeStore，通过 GlobalThemeSync 自动同步三模块。
class _ModeTile extends StatelessWidget {
  const _ModeTile({required this.store});
  final MusicThemeStore store;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: ThemeModeStore.notifier,
      builder: (context, mode, _) {
        final label = switch (mode) {
          ThemeMode.light => '浅色',
          ThemeMode.dark => '深色',
          ThemeMode.system => '跟随系统',
        };
        final icon = switch (mode) {
          ThemeMode.light => Icons.light_mode_rounded,
          ThemeMode.dark => Icons.dark_mode_rounded,
          ThemeMode.system => Icons.brightness_auto_rounded,
        };
        return ListTile(
          leading: ProfilePage._iconBox(icon),
          title: Text('外观模式',
              style: TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
          subtitle: Text(label,
              style: TextStyle(color: MusicTheme.secondary, fontSize: AppTheme.fontFootnote)),
          onTap: () async {
            final options = [
              (mode: ThemeMode.light, label: '浅色'),
              (mode: ThemeMode.dark, label: '深色'),
              (mode: ThemeMode.system, label: '跟随系统'),
            ];
            final picked = await showMusicSheet<ThemeMode>(
              context: context,
              backgroundColor: MusicTheme.card,
              builder: (ctx) => SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 12),
                    for (final o in options)
                      ListTile(
                        title: Text(o.label,
                            style: TextStyle(
                                color: o.mode == mode
                                    ? MusicTheme.tint
                                    : MusicTheme.label)),
                        trailing: o.mode == mode
                            ? Icon(Icons.check,
                                color: MusicTheme.tint, size: 18)
                            : null,
                        onTap: () => Navigator.pop(ctx, o.mode),
                      ),
                  ],
                ),
              ),
            );
            if (picked == null) return;
            // 改全局 ThemeModeStore —— 内部通过 GlobalThemeSync
            // 自动同步给音乐和阅读，三端一致。
            await ThemeModeStore.set(picked);
            // 壁纸会自动跟着换：`BackgroundService.currentSceneKey` 只读
            // `AppBrightness`，上面这行改完它就切到对应那套场景。
            //（原来还要调 `setAppearanceMode` 写第二份外观状态，已删除。）
          },
        );
      },
    );
  }
}

/// 主题配色选择器（7 套，与阅读/影视统一）
///
/// 直接操作 ModuleThemeStore（音乐模块的配色存在那里），
/// 和统一主题设置页的音乐区块是同一个数据源。
///
/// 用户 2026-10-16：「其余模块的主题样式的 UI 能不能也参考弄成阅读那样的」——
/// 原来这里是「34×34 三色环格点 + 名称在下」的 Wrap，与阅读那套
/// **全宽圆角行**不是一回事。现改为与阅读「主题风格」同款：
/// 一行入口 → 底部面板里是「三色点 + 名称 + 右侧单选圈」。
class _AccentPicker extends StatelessWidget {
  const _AccentPicker();

  @override
  Widget build(BuildContext context) {
    final store = ModuleThemeStore.instance;
    return ValueListenableBuilder<int>(
      valueListenable: store.revision,
      builder: (context, _, __) {
        final current = store.rawPreset(ModuleThemeStore.music);
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text('主题配色',
                      style:
                          TextStyle(color: MusicTheme.label, fontSize: AppTheme.fontHeadline)),
                  const Spacer(),
                  Text(
                    current == ModuleThemeStore.followReading
                        ? '跟随阅读'
                        : _presetName(current),
                    style: TextStyle(
                        fontSize: AppTheme.fontFootnote,
                        color: MusicTheme.secondary),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // 与阅读「主题风格」面板同款的行（点开底部面板再选）
              ThemePresetRow(
                name: '选择主题',
                subtitle: '与阅读「主题风格」同一套样式',
                dots: _dotsOf(current, store),
                selected: false,
                trailing: Icon(Icons.chevron_right_rounded,
                    size: 20, color: MusicTheme.secondary),
                onTap: () => _openPicker(context, current),
              ),
            ],
          ),
        );
      },
    );
  }

  String _presetName(String id) => ModuleThemeStore.instance.displayNameOf(id);

  /// 三色点：主色 / 强调色 / 浅底（与阅读面板上的色点同一取法）。
  /// 「跟随阅读」时直接显示阅读当前那套，用户一眼能看出跟随的是什么。
  ///
  /// ⚠️ 走 `paletteOf` 而不是 `JellyPalette.fromPreset`：阅读用**自定义主题**
  /// 时 id 是 `custom_*`，直接 fromPreset 会回退「魅力紫」，色点就错了。
  List<Color> _dotsOf(String id, ModuleThemeStore store) {
    final palette = store.paletteOf(
        id == ModuleThemeStore.followReading ? store.readingPreset : id);
    return [palette.primary, palette.accent, palette.backgroundLight];
  }

  /// 打开选主题弹窗。
  ///
  /// ── 用户 2026-10-16 报的两个问题，都在这里解决 ──────────────────
  /// ① **「退出音乐模块弹窗还留着」**：底栏是 `IndexedStack` 切 tab，
  ///    切 tab **不会 pop 路由** → 弹窗会盖到影视/阅读上面去。
  ///    所以弹窗期间监听主 tab，一旦不是音乐就立刻关。
  /// ② **「和悬浮菜单栏冲突」**：原来用的是全宽**底部面板**，正好压在
  ///    音乐自己的悬浮播放条 + 导航栏那一块。改用音乐模块统一的
  ///    [showMusicSheet]（**屏幕中间弹出**，约 4 行高、内部滚动），
  ///    与「音质 / 封面形态」那些弹窗同一套观感。
  Future<void> _openPicker(BuildContext context, String current) async {
    final store = ModuleThemeStore.instance;

    Future<void> pick(String id) async {
      await store.setPreset(ModuleThemeStore.music, id);
      // ⚠️ 必须落地：`setPreset` 只改 store 的数据。
      // 不调 `applyModuleThemes()` 的话，注入给音乐的强调色
      // （`MusicTheme._customAccent`）不会更新，也不会通知
      // 音乐 UI 重建 —— 表现是"只有圆点的勾移动了，
      // 底色/强调色不同步或不刷新"。
      await applyModuleThemes();
    }

    final tab = MainTabController.instance.selectedTab;
    var closed = false;
    void onTabChanged(int _) {
      if (closed) return;
      if (tab.value == MainTabController.musicTabIndex) return;
      closed = true;
      Navigator.of(context, rootNavigator: true).pop();
    }

    // GetX 的 Rx 用 `ever` 订阅（`addListener` 的签名是 RxInterface 那套，
    // 传普通回调会报 argument_type_not_assignable）
    final worker = ever<int>(tab, onTabChanged);
    try {
      await showMusicSheet<void>(
        context: context,
        isScrollControlled: true,
        // 行里的颜色都取自 AppTheme（与影视/设置页同一套），底色也用同一套，
        // 免得音乐自己的卡片色和它撞色
        backgroundColor: AppTheme.backgroundSecondary,
        builder: (sheetCtx) => SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 10),
                child: Text('主题风格',
                    style: TextStyle(
                        color: MusicTheme.label,
                        fontSize: AppTheme.fontTitle3,
                        fontWeight: FontWeight.w600)),
              ),
              ThemePresetRow(
                name: '跟随阅读',
                subtitle: '与阅读模块当前配色一致',
                dots: _dotsOf(ModuleThemeStore.followReading, store),
                selected: current == ModuleThemeStore.followReading,
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  pick(ModuleThemeStore.followReading);
                },
              ),
              for (final p in themePresets)
                ThemePresetRow(
                  name: p.name,
                  dots: _dotsOf(p.id, store),
                  selected: current == p.id,
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    pick(p.id);
                  },
                ),
            ],
          ),
        ),
      );
    } finally {
      closed = true;
      worker.dispose();
    }
  }
}

/// 标题后面那个淡淡的「？」—— 点开才显示这一项的说明。
///
/// 用户 2026-10-30：「音乐里面的小字也不要，然后加？来说明」。
/// 说明文字本身**不删**（删了就没法解释这个开关干什么），只是从
/// "每行都挂着的小字"变成"点开才看"。
///
/// 样式刻意压得很轻（14px、secondary 色、无边框），避免又变成一屏噪音。
class _HelpDot extends StatelessWidget {
  const _HelpDot({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => showMusicSheet<void>(
        context: context,
        backgroundColor: MusicTheme.card,
        builder: (ctx) => SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(22, 20, 22, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '说明',
                  style: TextStyle(
                    color: MusicTheme.label,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  text,
                  style: TextStyle(
                    color: MusicTheme.secondary,
                    fontSize: AppTheme.fontFootnote,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: Text('知道了',
                        style: TextStyle(color: MusicTheme.tint)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Icon(
          Icons.help_outline_rounded,
          size: 14,
          color: MusicTheme.secondary.withValues(alpha: 0.75),
        ),
      ),
    );
  }
}
