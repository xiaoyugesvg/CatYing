import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:tvbox/models/player_engine.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/widgets/app_player.dart';
import 'package:tvbox/widgets/ios_av_player.dart';
import 'package:tvbox/widgets/aether_player.dart';
import 'package:tvbox/widgets/mpv_app_player.dart';
import 'package:tvbox/widgets/video_player.dart';

/// REX 模块的播放页：直接用模块 `loadResource` 返回的地址与请求头。
class RexPlayerPage extends StatefulWidget {
  const RexPlayerPage({
    super.key,
    required this.title,
    required this.url,
    this.headers = const {},
  });

  final String title;
  final String url;
  final Map<String, String> headers;

  @override
  State<RexPlayerPage> createState() => _RexPlayerPageState();
}

class _RexPlayerPageState extends State<RexPlayerPage> {
  AppPlayer? _player;

  @override
  void initState() {
    super.initState();
    final p = _newPlayer();
    _player = p;
    p.open(AppMedia(
      widget.url,
      httpHeaders: widget.headers.isEmpty ? null : widget.headers,
    ));
  }

  @override
  void dispose() {
    final p = _player;
    _player = null;
    if (p != null) unawaited(p.dispose());
    super.dispose();
  }

  AppPlayer _newPlayer() {
    final engine = PlayerPrefs.instance.vodEngine.value;
    if (engine == PlayerEngine.mpv) {
      return MpvAppPlayer(config: const AppConfig(title: 'REX'));
    }
    if (engine == PlayerEngine.aether && Platform.isIOS) {
      return AetherPlayer(config: const AppConfig(title: 'REX'));
    }
    if (Platform.isIOS) {
      return IosAvPlayer(config: const AppConfig(title: 'REX'));
    }
    return AppPlayer(config: const AppConfig(title: 'REX'));
  }

  @override
  Widget build(BuildContext context) {
    final p = _player;
    return Scaffold(
      backgroundColor: Colors.black,
      body: p == null
          ? const Center(
              child: CircularProgressIndicator(color: Colors.white70))
          : VideoPlayerWidget(
              key: ObjectKey(p),
              player: p,
              url: widget.url,
              headers: widget.headers.isEmpty ? null : widget.headers,
              videoTitle: widget.title,
              initialVideoFit: VideoFitType.contain,
              onBack: () => Navigator.of(context).pop(),
            ),
    );
  }
}
