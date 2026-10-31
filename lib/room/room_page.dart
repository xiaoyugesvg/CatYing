import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/player_engine.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/widgets/app_player.dart';
import 'package:tvbox/widgets/ios_av_player.dart';
import 'package:tvbox/widgets/aether_player.dart';
import 'package:tvbox/widgets/mpv_app_player.dart';
import 'package:tvbox/widgets/video_player.dart';
import 'package:tvbox/widgets/live_danmu.dart';
import 'package:tvbox/room/room_models.dart';
import 'package:tvbox/room/room_session.dart';
import 'package:tvbox/room/room_source_picker.dart';

/// 「房间」播放页：播放器 + 成员 + 聊天。
///
/// ── 同步协议（watch-room-server）──────────────────────────────
///   · 房主 `play:update`：每 2 秒广播「地址 + 进度 + 播放态」，
///     顺便当房主心跳（服务端 30 秒收不到会清空片源）
///   · `play:seek` / `play:play` / `play:pause`：任何成员都能发，
///     服务端转发给房间里的其他人 ⇒ 大家都能暂停/拖进度
///   · `play:change`：房主换片（带上完整 PlayState）
///   · `chat:message`：聊天
///
/// 本地播放器的操作（点暂停、拖进度）没有可拦截的回调，所以用
/// 600ms 轮询做"变化检测"：播放态变了就发 play/pause，进度突跳就发 seek。
/// 应用远端事件时短暂静音（[._suppressUntil]），避免把别人的操作再弹回去。
class RoomPage extends StatefulWidget {
  const RoomPage({super.key});

  @override
  State<RoomPage> createState() => _RoomPageState();
}

class _RoomPageState extends State<RoomPage> {
  final _session = RoomSession.instance;
  final _chatCtrl = TextEditingController();
  final _chatScroll = ScrollController();

  AppPlayer? _player;

  /// 当前播放内容（房主选片 / 跟随服务端状态）
  PlayState? _media;

  StreamSubscription<RoomPlayEvent>? _playSub;
  Timer? _stateTimer;
  Timer? _watchTimer;

  DateTime _suppressUntil = DateTime.fromMillisecondsSinceEpoch(0);
  bool _lastPlaying = false;
  double _lastPos = 0;
  DateTime _lastPosAt = DateTime.now();
  int _lastMsgCount = 0;

  /// 聊天弹幕开关（房间内有效，不落盘：每次进房间默认开）
  bool _danmuOn = true;

  /// 聊天消息 → 弹幕。只取普通文本消息，系统提示（"xx 加入房间"）不上弹幕。
  ///
  /// 颜色按 userId 散列取一个柔和色，这样同一个人说话颜色固定，
  /// 一眼能分出是谁在说，又不会像纯白那样糊在亮画面上。
  List<LiveDanmuItem> get _danmuItems {
    const palette = [
      Color(0xFFFFFFFF),
      Color(0xFFFFD666),
      Color(0xFF7ED6FF),
      Color(0xFFB6F09C),
      Color(0xFFFFA8C8),
    ];
    final list = _session.messages;
    final out = <LiveDanmuItem>[];
    for (final m in list) {
      if (m.system) continue;
      if (m.type != 'text') continue;
      final text = m.content.trim();
      if (text.isEmpty) continue;
      final h = m.userId.hashCode.abs();
      out.add(
        LiveDanmuItem(
          id: m.id,
          text: text,
          color: palette[h % palette.length],
        ),
      );
    }
    return out;
  }

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
    _playSub = _session.playEvents.listen(_onPlayEvent);

    // 中途进房：服务端 room:join 已经把 currentState 带回来了
    final s = _session.playState;
    if (s != null && s.url.isNotEmpty) {
      _media = s;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _open(s);
      });
    }

    if (_session.isHost) {
      // 房主定时广播：既是进度同步，也是服务端要求的房主心跳
      _stateTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        final p = _player;
        final m = _media;
        if (p == null || m == null) return;
        _session.broadcastPlay(PlayState(
          url: m.url,
          headers: m.headers,
          videoId: m.videoId,
          videoName: m.videoName,
          episode: m.episode,
          currentTime: p.state.position.inMilliseconds / 1000,
          isPlaying: p.state.playing,
        ));
      });
    }

    _watchTimer = Timer.periodic(const Duration(milliseconds: 600), (_) {
      _detectLocalChanges();
    });
  }

  @override
  void dispose() {
    _stateTimer?.cancel();
    _watchTimer?.cancel();
    _playSub?.cancel();
    _session.removeListener(_onSession);
    _chatCtrl.dispose();
    _chatScroll.dispose();
    final p = _player;
    _player = null;
    if (p != null) unawaited(p.dispose());
    super.dispose();
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _fg => _isDark ? Colors.white : AppTheme.textPrimary;
  Color get _sub => _isDark ? Colors.white60 : Colors.black54;
  Color get _line => _isDark
      ? Colors.white.withValues(alpha: 0.08)
      : Colors.black.withValues(alpha: 0.06);

  /// 文字/图标用的强调色（暗色下 accentColor 是墨灰，看不见）
  Color get _accent => AppTheme.accentOnSurface;

  void _onSession() {
    if (!mounted) return;
    // 只在有新消息时滚到底；否则用户往前翻聊天记录会被不断拽回来
    if (_session.messages.length != _lastMsgCount) {
      _lastMsgCount = _session.messages.length;
      _scrollChatToBottom();
    }
    setState(() {});
  }

  // ── 播放器 ───────────────────────────────────────────────────

  AppPlayer _newPlayer() {
    final engine = PlayerPrefs.instance.vodEngine.value;
    if (engine == PlayerEngine.mpv) {
      return MpvAppPlayer(config: const AppConfig(title: '房间'));
    }
    if (engine == PlayerEngine.aether && Platform.isIOS) {
      return AetherPlayer(config: const AppConfig(title: '房间'));
    }
    if (Platform.isIOS) {
      return IosAvPlayer(config: const AppConfig(title: '房间'));
    }
    return AppPlayer(config: const AppConfig(title: '房间'));
  }

  void _suppress([int ms = 1500]) {
    _suppressUntil =
        DateTime.now().add(Duration(milliseconds: ms));
  }

  void _open(PlayState s) {
    _player ??= _newPlayer();
    _suppress(2000);
    _lastPlaying = s.isPlaying;
    _lastPos = s.currentTime;
    _lastPosAt = DateTime.now();
    _player!.open(
      AppMedia(
        s.url,
        httpHeaders: s.headers.isEmpty ? null : s.headers,
        start: Duration(milliseconds: (s.currentTime * 1000).round()),
      ),
      play: s.isPlaying,
    );
  }

  /// 应用远端状态：换片 / 对齐播放态 / 纠偏
  void _applyState(PlayState s) {
    if (s.url.isEmpty) return;
    if (_media?.url != s.url) {
      setState(() => _media = s);
      _open(s);
      return;
    }
    final p = _player;
    if (p == null) {
      _open(s);
      return;
    }
    var applied = false;
    if (p.state.playing != s.isPlaying) {
      if (s.isPlaying) {
        p.play();
      } else {
        p.pause();
      }
      applied = true;
    }
    final local = p.state.position.inMilliseconds / 1000;
    if ((local - s.currentTime).abs() > 2.5) {
      p.seek(Duration(milliseconds: (s.currentTime * 1000).round()));
      applied = true;
    }
    // 对齐后刷新基准，避免下一轮轮询把"刚跟随的动作"当成本地操作再发回去。
    // ⚠️ 还需要短暂静音：慢内核/慢网络下 position/playing 的本地回调会比
    //    seek/play 晚几百毫秒，只刷新基准仍可能把**旧进度**当成"用户拖了进度"
    //    再广播回去，形成 1~2 轮来回拉锯（画面抖动）。900ms < 2s 心跳，
    //    不会挡住用户自己的操作。
    if (applied) _suppress(900);
    _lastPlaying = s.isPlaying;
    _lastPos = s.currentTime;
    _lastPosAt = DateTime.now();
  }

  void _seekTo(double seconds) {
    final p = _player;
    if (p == null) return;
    if ((p.state.position.inMilliseconds / 1000 - seconds).abs() < 0.8) return;
    p.seek(Duration(milliseconds: (seconds * 1000).round()));
    // 同 _applyState：等本地 position 追上后再恢复变化检测，避免回环
    _suppress(900);
    _lastPos = seconds;
    _lastPosAt = DateTime.now();
  }

  void _setPlaying(bool playing) {
    final p = _player;
    if (p == null || p.state.playing == playing) return;
    if (playing) {
      p.play();
    } else {
      p.pause();
    }
    _suppress(600);
    _lastPlaying = playing;
    _lastPos = p.state.position.inMilliseconds / 1000;
    _lastPosAt = DateTime.now();
  }

  /// 本地操作检测：播放态变化 → play/pause；进度突跳 → seek
  void _detectLocalChanges() {
    final p = _player;
    if (p == null || _media == null) return;
    if (DateTime.now().isBefore(_suppressUntil)) return;

    final playing = p.state.playing;
    final pos = p.state.position.inMilliseconds / 1000;
    final now = DateTime.now();
    final elapsed = now.difference(_lastPosAt).inMilliseconds / 1000;

    if (playing != _lastPlaying) {
      if (playing) {
        _session.sendPlay();
      } else {
        _session.sendPause();
      }
      _lastPlaying = playing;
      _lastPos = pos;
      _lastPosAt = now;
      return;
    }

    final expected = _lastPos + (playing ? elapsed : 0);
    if ((pos - expected).abs() > 2.5) {
      _session.sendSeek(pos);
    }
    _lastPos = pos;
    _lastPosAt = now;
  }

  void _onPlayEvent(RoomPlayEvent e) {
    if (!mounted) return;
    switch (e) {
      case RoomPlayUpdated(:final state):
        _applyState(state);
        break;
      case RoomPlayChanged(:final state):
        _applyState(state);
        break;
      case RoomPlaySought(:final seconds):
        _seekTo(seconds);
        break;
      case RoomPlayToggled(:final playing):
        _setPlaying(playing);
        break;
      case RoomPlayCleared():
        _player?.pause();
        setState(() => _media = null);
        break;
    }
  }

  Future<void> _pick() async {
    final media = await Navigator.of(context).push<RoomMedia>(MaterialPageRoute(
      settings: const RouteSettings(name: 'room:pick'),
      builder: (_) => const RoomSourcePickerPage(),
    ));
    if (media == null || !mounted) return;
    final s = PlayState(
      url: media.url,
      headers: media.headers,
      videoName: media.title,
      currentTime: 0,
      isPlaying: true,
    );
    setState(() => _media = s);
    _open(s);
    _session.changePlay(s);
  }

  // ── 聊天 ─────────────────────────────────────────────────────

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_chatScroll.hasClients) return;
      _chatScroll.jumpTo(_chatScroll.position.maxScrollExtent);
    });
  }

  void _send() {
    final text = _chatCtrl.text;
    if (text.trim().isEmpty) return;
    _chatCtrl.clear();
    _session.sendChat(text);
  }

  // ── 退出 ─────────────────────────────────────────────────────

  Future<void> _leave() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('离开房间？'),
        content: const Text('房主离开后房间保留 5 分钟，期间可以用房间号回来。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('离开')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _session.leaveRoom();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final room = _session.room;
    if (room == null) {
      // 房间已被解散 / 已离开：不要停在空页面上
      return Scaffold(
        backgroundColor: _isDark ? const Color(0xFF0B0B0C) : Colors.white,
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('房间已关闭',
                  style: TextStyle(color: _fg, fontSize: AppTheme.fontHeadline)),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('返回大厅'),
              ),
            ],
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: _isDark ? const Color(0xFF0B0B0C) : Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(room.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w600,
                    color: _fg)),
            Text(
              // 房间内不必再显示 IP：进房时已经用过一次了，
              // 这里换成「模式 · 人数 · 连接状态」更有信息量
              '${_session.mode == RoomMode.lan ? '局域网' : '房间 ${room.id}'}'
              ' · ${_session.members.length} 人'
              '${_session.connected ? '' : ' · 已断开'}',
              style: TextStyle(fontSize: AppTheme.fontCaption, color: _sub),
            ),
          ],
        ),
        actions: [
          // 聊天弹幕开关：默认开（边看边聊才是「一起看」的乐趣）
          IconButton(
            tooltip: _danmuOn ? '关闭聊天弹幕' : '开启聊天弹幕',
            icon: Icon(
              _danmuOn ? Icons.subtitles_rounded : Icons.subtitles_off_rounded,
              color: _danmuOn ? _accent : _sub,
            ),
            onPressed: () => setState(() => _danmuOn = !_danmuOn),
          ),
          if (_session.isHost)
            IconButton(
              tooltip: '选片',
              icon: Icon(Icons.video_library_outlined, color: _fg),
              onPressed: _pick,
            ),
          if (_session.isHost)
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert, color: _fg),
              onSelected: (v) {
                if (v == 'clear') {
                  _session.clearPlayback();
                  _player?.pause();
                  setState(() => _media = null);
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'clear', child: Text('停止播放（清空片源）')),
              ],
            ),
          IconButton(
            tooltip: '离开房间',
            icon: Icon(Icons.logout_rounded, color: _fg),
            onPressed: _leave,
          ),
        ],
      ),
      body: Column(
        children: [
          _playerArea(),
          _syncCard(),
          if (_session.error != null) _errorBar(),
          Expanded(child: _chatList()),
          _inputBar(),
        ],
      ),
    );
  }

  Widget _playerArea() {
    final media = _media;
    final player = _player;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(
            color: Colors.black,
            child: (media == null || player == null)
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.live_tv_rounded,
                              size: 22,
                              color: Colors.white.withValues(alpha: 0.6)),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          _session.isHost ? '点「选片」挑一集开始' : '等房主选片…',
                          style: const TextStyle(
                              color: Colors.white70,
                              fontSize: AppTheme.fontFootnote),
                        ),
                      ],
                    ),
                  )
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      VideoPlayerWidget(
                        // key 跟随播放器实例：换内核/重建时整体 remount，避免残留旧纹理
                        key: ObjectKey(player),
                        player: player,
                        url: media.url,
                        headers: media.headers.isEmpty ? null : media.headers,
                        videoTitle: media.title,
                        initialVideoFit: VideoFitType.contain,
                        onBack: _leave,
                      ),
                      // 聊天弹幕：压在画面上、不吃点击（IgnorePointer 在控件内部）
                      Positioned.fill(
                        child: LiveDanmuOverlay(
                          items: _danmuItems,
                          enabled: _danmuOn,
                          fontSize: 15,
                          speed: 105,
                          maxTracks: 5,
                          topPadding: 40,
                          bottomPadding: 56,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  /// 同步卡：播放状态 + 片名 + 成员头像，替代原来的「状态栏 + 成员横条」两段。
  Widget _syncCard() {
    final m = _media;
    final playing = _player?.state.playing ?? false;
    final members = _session.members;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: _isDark
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.black.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _line, width: 0.8),
      ),
      child: Row(
        children: [
          // 播放状态点：播放中亮、暂停时暗
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: m == null
                  ? _sub.withValues(alpha: 0.4)
                  : (playing ? _accent : _sub.withValues(alpha: 0.5)),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  m?.title ?? '还没有播放内容',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: _fg,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  m == null
                      ? (_session.isHost ? '你是房主，选片后大家一起看' : '房主选片后会同步到这')
                      : '${playing ? '同步播放中' : '已暂停'} · '
                          '${_session.isHost ? '房主可换片' : '所有人都能暂停/拖进度'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption),
                ),
              ],
            ),
          ),
          if (_session.isHost)
            GestureDetector(
              onTap: _pick,
              behavior: HitTestBehavior.opaque,
              child: Container(
                margin: const EdgeInsets.only(left: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: _accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.swap_horiz_rounded, size: 15, color: _accent),
                    const SizedBox(width: 3),
                    Text(m == null ? '选片' : '换片',
                        style: TextStyle(
                            color: _accent,
                            fontSize: AppTheme.fontCaption,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          const SizedBox(width: 8),
          _memberAvatars(members),
        ],
      ),
    );
  }

  /// 成员头像（最多 3 个 + 剩余人数）
  ///
  /// 不重叠排列：重叠式在 24px 圆上只露出 17px，昵称首字会被下一张压掉一半，
  /// 反而看不清是谁。3 个 + "+N" 宽度约 100，同步卡放得下。
  Widget _memberAvatars(List<RoomMemberInfo> members) {
    if (members.isEmpty) return const SizedBox.shrink();
    const size = 24.0;
    const step = 26.0;
    final shown = members.take(3).toList();
    final extra = members.length - shown.length;
    return SizedBox(
      height: size,
      width: shown.length * step - 2 + (extra > 0 ? step : 0),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * step,
              child: Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color:
                      _accent.withValues(alpha: shown[i].isOwner ? 0.9 : 0.22),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _isDark ? const Color(0xFF141416) : Colors.white,
                    width: 1.5,
                  ),
                ),
                child: Text(
                  _initial(shown[i].name),
                  style: TextStyle(
                    color: shown[i].isOwner
                        ? (_isDark ? const Color(0xFF141416) : Colors.white)
                        : _accent,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          if (extra > 0)
            Positioned(
              left: shown.length * step,
              child: Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _isDark
                      ? Colors.white.withValues(alpha: 0.10)
                      : Colors.black.withValues(alpha: 0.06),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: _isDark ? const Color(0xFF141416) : Colors.white,
                    width: 1.5,
                  ),
                ),
                child: Text('+$extra',
                    style: TextStyle(
                        color: _sub,
                        fontSize: 9,
                        fontWeight: FontWeight.w600)),
              ),
            ),
        ],
      ),
    );
  }

  /// 昵称首字（中文取第一个字，英文取首字母大写）
  static String _initial(String name) {
    final n = name.trim();
    if (n.isEmpty) return '?';
    return n.characters.first.toUpperCase();
  }

  Widget _errorBar() => Container(
        width: double.infinity,
        margin: const EdgeInsets.fromLTRB(14, 6, 14, 0),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.redAccent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(_session.error ?? '',
            style: TextStyle(
                color: Colors.redAccent, fontSize: AppTheme.fontCaption)),
      );

  Widget _chatList() {
    final msgs = _session.messages;
    if (msgs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.forum_outlined,
                size: 30, color: _sub.withValues(alpha: 0.5)),
            const SizedBox(height: 8),
            Text('还没有人说话',
                style: TextStyle(color: _fg, fontSize: AppTheme.fontFootnote)),
            const SizedBox(height: 3),
            Text('一起看的同时聊两句吧',
                style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption)),
          ],
        ),
      );
    }
    return ListView.builder(
      controller: _chatScroll,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
      itemCount: msgs.length,
      itemBuilder: (context, i) {
        final m = msgs[i];
        if (m.system) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: _isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : Colors.black.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(m.content,
                    style: TextStyle(
                        color: _sub,
                        fontSize: AppTheme.fontCaption,
                        height: 1.4)),
              ),
            ),
          );
        }
        // 服务端消息没带"我"的标识：用 userId 与本地 socket id 比对做不到
        //（socket.id 只有服务端知道），所以统一靠右显示自己的昵称
        final me = m.userName == _session.nickname;
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment:
                me ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              if (!me) ...[
                _chatAvatar(m.userName),
                const SizedBox(width: 7),
              ],
              Flexible(
                child: Column(
                  crossAxisAlignment:
                      me ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(left: 4, right: 4),
                      child: Text(
                        me ? '我' : m.userName,
                        style: TextStyle(
                            color: _sub, fontSize: AppTheme.fontCaption),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 11, vertical: 8),
                      decoration: BoxDecoration(
                        // 自己：主题色实心 + 白字；别人：淡底
                        color: me
                            ? _accent
                            : (_isDark
                                ? Colors.white.withValues(alpha: 0.08)
                                : Colors.black.withValues(alpha: 0.05)),
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(14),
                          topRight: const Radius.circular(14),
                          bottomLeft: Radius.circular(me ? 14 : 4),
                          bottomRight: Radius.circular(me ? 4 : 14),
                        ),
                      ),
                      child: Text(
                        m.content,
                        style: TextStyle(
                          color: me
                              ? (_isDark
                                  ? const Color(0xFF141416)
                                  : Colors.white)
                              : _fg,
                          fontSize: AppTheme.fontSubhead,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 聊天里的圆形头像（昵称首字）
  Widget _chatAvatar(String name) => Container(
        width: 28,
        height: 28,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _accent.withValues(alpha: 0.16),
          shape: BoxShape.circle,
        ),
        child: Text(_initial(name),
            style: TextStyle(
                color: _accent,
                fontSize: 11,
                fontWeight: FontWeight.w700)),
      );

  Widget _inputBar() => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: _chatCtrl,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  // 让发送按钮的可用态跟着输入内容变
                  onChanged: (_) => setState(() {}),
                  minLines: 1,
                  maxLines: 4,
                  style: TextStyle(color: _fg, fontSize: AppTheme.fontSubhead),
                  decoration: InputDecoration(
                    hintText: _session.connected ? '说点什么…' : '连接已断开',
                    hintStyle:
                        TextStyle(color: _sub, fontSize: AppTheme.fontSubhead),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 11),
                    filled: true,
                    fillColor: _isDark
                        ? Colors.white.withValues(alpha: 0.07)
                        : Colors.black.withValues(alpha: 0.04),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(20),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _chatCtrl.text.trim().isEmpty ? null : _send,
                child: Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _chatCtrl.text.trim().isEmpty
                        ? _accent.withValues(alpha: 0.35)
                        : _accent,
                    borderRadius: BorderRadius.circular(19),
                  ),
                  child: Icon(
                    Icons.send_rounded,
                    size: 17,
                    color: _isDark ? const Color(0xFF141416) : Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}
