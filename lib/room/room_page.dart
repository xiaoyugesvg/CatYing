import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../common/theme.dart';
import '../models/player_engine.dart';
import '../services/player_prefs.dart';
import '../widgets/app_player.dart';
import '../widgets/ios_av_player.dart';
import '../widgets/ks_player.dart';
import '../widgets/mpv_app_player.dart';
import '../widgets/video_player.dart';
import 'room_models.dart';
import 'room_session.dart';
import 'room_source_picker.dart';

/// 「一起看」房间页：播放器 + 成员 + 聊天。
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
      return MpvAppPlayer(config: const AppConfig(title: '一起看'));
    }
    if (engine == PlayerEngine.ksplayer && Platform.isIOS) {
      return KSPlayer(config: const AppConfig(title: '一起看'));
    }
    if (Platform.isIOS) {
      return IosAvPlayer(config: const AppConfig(title: '一起看'));
    }
    return AppPlayer(config: const AppConfig(title: '一起看'));
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
    if (p.state.playing != s.isPlaying) {
      if (s.isPlaying) {
        p.play();
      } else {
        p.pause();
      }
    }
    final local = p.state.position.inMilliseconds / 1000;
    if ((local - s.currentTime).abs() > 2.5) {
      p.seek(Duration(milliseconds: (s.currentTime * 1000).round()));
    }
    // 对齐后刷新基准，避免下一轮轮询把"刚跟随的动作"当成本地操作再发回去
    _lastPlaying = s.isPlaying;
    _lastPos = s.currentTime;
    _lastPosAt = DateTime.now();
  }

  void _seekTo(double seconds) {
    final p = _player;
    if (p == null) return;
    if ((p.state.position.inMilliseconds / 1000 - seconds).abs() < 0.8) return;
    p.seek(Duration(milliseconds: (seconds * 1000).round()));
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
              _session.mode == RoomMode.lan
                  ? '局域网 ${_session.lanAddress} · ${_session.members.length} 人'
                      '${_session.connected ? '' : ' · 连接已断开'}'
                  : '房间号 ${room.id} · ${_session.members.length} 人'
                      '${_session.connected ? '' : ' · 连接已断开'}',
              style: TextStyle(fontSize: AppTheme.fontCaption, color: _sub),
            ),
          ],
        ),
        actions: [
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
          _statusBar(),
          _membersBar(),
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
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        color: Colors.black,
        child: (media == null || player == null)
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.live_tv_outlined,
                        size: 30, color: Colors.white.withValues(alpha: 0.5)),
                    const SizedBox(height: 8),
                    Text(
                      _session.isHost ? '点右上角「选片」挑一集开始' : '等房主选片…',
                      style: const TextStyle(
                          color: Colors.white54,
                          fontSize: AppTheme.fontFootnote),
                    ),
                  ],
                ),
              )
            : VideoPlayerWidget(
                // key 跟随播放器实例：换内核/重建时整体 remount，避免残留旧纹理
                key: ObjectKey(player),
                player: player,
                url: media.url,
                headers: media.headers.isEmpty ? null : media.headers,
                videoTitle: media.title,
                initialVideoFit: VideoFitType.contain,
                onBack: _leave,
              ),
      ),
    );
  }

  Widget _statusBar() {
    final m = _media;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
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
                  _session.isHost
                      ? '你选片；播放/暂停/进度大家都能控'
                      : '跟随房间同步；你也可以暂停或拖进度',
                  style: TextStyle(color: _sub, fontSize: AppTheme.fontCaption),
                ),
              ],
            ),
          ),
          if (_session.isHost)
            TextButton.icon(
              onPressed: _pick,
              icon: const Icon(Icons.swap_horiz_rounded, size: 16),
              label: Text(m == null ? '选片' : '换片',
                  style: TextStyle(fontSize: AppTheme.fontFootnote)),
            ),
        ],
      ),
    );
  }

  Widget _membersBar() {
    final members = _session.members;
    if (members.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: members.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (context, i) {
          final mb = members[i];
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.accentColor
                  .withValues(alpha: mb.isOwner ? 0.18 : 0.08),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              children: [
                Icon(
                  mb.isOwner ? Icons.star_rounded : Icons.person_rounded,
                  size: 12,
                  color: AppTheme.accentColor,
                ),
                const SizedBox(width: 4),
                Text(
                  mb.name,
                  style: TextStyle(
                      color: AppTheme.accentColor,
                      fontSize: AppTheme.fontCaption,
                      fontWeight: mb.isOwner ? FontWeight.w600 : FontWeight.w400),
                ),
              ],
            ),
          );
        },
      ),
    );
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
        child: Text('还没有人说话，打个招呼吧',
            style: TextStyle(color: _sub, fontSize: AppTheme.fontFootnote)),
      );
    }
    return ListView.builder(
      controller: _chatScroll,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      itemCount: msgs.length,
      itemBuilder: (context, i) {
        final m = msgs[i];
        if (m.system) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Center(
              child: Text(m.content,
                  style: TextStyle(
                      color: _sub.withValues(alpha: 0.8),
                      fontSize: AppTheme.fontCaption)),
            ),
          );
        }
        // 服务端消息没带"我"的标识：用 userId 与本地 socket id 比对做不到
        //（socket.id 只有服务端知道），所以统一靠右显示自己的昵称
        final me = m.userName == _session.nickname;
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment:
                me ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              Flexible(
                child: Column(
                  crossAxisAlignment:
                      me ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                  children: [
                    Text(m.userName,
                        style: TextStyle(
                            color: _sub, fontSize: AppTheme.fontCaption)),
                    const SizedBox(height: 2),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 7),
                      decoration: BoxDecoration(
                        color: me
                            ? AppTheme.accentColor.withValues(alpha: 0.16)
                            : (_isDark
                                ? Colors.white.withValues(alpha: 0.08)
                                : Colors.black.withValues(alpha: 0.05)),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(m.content,
                          style: TextStyle(
                              color: _fg,
                              fontSize: AppTheme.fontSubhead,
                              height: 1.35)),
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

  Widget _inputBar() => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatCtrl,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  style: TextStyle(color: _fg, fontSize: AppTheme.fontSubhead),
                  decoration: InputDecoration(
                    hintText: _session.connected ? '说点什么…' : '连接已断开',
                    hintStyle:
                        TextStyle(color: _sub, fontSize: AppTheme.fontSubhead),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 11),
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
                onTap: _send,
                child: Container(
                  width: 38,
                  height: 38,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: AppTheme.accentColor,
                    borderRadius: BorderRadius.circular(19),
                  ),
                  child: const Icon(Icons.send_rounded,
                      size: 18, color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      );
}
