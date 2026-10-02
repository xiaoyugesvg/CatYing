import 'dart:async';
import '../../widgets/common_widgets.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart'
    show VideoController, Video, AdaptiveVideoControls;

import '../../common/theme.dart';
import '../../common/system_ui.dart';
import '../../models/live_models.dart';
import '../../services/epg_service.dart';
import '../../services/live_service.dart';
import '../../services/main_tab_controller.dart';
import '../../services/player_fullscreen_controller.dart';
import '../../widgets/app_player.dart';
import '../../widgets/ios_av_player.dart';
import '../../widgets/video_player_pip.dart';
import 'controller.dart';
import '../../services/audio_focus.dart';
import '../../widgets/app_empty_view.dart';
import '../../widgets/app_toast.dart';

/// 直播主界面（对照参考图）
/// 上：视频区 + LIVE 角标 + 小窗/全屏
/// 下：播放源下拉 + 频道列表（TV 图标 + 状态）
class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  final _controller = Get.put(LiveController());
  Player? _player;
  VideoController? _videoController;

  /// iOS：与点播共用 IosAvPlayer（AvEngine）
  IosAvPlayer? _avPlayer;
  bool _fullscreen = false;
  bool _audioMode = false;
  int _activeGroupIndex = 0;
  String? _playError;

  /// 正在切台/加载流（显示播放器中间转圈）
  bool _switching = false;

  /// 加载遮罩兜底计时器
  Timer? _switchTimer;

  /// 「出画面」监听（position 前进即视为开播）
  StreamSubscription? _switchReadySub;
  StreamSubscription<dynamic>? _errSub;
  Worker? _tabWorker;

  @override
  void initState() {
    super.initState();
    // IndexedStack 会在 App 启动时构建所有 tab（含直播页）。
    // 只有当前选中「直播」tab 才自动开播，避免一打开软件就在播直播。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MainTabController.instance.selectedTab.value == 4) {
        _autoplayCurrent();
      }
    });
    // 离开直播 tab 时暂停；切回直播 tab 时若未在播则自动开播
    _tabWorker = ever(MainTabController.instance.selectedTab, (tab) {
      if (tab != 4) {
        try {
          _player?.pause();
        } catch (e) {
          /* ignore */
        }
      } else {
        final playing = _player?.state.playing ?? false;
        if (!playing) {
          _autoplayCurrent();
        }
      }
    });
    // 点播/音乐要出声时会通过 AudioFocus 让直播暂停。
    //
    // ⚠️ 原来这里注册的是 `LiveService.pauseLivePlayer` ——
    // 那个回调**只覆盖「点播 ⇄ 直播」**，音乐完全没参与，
    // 于是"听音乐时打开视频"/"看视频时音乐还在响"两边一起出声。
    // 现在统一走 AudioFocus（三方都注册），任一方出声都会让另两方闭嘴。
    AudioFocus.register('live', () async {
      try {
        await _player?.pause();
      } catch (e) {
        /* 暂停失败不影响其它方，AudioFocus 会记日志 */
      }
    });
  }

  @override
  void dispose() {
    AudioFocus.unregister('live');
    _tabWorker?.dispose();
    _errSub?.cancel();
    _switchReadySub?.cancel();
    _switchTimer?.cancel();
    _player?.dispose();
    _player = null;
    _avPlayer?.dispose();
    _avPlayer = null;
    _videoController = null;
    super.dispose();
  }

  /// 播放当前选中频道；无地址则跳过
  void _autoplayCurrent() {
    // 直播要出声了 → 让音乐/点播先闭嘴（用户能直接听到的"双声"问题）
    unawaited(AudioFocus.request('live'));
    final url = _controller.currentChannel?.playUrl ?? '';
    if (url.isEmpty) return;
    _playChannel(url);
  }

  void _playChannel(String url) {
    if (url.isEmpty) return;
    _playError = null;
    // 切台时先亮起「加载中」遮罩：新流从 open 到出画面有几百毫秒到几秒，
    // 期间老画面还在，没有反馈会让人以为点了没反应。
    _switching = true;
    _switchTimer?.cancel();
    // 兜底：最多显示 20 秒（真正就绪时由 position/buffering 监听提前清掉）
    _switchTimer = Timer(const Duration(seconds: 20), () {
      if (mounted && _switching) setState(() => _switching = false);
    });
    // 复用同一 Player，切台只 open 新地址，避免黑屏/闪断
    _player ??= Player(
      configuration: const PlayerConfiguration(title: '猫影直播'),
    );
    _videoController ??= VideoController(_player!);
    // HLS/FLV/TS/MP4/RTMP/RTSP：带全量请求头，提升 mp4 直链与 CDN 可播性
    String origin = '';
    String referer = '';
    try {
      final u = Uri.parse(url);
      if (u.hasScheme && u.host.isNotEmpty) {
        final base = '${u.scheme}://${u.host}${u.hasPort ? ':${u.port}' : ''}';
        origin = base;
        referer = '$base/';
      }
    } catch (e) {
      /* ignore */
    }
    final headers = <String, String>{
      'User-Agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Connection': 'keep-alive',
      if (referer.isNotEmpty) 'Referer': referer,
      if (origin.isNotEmpty) 'Origin': origin,
    };
    if (Platform.isIOS) {
      // 与点播同一 AVPlayer 内核，进出小窗/手势一致
      _avPlayer ??= IosAvPlayer(config: const AppConfig(title: '猫影直播'));
      _avPlayer!.open(AppMedia(url, httpHeaders: headers));
    } else {
      _player!.open(Media(url, httpHeaders: headers));
    }
    // 预热原生 PiP，否则点小窗时 AVPlayer 冷启动易失败/黑屏
    if (Platform.isIOS) {
      VideoPlayerPip.instance.prepareIos(url: url, headers: headers);
    }
    // 订阅播放错误，避免一直转圈无提示
    _errSub?.cancel();
    _switchReadySub?.cancel();
    _switchTimer?.cancel();
    _errSub = _player!.stream.error.listen((msg) {
      if (!mounted) return;
      setState(() {
        _playError = msg.isEmpty ? '播放失败，点此重试' : msg;
        _switching = false;
      });
    });
    // 出画面了就撤掉「加载中」遮罩（position 前进即视为已开播）
    _switchReadySub?.cancel();
    _switchReadySub = _player!.stream.position.listen((pos) {
      if (!mounted) return;
      if (_switching && pos > Duration.zero) {
        _switchTimer?.cancel();
        setState(() => _switching = false);
      }
    });
    setState(() {});
  }

  Future<void> _togglePip() async {
    final ch = _controller.currentChannel;
    final url = ch?.playUrl ?? '';
    if (url.isEmpty) {
      AppToast.message('请先选择频道');
      return;
    }
    try {
      final supported = await VideoPlayerPip.instance.isIosPipSupported();
      if (!supported) {
        AppToast.message('当前设备不支持系统小窗（需真机 iOS）');
        return;
      }
      final pos = _player?.state.position ?? Duration.zero;
      // 先预热原生 AVPlayer，再启动 PiP，降低“点了没小窗”的概率
      final pipHeaders = <String, String>{
        'User-Agent':
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      };
      await VideoPlayerPip.instance.prepareIos(url: url, headers: pipHeaders);
      // 单实例 AVPlayer：进/出小窗都不要 pause，否则小窗冻结/回 App 停播
      final ok = await VideoPlayerPip.instance.enterIos(
        url: url,
        headers: pipHeaders,
        position: pos,
        onStarted: () {
          // 系统接管同一 layer，无需暂停
        },
        onStopped: () {
          // 同一播放器继续播，只收 UI
          if (mounted) setState(() {});
        },
      );
      if (!ok) {
        AppToast.message('小窗启动失败');
      }
    } catch (e) {
      AppToast.message('小窗失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _fullscreen ? Colors.black : AppTheme.backgroundPrimary,
      body: GetBuilder<LiveController>(
        builder: (c) {
          final groups = c.groups;
          final channels = c.channels;
          final current = c.currentChannel;
          final currentSourceName = c.currentSourceName;
          final currentGroupName = c.currentGroupName;
          final sources = c.sources;
          // 视频层常驻 Stack 首位：全屏/普通切换只改高度，Video 永不重建
          // （修复直播全屏/横屏后"有声音没画面"——同一 VideoController
          //   被反复 attach/detach 时 media_kit 渲染层会黑屏）
          return LayoutBuilder(
            builder: (ctx, cons) {
              final pad = MediaQuery.of(ctx).padding;
              final topBar = _fullscreen ? 0.0 : (pad.top > 0 ? pad.top : 0.0);
              final videoHeight = _fullscreen
                  ? cons.maxHeight - topBar
                  : cons.maxWidth * 9 / 16;
              return Column(
                children: [
                  // 状态栏高度黑边：状态栏压在黑边上，不与画面重叠
                  if (topBar > 0)
                    // ⚠️ 这一条正好覆盖状态栏区域，所以在这里发"浅色图标"：
                    // 本页没有 AppBar，不标注的话会沿用上一条路由的样式，
                    // 浅色模式下就是"深色图标压黑边"，看不见。
                    AnnotatedRegion<SystemUiOverlayStyle>(
                      value: SystemUiOverlayStyle.light,
                      child: SizedBox(
                        height: topBar,
                        child: const ColoredBox(color: Colors.black),
                      ),
                    ),
                  // 视频层（全屏时吃掉剩余高度）
                  SizedBox(
                    height: videoHeight,
                    width: double.infinity,
                    child: _buildVideoLayer(c, current),
                  ),
                  // 非全屏：内容层（选择器 + 频道列表）
                  if (!_fullscreen)
                    Expanded(
                      child: Column(
                        children: [
                          Obx(() {
                            final err = LiveService.instance.error.value;
                            if (err == null) return const SizedBox.shrink();
                            final loading =
                                LiveService.instance.isLoading.value;
                            // 按你的要求：**不显示红色错误文案与「重试」文字**。
                            // 源加载失败时只在播放器/列表上方放一个圆形的
                            // 重试图标按钮（无文字），点它重新加载。
                            return Padding(
                              padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
                              child: Row(
                                children: [
                                  GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTap: loading
                                        ? null
                                        : () =>
                                              LiveService.instance.retryLast(),
                                    child: Container(
                                      width: 32,
                                      height: 32,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: AppTheme.accentColor.withValues(
                                          alpha: 0.14,
                                        ),
                                        border: Border.all(
                                          color: AppTheme.accentColor
                                              .withValues(alpha: 0.45),
                                          width: 0.8,
                                        ),
                                      ),
                                      child: loading
                                          ? SizedBox(
                                              width: 14,
                                              height: 14,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 1.8,
                                                color: AppTheme.accentColor,
                                              ),
                                            )
                                          : Icon(
                                              Icons.refresh_rounded,
                                              size: 18,
                                              color: AppTheme.accentColor,
                                            ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    loading ? '正在加载源…' : '加载失败',
                                    style: TextStyle(
                                      color: AppTheme.textTertiary,
                                      fontSize: AppTheme.fontFootnote,
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }),
                          // 加载中细进度条（缓存已出列表时也能看到在刷新）
                          Obx(() {
                            if (!LiveService.instance.isLoading.value) {
                              return SizedBox(height: 2);
                            }
                            return Padding(
                              padding: EdgeInsets.fromLTRB(12, 4, 12, 0),
                              child: LinearProgressIndicator(
                                minHeight: 2,
                                color: AppTheme.accentColor,
                                // 原来写死 Colors.white12：浅色模式下进度槽
                                // 在白底上完全不可见。跟随主题三级色。
                                backgroundColor:
                                    AppTheme.textTertiary.withValues(alpha: 0.25),
                              ),
                            );
                          }),
                          const SizedBox(height: 8),
                          // 双层选择器：直播源 + 分组
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            child: Row(
                              children: [
                                // 刷新按钮
                                GestureDetector(
                                  onTap: _onRefreshSource,
                                  child: Container(
                                    width: 38,
                                    height: 38,
                                    decoration: BoxDecoration(
                                      color: AppTheme.backgroundTertiary,
                                      shape: BoxShape.circle,
                                    ),
                                    child: Icon(
                                      Icons.refresh,
                                      color: AppTheme.textSecondary,
                                      size: 18,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // 直播源选择（左下拉）
                                Expanded(
                                  child: GestureDetector(
                                    onTap: () => _showSourcePicker(context, c),
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 9,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppTheme.backgroundTertiary,
                                        borderRadius: BorderRadius.circular(20),
                                        border: Border.all(
                                          color: AppTheme.accentColor
                                              .withValues(alpha: 0.3),
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.rss_feed,
                                            color: AppTheme.accentColor,
                                            size: 16,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              currentSourceName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: AppTheme.accentColor,
                                                fontSize: AppTheme.fontSubhead,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                          Icon(
                                            Icons.arrow_drop_down,
                                            color: AppTheme.textSecondary,
                                            size: 18,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                // 分组选择（右下拉）
                                Expanded(
                                  child: GestureDetector(
                                    onTap: groups.isEmpty
                                        ? null
                                        : () => _showGroupPicker(
                                            context,
                                            c,
                                            groups,
                                          ),
                                    child: Container(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 9,
                                      ),
                                      decoration: BoxDecoration(
                                        color: AppTheme.backgroundTertiary,
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            Icons.playlist_play,
                                            color: AppTheme.textSecondary,
                                            size: 16,
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              currentGroupName,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                color: AppTheme.textPrimary,
                                                fontSize: AppTheme.fontSubhead,
                                              ),
                                            ),
                                          ),
                                          Icon(
                                            Icons.arrow_drop_down,
                                            color: AppTheme.textSecondary,
                                            size: 18,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          // 跨组搜索 + 只看收藏
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  onChanged: (v) {
                                    c.searchKeyword.value = v;
                                    c.update();
                                  },
                                  style: TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: AppTheme.fontSubhead,
                                  ),
                                  decoration: InputDecoration(
                                    isDense: true,
                                    hintText: '搜索频道（跨分组）',
                                    hintStyle: TextStyle(
                                      color: AppTheme.textTertiary,
                                      fontSize: AppTheme.fontFootnote,
                                    ),
                                    prefixIcon: Icon(
                                      Icons.search,
                                      size: 18,
                                      color: AppTheme.textTertiary,
                                    ),
                                    filled: true,
                                    fillColor: AppTheme.backgroundTertiary,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 8,
                                    ),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(12),
                                      borderSide: BorderSide.none,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              GestureDetector(
                                onTap: () => _showEpgSheet(context, c),
                                child: Container(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 10,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppTheme.backgroundTertiary,
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Icon(
                                    Icons.schedule,
                                    size: 18,
                                    color: AppTheme.textSecondary,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Obx(() {
                                final onlyFav = c.showOnlyFavorites.value;
                                return GestureDetector(
                                  onTap: () {
                                    c.showOnlyFavorites.value = !onlyFav;
                                    c.update();
                                  },
                                  child: Container(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 10,
                                    ),
                                    decoration: BoxDecoration(
                                      color: onlyFav
                                          ? AppTheme.accentColor.withValues(
                                              alpha: 0.2,
                                            )
                                          : AppTheme.backgroundTertiary,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Icon(
                                      onlyFav ? Icons.star : Icons.star_border,
                                      size: 18,
                                      color: onlyFav
                                          ? AppTheme.accentColor
                                          : AppTheme.textSecondary,
                                    ),
                                  ),
                                );
                              }),
                            ],
                          ),
                          const SizedBox(height: 8),
                          // 频道列表（占满宽度）
                          Expanded(
                            child: Obx(() {
                              // 切换直播源 / 分组时给明确反馈，
                              // 否则列表为空的那段时间就是一片黑，不知道在加载还是坏了。
                              final loading =
                                  LiveService.instance.isLoading.value;
                              if (loading && channels.isEmpty) {
                                return Center(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      SizedBox(
                                        width: 26,
                                        height: 26,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.4,
                                          color: AppTheme.accentColor,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Text(
                                        '正在加载频道…',
                                        style: TextStyle(
                                          color: AppTheme.textSecondary,
                                          fontSize: AppTheme.fontSubhead,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '切换直播源需要几秒',
                                        style: TextStyle(
                                          color: AppTheme.textTertiary,
                                          fontSize: AppTheme.fontCaption,
                                        ),
                                      ),
                                    ],
                                  ),
                                );
                              }
                              if (groups.isEmpty) {
                                return _EmptyLive(
                                  onReload: () => _pickSource(context, c),
                                );
                              }
                              return Stack(
                                children: [
                                  _buildChannelList(c, channels),
                                  // 已有旧列表时：叠加一层半透明遮罩 + 转圈，
                                  // 让"正在换源"这件事可见，又不丢掉旧内容。
                                  if (loading)
                                    Positioned.fill(
                                      child: IgnorePointer(
                                        child: Container(
                                          color: AppTheme.backgroundPrimary
                                              .withValues(alpha: 0.45),
                                          child: Center(
                                            child: SizedBox(
                                              width: 24,
                                              height: 24,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2.2,
                                                color: AppTheme.accentColor,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              );
                            }),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _pickSource(BuildContext context, LiveController c) async {
    // 导入/覆盖直播源（m3u/txt URL）——左栏底部 + 号进入
    final url = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final ctrl = TextEditingController();
        return AlertDialog(
          backgroundColor: AppTheme.backgroundSecondary,
          title: Text(
            '导入直播源',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: AppTheme.fontHeadline,
            ),
          ),
          content: TextField(
            controller: ctrl,
            style: TextStyle(color: AppTheme.textPrimary),
            decoration: InputDecoration(
              hintText: 'm3u / txt 地址',
              hintStyle: TextStyle(color: AppTheme.textTertiary),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
              child: const Text('加载'),
            ),
          ],
        );
      },
    );
    if (url != null && url.isNotEmpty) {
      await c.reloadFromUrl(url);
      if (mounted) {
        c.selectGroup(0);
        _autoplayCurrent();
      }
    }
  }

  /// 投屏入口（DLNA/UPnP）—— 与点播播放器同通道
  void _toggleCast() {
    final ch = _controller.currentChannel;
    final url = ch?.playUrl ?? '';
    if (url.isEmpty) {
      AppToast.message('请先选择频道');
      return;
    }
    Get.toNamed(
      '/dlna',
      parameters: {
        'url': url,
        'title': ch!.name,
      },
    );
  }

  void _toggleAudioMode() {
    // 若尚未开播，先起播再进听剧，否则只有壳没有声音
    if (!_audioMode && (_player == null || !_player!.state.playing)) {
      _autoplayCurrent();
    }
    setState(() => _audioMode = !_audioMode);
    // 进入听剧时保持播放（后台可续播由 UIBackgroundModes=audio 保证）
  }

  /// 全屏：只显示视频画面（横屏铺满），左上返回、右上频道名+退出全屏
  /// 视频层（常驻 Stack 首位）：全屏/普通切换只改外层高度，Video 永不重建
  /// 修复直播全屏后"有声音没画面"（同一 VideoController 反复 attach 黑屏）
  Widget _buildVideoLayer(LiveController c, LiveChannel? current) {
    final pad = MediaQuery.of(context).padding;
    // 画面已在状态栏黑边之下，控件只需少量上边距，不必再吃 safe-area
    final topInset = _fullscreen ? (pad.top > 0 ? pad.top : 12.0) : 8.0;
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 视频层常驻（听剧时透明隐藏，不从树上摘掉，保证音轨不断、退出听剧能恢复画面）
          if ((Platform.isIOS && _avPlayer != null) ||
              (_videoController != null && current != null))
            Opacity(
              opacity: _audioMode ? 0.0 : 1.0,
              child: (Platform.isIOS && _avPlayer != null)
                  ? AppVideoView(player: _avPlayer!)
                  : Video(
                      controller: _videoController!,
                      controls: AdaptiveVideoControls,
                    ),
            )
          else
            Center(
              child: Icon(
                Icons.live_tv,
                // ── ⚠️ 必须是**白色**，不能跟主题走 ────────────────
                // 这个图标画在 `_buildVideoLayer` 的容器里，而那个容器是
                // **`color: Colors.black`（视频区永远是黑的）**。
                //
                // 原来用 `AppTheme.textTertiary`（= #8E8E93），
                // **浅色模式下对比度不足、看起来发灰不明显**
                // （用户实测："直播的播放按钮在浅色模式下应该是白色的"）。
                // 视频区的图标不该随全局明暗变 —— 背景永远是黑的。
                color: Colors.white.withValues(alpha: 0.72),
                size: 56,
              ),
            ),
          // 切台加载中：播放器正中间转圈（无文字干扰）
          if (_switching && !_audioMode && _playError == null)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.35),
                  alignment: Alignment.center,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 34,
                        height: 34,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.6,
                          color: Colors.white.withValues(alpha: 0.92),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '正在加载…',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: AppTheme.fontFootnote,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          // 播放失败：**不显示红字/错误文案**，只在播放器正中间放一个
          // 重试图标按钮。点它重新拉流，成功就自动开始播。
          if (_playError != null && !_audioMode)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  final url = current?.playUrl ?? '';
                  if (url.isNotEmpty) {
                    setState(() => _playError = null);
                    _playChannel(url);
                  }
                },
                child: Container(
                  color: Colors.black.withValues(alpha: 0.45),
                  alignment: Alignment.center,
                  child: Container(
                    width: 64,
                    height: 64,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.14),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.5),
                        width: 1.4,
                      ),
                    ),
                    child: const Icon(
                      Icons.refresh_rounded,
                      color: Colors.white,
                      size: 32,
                    ),
                  ),
                ),
              ),
            ),
          if (_audioMode) _buildAudioModeOverlay(c, current),
          // 普通模式左上：返回 + LIVE 角标
          if (!_fullscreen)
            Positioned(
              top: topInset,
              left: 4 + pad.left,
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () {
                      if (MainTabController.instance.selectedTab.value == 4) {
                        MainTabController.instance.selectedTab.value = 0;
                      } else {
                        Get.back();
                      }
                    },
                    child: Container(
                      width: 40,
                      height: 40,
                      alignment: Alignment.center,
                      child: Icon(
                        // ⚠️ 这一层恒为黑底视频（见本文件 :732 的 Colors.black），
                        // 前景必须白色：浅色模式下 AppTheme.textPrimary 是深色，
                        // 深色图标压黑视频 = 返回键看不见。
                        Icons.arrow_back_ios_new,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'LIVE',
                          style: TextStyle(
                            // 角标底是半透明黑（:865），文字必须白色
                            color: Colors.white,
                            fontSize: AppTheme.fontCaption,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.5,
                          ),
                        ),
                        SizedBox(width: 5),
                        _LiveDot(size: 7),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          // 全屏：左上返回（退出全屏并回首页/退路由）
          if (_fullscreen)
            Positioned(
              top: 8 + topInset,
              left: 8 + pad.left,
              child: GestureDetector(
                onTap: () {
                  _toggleFullscreen();
                  if (MainTabController.instance.selectedTab.value == 4) {
                    MainTabController.instance.selectedTab.value = 0;
                  } else {
                    Get.back();
                  }
                },
                child: Container(
                  width: 40,
                  height: 40,
                  alignment: Alignment.center,
                  child: Icon(
                    // 同 _VideoTopIcon：黑底视频层上必须用白色
                    Icons.arrow_back_ios_new,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ),
          // 右上：功能按钮（听剧/小窗/投屏/全屏）
          Positioned(
            top: topInset,
            right: 8 + pad.right,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_fullscreen && current != null)
                  Container(
                    constraints: const BoxConstraints(maxWidth: 150),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    child: Text(
                      current.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: AppTheme.fontCaption,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                _VideoTopIcon(
                  icon: _audioMode
                      ? Icons.headphones
                      : Icons.headphones_outlined,
                  onTap: _toggleAudioMode,
                  tooltip: '听剧模式',
                ),
                _VideoTopIcon(
                  icon: Icons.picture_in_picture_alt,
                  onTap: _togglePip,
                  tooltip: '小窗播放',
                ),
                _VideoTopIcon(
                  icon: Icons.cast,
                  onTap: _toggleCast,
                  tooltip: '投屏',
                ),
                _VideoTopIcon(
                  icon: _fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  onTap: _toggleFullscreen,
                  tooltip: _fullscreen ? '退出全屏' : '全屏',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAudioModeOverlay(LiveController c, LiveChannel? current) {
    final name = current?.name ?? '';
    return Container(
      color: Colors.black,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.headphones, color: Colors.white70, size: 44),
            const SizedBox(height: 16),
            if (name.isNotEmpty)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    // 听剧模式整屏黑底（:972），必须白色
                    color: Colors.white,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            const SizedBox(height: 6),
            Text(
              '听剧模式 · 后台可继续播放',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: AppTheme.fontCaption,
              ),
            ),
            const SizedBox(height: 18),
            GestureDetector(
              onTap: _toggleAudioMode,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '退出听剧模式',
                  style: TextStyle(
                    // 同上：黑底
                    color: Colors.white,
                    fontSize: AppTheme.fontFootnote,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 左栏：直播源列表（参考图：一侧是直播源）——绿点=已加载，灰点=未下载
  /// 刷新当前直播源
  void _onRefreshSource() {
    final c = _controller;
    if (c.sources.isEmpty) {
      _pickSource(context, c);
      return;
    }
    // 刷新当前选中的源
    final index = c.selectedSourceIndex;
    if (index >= 0 && index < c.sources.length) {
      c.selectSource(index).then((_) {
        if (mounted) _autoplayCurrent();
      });
      AppToast.message('正在刷新直播源...', duration: const Duration(seconds: 1));
    }
  }

  /// 显示直播源选择弹窗 — 居中、不透明、过高可滚动
  Future<void> _showSourcePicker(BuildContext context, LiveController c) async {
    final srcs = LiveService.instance.sources;
    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: AppTheme.backgroundSecondary,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 28,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.55,
              maxWidth: 360,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 18, 12, 8),
                  child: Row(
                    children: [
                      Text(
                        '选择直播源',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _pickSource(context, c);
                        },
                        child: const Text('添加源'),
                      ),
                    ],
                  ),
                ),
                if (srcs.isEmpty)
                  Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      '还没有直播源，点击右上角添加',
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontSubhead,
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      itemCount: srcs.length,
                      separatorBuilder: (_, __) =>
                          Divider(height: 1, color: AppTheme.borderLight),
                      itemBuilder: (_, i) {
                        final src = srcs[i];
                        final isActive = c.selectedSourceIndex == i;
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.play_circle_fill,
                            color: isActive
                                ? AppTheme.accentColor
                                : AppTheme.textTertiary,
                            size: 22,
                          ),
                          title: Text(
                            src.name,
                            style: TextStyle(
                              color: isActive
                                  ? AppTheme.accentColor
                                  : AppTheme.textPrimary,
                              fontSize: AppTheme.fontBody,
                            ),
                          ),
                          subtitle: Text(
                            isActive ? '当前播放' : '未下载',
                            style: TextStyle(
                              color: isActive
                                  ? AppTheme.accentColor.withValues(alpha: 0.7)
                                  : AppTheme.textTertiary,
                              fontSize: AppTheme.fontCaption,
                            ),
                          ),
                          trailing: isActive
                              ? Icon(
                                  Icons.check_circle,
                                  color: AppTheme.accentColor,
                                  size: 20,
                                )
                              : null,
                          onTap: () async {
                            Navigator.pop(ctx);
                            await c.selectSource(i);
                            if (mounted) _autoplayCurrent();
                          },
                        );
                      },
                    ),
                  ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 显示分组选择弹窗 — 居中、不透明、过高可滚动
  Future<void> _showGroupPicker(
    BuildContext context,
    LiveController c,
    List<LiveGroup> groups,
  ) async {
    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          backgroundColor: AppTheme.backgroundSecondary,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 28,
            vertical: 24,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.55,
              maxWidth: 360,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 18, 20, 10),
                  child: Text(
                    '选择分组',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    itemCount: groups.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: AppTheme.borderLight),
                    itemBuilder: (_, i) {
                      final g = groups[i];
                      final selected = c.selectedGroup == i;
                      return ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.playlist_play,
                          color: selected
                              ? AppTheme.accentColor
                              : AppTheme.textTertiary,
                          size: 22,
                        ),
                        title: Text(
                          g.name,
                          style: TextStyle(
                            color: selected
                                ? AppTheme.accentColor
                                : AppTheme.textPrimary,
                            fontSize: AppTheme.fontBody,
                          ),
                        ),
                        subtitle: Text(
                          '${g.channels.length} 个频道',
                          style: TextStyle(
                            color: AppTheme.textTertiary,
                            fontSize: AppTheme.fontCaption,
                          ),
                        ),
                        trailing: selected
                            ? Icon(
                                Icons.check_circle,
                                color: AppTheme.accentColor,
                                size: 20,
                              )
                            : null,
                        onTap: () {
                          Navigator.pop(ctx);
                          c.selectGroup(i);
                          setState(() => _activeGroupIndex = i);
                          _autoplayCurrent();
                        },
                      );
                    },
                  ),
                ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showAnnouncements(BuildContext context) {
    final list = LiveService.instance.announcements;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      builder: (ctx) => kbSheet(
        SafeArea(
          child: list.isEmpty
              ? Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    '暂无公告',
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontSubhead,
                    ),
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        '公告',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontHeadline,
                        ),
                      ),
                    ),
                    for (final item in list)
                      ListTile(
                        dense: true,
                        leading: Icon(
                          Icons.tv,
                          color: AppTheme.textSecondary,
                          size: 20,
                        ),
                        title: Text(
                          item,
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: AppTheme.fontSubhead,
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  Future<void> _toggleFullscreen() async {
    setState(() => _fullscreen = !_fullscreen);
    // 通知全局：全屏时隐藏底部悬浮导航栏
    if (_fullscreen) {
      PlayerFullscreenController.instance.enter('live');
    } else {
      PlayerFullscreenController.instance.exit('live');
    }
    if (_fullscreen) {
      await SystemUiController.enter(
        'live',
        mode: SystemUiMode.immersiveSticky,
        // 横屏 + 跟随设备方向，避免只锁左/右横屏时布局错乱
        orientations: Platform.isIOS
            ? const [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : null,
        // 视频黑底 → 浅色状态栏图标
        overlayStyle: SystemUiOverlayStyle.light,
      );
    } else {
      // 恢复**进入前**的方向与系统栏状态
      // （原来无条件写死"竖屏+左右横屏"，会覆盖别的页面设定的方向锁）
      await SystemUiController.exit('live');
    }
  }

  Future<void> _showEpgSheet(BuildContext context, LiveController c) async {
    final ch = c.currentChannel;
    if (ch == null) return;
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.backgroundPrimary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.5,
          child: FutureBuilder<List<EpgProgram>>(
            future: EpgService.instance.programsFor(ch.name),
            builder: (context, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final list = snap.data ?? <EpgProgram>[];
              if (list.isEmpty) {
                return Center(
                  child: Text(
                    '暂无节目单\n请在 直播设置 里配置 EPG 地址',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                );
              }
              final now = DateTime.now();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                    child: Text(
                      '节目单 · ${ch.name}',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView.builder(
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: list.length,
                      itemBuilder: (_, i) {
                        final p = list[i];
                        final playing =
                            p.start != null &&
                            p.stop != null &&
                            now.isAfter(p.start!) &&
                            now.isBefore(p.stop!);
                        return ListTile(
                          dense: true,
                          title: Text(
                            p.title,
                            style: TextStyle(
                              color: playing
                                  ? AppTheme.accentColor
                                  : AppTheme.textPrimary,
                              fontWeight: playing
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                          trailing: Text(
                            EpgService.instance.formatTime(p.start),
                            style: TextStyle(
                              color: playing
                                  ? AppTheme.accentColor
                                  : AppTheme.textTertiary,
                              fontSize: AppTheme.fontFootnote,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildChannelList(LiveController c, List<LiveChannel> channels) {
    if (channels.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tv_off, color: AppTheme.textTertiary, size: 48),
            SizedBox(height: 12),
            Text(
              '该分组暂无频道',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontSubhead,
              ),
            ),
          ],
        ),
      );
    }
    return ListView.separated(
      padding: EdgeInsets.fromLTRB(12, 0, 12, 100),
      itemCount: channels.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: AppTheme.borderLight),
      itemBuilder: (_, i) {
        final ch = channels[i];
        final selected = c.selectedChannelIndex.value == i;
        final fav = c.isFavorite(ch);
        return ListTile(
          dense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          title: Text(
            ch.name,
            style: TextStyle(
              color: selected ? AppTheme.accentColor : AppTheme.textPrimary,
              fontSize: AppTheme.fontHeadline,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            ),
          ),
          subtitle: Text(
            ch.urls.isNotEmpty ? (ch.group) : '未下载',
            style: TextStyle(
              color: AppTheme.textTertiary,
              fontSize: AppTheme.fontCaption,
            ),
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => c.toggleFavorite(ch),
                child: Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(
                    fav ? Icons.star : Icons.star_border,
                    color: fav ? AppTheme.accentColor : AppTheme.textTertiary,
                    size: 20,
                  ),
                ),
              ),
              SizedBox(width: 4),
              Icon(
                Icons.play_circle_fill,
                color: selected
                    ? AppTheme.accentColor
                    : AppTheme.textTertiary.withValues(alpha: 0.5),
                size: 22,
              ),
            ],
          ),
          onTap: () {
            c.selectChannel(i);
            _playChannel(ch.playUrl);
          },
        );
      },
    );
  }
}

class _LiveDot extends StatefulWidget {
  final double size;
  const _LiveDot({this.size = 8});
  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween(begin: 0.35, end: 1.0).animate(_c),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: const BoxDecoration(
          color: Colors.redAccent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _TopIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _TopIcon({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: AppTheme.backgroundTertiary,
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: AppTheme.textSecondary, size: 18),
        ),
      ),
    );
  }
}

/// 视频画面上的顶栏功能按钮（半透明黑底 + 白色图标，与点播播放器风格一致）
class _VideoTopIcon extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final double size;
  const _VideoTopIcon({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.size = 20,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      preferBelow: false,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 38,
          height: 38,
          alignment: Alignment.center,
          // ⚠️ 这几个按钮画在黑底视频层上：不能用跟随主题的
          // AppTheme.textPrimary（浅色模式下是深色 → 图标隐形）。
          child: Icon(icon, color: Colors.white, size: size),
        ),
      ),
    );
  }
}

class _EmptyLive extends StatelessWidget {
  final VoidCallback onReload;
  const _EmptyLive({required this.onReload});

  @override
  Widget build(BuildContext context) {
    return AppEmptyView(
      icon: Icons.live_tv,
      title: '暂无直播频道',
      subtitle: '在订阅 JSON 的 lives 配置，或导入 m3u',
      iconColor: AppTheme.textTertiary,
      action: OutlinedButton(
        onPressed: onReload,
        child: Text('导入直播源', style: TextStyle(color: AppTheme.accentColor)),
      ),
    );
  }
}
