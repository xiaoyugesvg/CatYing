import 'package:flutter/material.dart';

import '../../widgets/video_player.dart';
import 'emby_api.dart';
import 'emby_models.dart';

/// Emby 播放页：复用全局播放器（含弹幕 / 内核切换 / 手势）。
///
/// 默认走 `static=true` 直连原片（不转码、秒开、画质无损）。
/// 若首个内核报错（常见于 HEVC / AC3 等编码不被支持），自动回退一次
/// 服务端转码线路（H.264 + AAC），避免直接黑屏。
class EmbyPlayerPage extends StatefulWidget {
  const EmbyPlayerPage({
    super.key,
    required this.server,
    required this.item,
    required this.title,
  });

  final EmbyServer server;
  final EmbyItem item;
  final String title;

  @override
  State<EmbyPlayerPage> createState() => _EmbyPlayerPageState();
}

class _EmbyPlayerPageState extends State<EmbyPlayerPage> {
  bool _transcode = false;

  @override
  Widget build(BuildContext context) {
    final api = EmbyApi(widget.server);
    final url = api.streamUrl(widget.item.id, static: !_transcode);
    return Scaffold(
      backgroundColor: Colors.black,
      body: VideoPlayerWidget(
        key: ValueKey(
          'emby_${widget.item.id}_${_transcode ? 'transcode' : 'static'}',
        ),
        url: url,
        videoTitle: widget.title,
        headers: api.imageHeaders,
        onBack: () => Navigator.of(context).maybePop(),
        onError: () {
          // 只回退一次：转码线路再失败就交给播放器自己的错误提示
          if (_transcode || !mounted) return;
          setState(() => _transcode = true);
        },
      ),
    );
  }
}
