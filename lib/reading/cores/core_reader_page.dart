// lib/reading/cores/core_reader_page.dart
//
// 「阅读核心」的**独立阅读页**（方案 A，用户 2026-10-14 明确）。
//
// ── 定位 ─────────────────────────────────────────────────────
//   自成一块：入参只有"图片 URL 列表"或"正文文本"，**不依赖**漫画模块的
//   阅读器、不依赖书源引擎，也不引用影视/音乐的任何东西。
//   入口由影视详情页那个「阅读」按钮负责把内容取好再 push 进来。
//
// ── 为什么不做源浏览 / 搜索 / 详情 ─────────────────────────────
//   用户原话：影视模块本来就有详情页和播放列表，点列表里的「阅读」直接看就行，
//   不需要再在阅读侧重复一套浏览 UI。

import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:photo_view/photo_view_gallery.dart';

import '../services/tts_service.dart';

class CoreReaderPage extends StatefulWidget {
  const CoreReaderPage({
    super.key,
    required this.title,
    this.images,
    this.text,
  });

  final String title;

  /// 图片模式（漫画 / 图集）
  final List<String>? images;

  /// 正文模式（小说 / 图文正文）
  final String? text;

  @override
  State<CoreReaderPage> createState() => _CoreReaderPageState();
}

class _CoreReaderPageState extends State<CoreReaderPage> {
  final _pageCtrl = PageController();
  int _index = 0;
  double _fontSize = 17;

  /// 是否正在朗读（只用来切换图标，不做播放控制）
  bool _speaking = false;

  /// 朗读本页正文 —— 走 App 既有的 [TtsService]（系统 AVSpeechSynthesizer，
  /// **不引 flutter_tts**：本项目 TrollStore 侧载不能新增原生插件，会 SIGABRT）。
  /// 朗读中再点一次 = 从头重读（没接"停止"：TtsService 的停止 API 待确认，
  /// 不猜就不会调错）。
  Future<void> _speak() async {
    final t = _text.trim();
    if (t.isEmpty) return;
    if (mounted) setState(() => _speaking = true);
    try {
      await TtsService.instance.speak(t);
    } catch (_) {
      /* 朗读失败不影响阅读 */
    }
    if (mounted) setState(() => _speaking = false);
  }

  List<String> get _images => widget.images ?? const [];
  String get _text => widget.text ?? '';
  bool get _isImageMode => _images.isNotEmpty;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final total = _images.length;
    return Scaffold(
      backgroundColor: _isImageMode ? Colors.black : null,
      appBar: AppBar(
        backgroundColor: _isImageMode ? Colors.black : null,
        foregroundColor: _isImageMode ? Colors.white : null,
        title: Text(
          total > 1 ? '${widget.title}  ${_index + 1}/$total' : widget.title,
          style: const TextStyle(fontSize: 16),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: _isImageMode
            ? null
            : [
                IconButton(
                  tooltip: '朗读本页',
                  icon: Icon(_speaking
                      ? Icons.volume_up_rounded
                      : Icons.record_voice_over_rounded),
                  onPressed: _speak,
                ),
                IconButton(
                  tooltip: '缩小字号',
                  icon: const Icon(Icons.text_decrease_rounded),
                  onPressed: () => setState(
                      () => _fontSize = (_fontSize - 1).clamp(12, 30)),
                ),
                IconButton(
                  tooltip: '放大字号',
                  icon: const Icon(Icons.text_increase_rounded),
                  onPressed: () => setState(
                      () => _fontSize = (_fontSize + 1).clamp(12, 30)),
                ),
              ],
      ),
      body: _isImageMode ? _buildImages() : _buildText(),
    );
  }

  Widget _buildImages() {
    final total = _images.length;
    return Stack(
      children: [
        PhotoViewGallery.builder(
          pageController: _pageCtrl,
          itemCount: total,
          onPageChanged: (i) => setState(() => _index = i),
          builder: (_, i) => PhotoViewGalleryPageOptions(
            imageProvider: CachedNetworkImageProvider(_images[i]),
            minScale: PhotoViewComputedScale.contained,
            maxScale: PhotoViewComputedScale.covered * 3,
          ),
          loadingBuilder: (_, e) => Center(
            child: e == null
                ? const CircularProgressIndicator()
                : const Icon(Icons.broken_image_rounded,
                    color: Colors.white54, size: 40),
          ),
          backgroundDecoration: const BoxDecoration(color: Colors.black),
        ),
        // 底部进度条：多图时给个"看到哪了"的直觉
        if (total > 1)
          Positioned(
            left: 0,
            right: 0,
            bottom: 10,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${_index + 1} / $total',
                  style: const TextStyle(color: Colors.white, fontSize: 12),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildText() {
    if (_text.trim().isEmpty) {
      return const Center(child: Text('（没有取到正文）'));
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 12, 18, 40),
      child: SelectableText(
        _text,
        style: TextStyle(fontSize: _fontSize, height: 1.8),
      ),
    );
  }
}
