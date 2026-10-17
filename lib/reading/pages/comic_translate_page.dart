import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../../reading/source/global_proxy.dart';
import '../../services/app_log.dart';
import '../../services/ocr_service.dart';
import '../../services/translate_service.dart';

/// 漫画「翻译本页」—— 独立的全屏翻译阅读页。
///
/// ── 为什么单独一页（而不是直接叠在原阅读器上）──────────────────
/// 原阅读器有翻页 / 双页 / 拼页 / 溶解 / 缩放五套渲染路径，把译文层塞进
/// 每一套都要各自算一遍"图片实际显示矩形"，改动面大且容易错位。
/// 这里用一个**只做"图片 + 译文覆盖"**的简单 PageView：
///   · 与原阅读器共用同一份图片地址（data: / file:// / http）与请求头；
///   · 每页懒加载：划到哪页翻哪页，翻过的页缓存住不重复请求；
///   · 坐标直接来自 Vision 的归一化 rect，按 contain 后的显示矩形映射。
class ComicTranslatePage extends StatefulWidget {
  const ComicTranslatePage({
    super.key,
    required this.images,
    required this.initialIndex,
    this.headers = const {},
    this.useLocal = false,
    this.title = '翻译',
  });

  final List<String> images;
  final int initialIndex;
  final Map<String, String> headers;
  final bool useLocal;
  final String title;

  @override
  State<ComicTranslatePage> createState() => _ComicTranslatePageState();
}

class _ComicTranslatePageState extends State<ComicTranslatePage> {
  late final PageController _controller;
  late int _index;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex.clamp(0, math.max(0, widget.images.length - 1));
    _controller = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.paddingOf(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          SizedBox(height: pad.top),
          _topBar(),
          Expanded(
            child: widget.images.isEmpty
                ? const Center(
                    child: Text('没有可翻译的图片',
                        style: TextStyle(color: Colors.white70)))
                : PageView.builder(
                    controller: _controller,
                    itemCount: widget.images.length,
                    onPageChanged: (i) => setState(() => _index = i),
                    itemBuilder: (_, i) => _TranslatedImage(
                      key: ValueKey(widget.images[i]),
                      url: widget.images[i],
                      headers: widget.headers,
                      useLocal: widget.useLocal,
                      active: i == _index,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _topBar() {
    return Container(
      height: 46,
      color: Colors.black,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          IconButton(
            tooltip: '返回',
            icon: const Icon(Icons.arrow_back_ios_new_rounded,
                size: 18, color: Colors.white),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Text(
              '${widget.title} · ${_index + 1}/${widget.images.length}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w600),
            ),
          ),
          const Text('译文由 AI 生成',
              style: TextStyle(color: Colors.white38, fontSize: 11)),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

/// 单页：加载图片 → OCR → 翻译 → 覆盖
class _TranslatedImage extends StatefulWidget {
  const _TranslatedImage({
    super.key,
    required this.url,
    required this.headers,
    required this.useLocal,
    required this.active,
  });

  final String url;
  final Map<String, String> headers;
  final bool useLocal;
  final bool active;

  @override
  State<_TranslatedImage> createState() => _TranslatedImageState();
}

class _TranslatedImageState extends State<_TranslatedImage> {
  /// 已完成的页翻译缓存（同一张图重开直接命中）
  ///
  /// ⚠️ 有上限：每条都持有整页图片字节（大图 2~5MB），无限缓存会吃掉上百 MB。
  /// 只留最近 6 页——翻回去时重新解码一次即可（网络图还有磁盘缓存兜底）。
  static final Map<String, _PageResult> _cache = {};

  static void _remember(String url, _PageResult r) {
    if (_cache.length >= 6) _cache.remove(_cache.keys.first);
    _cache[url] = r;
  }

  static final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 20),
    receiveTimeout: const Duration(seconds: 30),
    responseType: ResponseType.bytes,
  ));

  Uint8List? _bytes;
  double _imgW = 0;
  double _imgH = 0;
  _PageResult? _result;
  String _status = '';
  bool _started = false;

  @override
  void initState() {
    super.initState();
    final hit = _cache[widget.url];
    if (hit != null) {
      _result = hit;
      _bytes = hit.bytes;
      _imgW = hit.imgW;
      _imgH = hit.imgH;
    } else if (widget.active) {
      _run();
    }
  }

  @override
  void didUpdateWidget(covariant _TranslatedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 划到本页才开始处理，避免 PageView 预建相邻页时白烧一次 OCR/翻译
    if (widget.active && !oldWidget.active && _result == null) {
      _run();
    }
  }

  Future<void> _run({bool force = false}) async {
    if (_started && !force) return;
    _started = true;
    if (force) _cache.remove(widget.url);
    setState(() {
      _status = '正在识别文字…';
      _result = null;
    });
    try {
      final bytes = _bytes ?? await _loadBytes();
      final dim = await _decodeSize(bytes);
      if (!mounted) return;
      setState(() {
        _bytes = bytes;
        _imgW = dim.$1;
        _imgH = dim.$2;
      });

      final src = await _sourceLang();
      var blocks = await OcrService.recognize(
        bytes,
        languages: OcrService.visionLanguages(src),
      );
      if (!mounted) return;
      if (blocks.isEmpty) {
        final r = _PageResult(
            bytes: bytes, imgW: dim.$1, imgH: dim.$2, blocks: const [], lines: const []);
        _remember(widget.url, r);
        setState(() {
          _result = r;
          _status = '这一页没识别出文字';
        });
        return;
      }
      blocks = OcrService.sortReadingOrder(blocks);
      setState(() => _status = '正在翻译（${blocks.length} 段）…');

      List<String> lines;
      try {
        lines = await TranslateService.instance
            .translateLines(blocks.map((b) => b.text).toList());
      } catch (e) {
        lines = const [];
        _status = '翻译失败：${_short(e)}';
      }
      final r = _PageResult(
        bytes: bytes,
        imgW: dim.$1,
        imgH: dim.$2,
        blocks: blocks,
        lines: lines,
      );
      _remember(widget.url, r);
      if (!mounted) return;
      setState(() {
        _result = r;
        _status = lines.isEmpty ? (_status.isEmpty ? '没有译文' : _status) : '';
      });
    } catch (e) {
      AppLog.instance.log('[ComicTranslate] 失败: $e');
      if (mounted) setState(() => _status = '处理失败：${_short(e)}');
    }
  }

  static Future<String> _sourceLang() async {
    final s = await TranslateSettings.from();
    return s;
  }

  Future<Uint8List> _loadBytes() async {
    final u = widget.url;
    if (u.startsWith('data:')) {
      final i = u.indexOf(',');
      return base64.decode(i > 0 ? u.substring(i + 1) : '');
    }
    if (u.startsWith('file://') || !u.contains('://')) {
      final p = u.startsWith('file://') ? Uri.parse(u).toFilePath() : u;
      return File(p).readAsBytes();
    }
    applyGlobalProxy(_dio);
    final r = await _dio.get<List<int>>(u,
        options: Options(headers: widget.headers));
    return Uint8List.fromList(r.data ?? const []);
  }

  static Future<(double, double)> _decodeSize(Uint8List bytes) async {
    final img = await decodeImageFromList(bytes);
    final w = img.width.toDouble();
    final h = img.height.toDouble();
    img.dispose();
    return (w, h);
  }

  static String _short(Object e) {
    final s = e.toString().replaceAll('\n', ' ');
    return s.length > 50 ? s.substring(0, 50) : s;
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes == null) {
      return _placeholder();
    }
    return LayoutBuilder(builder: (context, c) {
      // BoxFit.contain：算图片实际显示矩形，译文按同一比例映射
      final scale = math.min(c.maxWidth / _imgW, c.maxHeight / _imgH);
      final dw = _imgW * scale;
      final dh = _imgH * scale;
      final dx = (c.maxWidth - dw) / 2;
      final dy = (c.maxHeight - dh) / 2;

      return Stack(
        children: [
          Positioned(
            left: dx,
            top: dy,
            width: dw,
            height: dh,
            child: Image.memory(bytes, fit: BoxFit.fill, gaplessPlayback: true),
          ),
          if (_result != null && _result!.lines.isNotEmpty)
            for (var i = 0; i < _result!.blocks.length; i++)
              if (i < _result!.lines.length && _result!.lines[i].trim().isNotEmpty)
                _overlayBox(
                  _result!.blocks[i],
                  _result!.lines[i],
                  dx,
                  dy,
                  dw,
                  dh,
                ),
          if (_status.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: 8,
              child: Center(child: _statusChip(_status)),
            ),
          if (widget.active && _result != null)
            Positioned(
              right: 10,
              bottom: 8,
              child: _smallButton('重译', () => _run(force: true)),
            ),
        ],
      );
    });
  }

  Widget _overlayBox(OcrBlock b, String text, double dx, double dy, double dw,
      double dh) {
    final left = dx + b.x * dw;
    final top = dy + b.y * dh;
    final width = math.max(28.0, b.w * dw);
    final size = (b.h * dh * 0.62).clamp(11.0, 18.0);
    return Positioned(
      left: left,
      top: top,
      width: width,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: Colors.white24, width: 0.6),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: Colors.white,
            fontSize: size,
            height: 1.25,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _placeholder() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white54),
          ),
          const SizedBox(height: 10),
          Text(_status.isEmpty ? '加载图片…' : _status,
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _statusChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24, width: 0.6),
      ),
      child: Text(text,
          style: const TextStyle(color: Colors.white70, fontSize: 11)),
    );
  }

  Widget _smallButton(String text, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: AppTheme.accentOnSurface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text,
            style: const TextStyle(color: Colors.white, fontSize: 11)),
      ),
    );
  }
}

class _PageResult {
  const _PageResult({
    required this.bytes,
    required this.imgW,
    required this.imgH,
    required this.blocks,
    required this.lines,
  });

  final Uint8List bytes;
  final double imgW;
  final double imgH;
  final List<OcrBlock> blocks;
  final List<String> lines;
}
