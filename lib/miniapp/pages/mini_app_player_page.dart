import 'package:flutter/material.dart';

import '../../widgets/video_player.dart';

/// URL 直播放页（ant.player.open 用）。
///
/// 复用项目播放器内核（media_kit/libmpv + 弹幕 + PiP），
/// 黑底全屏，进页即播。带取流请求头（source.play 返回的 header 原样透传）。
class MiniAppPlayerPage extends StatefulWidget {
  final String url;
  final String title;
  final Map<String, String>? headers;

  const MiniAppPlayerPage({
    super.key,
    required this.url,
    this.title = '',
    this.headers,
  });

  @override
  State<MiniAppPlayerPage> createState() => _MiniAppPlayerPageState();
}

class _MiniAppPlayerPageState extends State<MiniAppPlayerPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // 不再自画返回按钮：播放器自带返回键（用户 2026-10-14），
      // 两个返回叠在一起既重复又挡画面。
      body: VideoPlayerWidget(
        key: ValueKey('ant_player_${widget.url}'),
        url: widget.url,
        videoTitle: widget.title.isEmpty ? '播放' : widget.title,
        headers: widget.headers,
        // 顶栏返回键由播放器自带、且**无条件显示**；不传 onBack 时点了
        // 什么都不会发生（只能靠系统手势退出）—— 2026-10-15 修复。
        // 从嗅探页进来时回到嗅探页，从小程序进来时回到小程序页。
        onBack: () => Navigator.of(context).maybePop(),
      ),
    );
  }
}
