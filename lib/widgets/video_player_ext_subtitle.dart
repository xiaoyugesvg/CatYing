part of 'video_player.dart';

/// 外挂字幕译文（方案 A）的 UI 与动作。
///
/// 为什么自己画而不是交给内核：
///   · MPV 能用 `sub-add`，但 AVPlayer / KSPlayer 加不了外部文件
///   · 三种内核表现不一致 ⇒ 用户换个内核"字幕就没了"
/// 自己按 `_positionVN` 叠中文，三条内核走同一份代码，样式也统一。
extension _ExtSubtitleUi on _VideoPlayerWidgetState {
  /// 当前进度对应的译文（二分查找；字幕行按时间升序）
  String? _extCueAt(Duration pos) {
    final cues = _extCues;
    if (cues.isEmpty) return null;
    var lo = 0;
    var hi = cues.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final c = cues[mid];
      if (pos < c.start) {
        hi = mid - 1;
      } else if (pos >= c.end) {
        lo = mid + 1;
      } else {
        final t = c.text.trim();
        return t.isEmpty ? null : t;
      }
    }
    return null;
  }

  /// 译文层：白字 + 双层阴影（不铺底色，画面更干净）
  Widget _buildExtSubtitleLayer() {
    final withBar = _showControls && !_isLocked;
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      left: 18,
      right: 18,
      // 控件开着时抬到进度条上方，收起时贴底部
      bottom: withBar ? 92 : 28,
      child: IgnorePointer(
        child: ValueListenableBuilder<Duration>(
          valueListenable: _positionVN,
          builder: (context, pos, _) {
            final text = _extCueAt(pos);
            if (text == null) return const SizedBox.shrink();
            return Align(
              alignment: Alignment.bottomCenter,
              child: Text(
                text,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  height: 1.35,
                  fontWeight: FontWeight.w600,
                  shadows: [
                    Shadow(blurRadius: 6, color: Colors.black87),
                    Shadow(blurRadius: 2, color: Colors.black),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  void _toggleExtSubtitle() {
    if (_extCues.isEmpty) {
      AppToast.message('还没有载入译文');
      return;
    }
    _extSetState(() => _extOn = !_extOn);
    AppToast.message(_extOn ? '译文已显示' : '译文已关闭');
  }

  /// 选一个字幕文件 → 翻译（或复用同目录的 `xxx.zh.srt`）→ 叠在画面上
  Future<void> _pickExtSubtitle() async {
    PlatformFile? picked;
    try {
      picked = await FilePicker.pickFile(
        dialogTitle: '选择字幕文件（.srt / .ass）',
        type: FileType.custom,
        allowedExtensions: const ['srt', 'ass', 'ssa'],
      );
    } catch (e) {
      AppToast.message('打开文件选择器失败：$e');
      return;
    }
    final path = picked?.path;
    if (path == null || path.isEmpty) return;

    // 已经译过（同名 .zh.srt 且不比源文件旧）→ 直接加载，不再打网络
    final outPath = SubtitleTranslator.outputPathFor(path);
    try {
      final out = File(outPath);
      if (await out.exists()) {
        final outAt = (await out.stat()).modified;
        final srcAt = (await File(path).stat()).modified;
        if (!outAt.isBefore(srcAt)) {
          await _loadExtCuesFile(outPath, '中文译文');
          return;
        }
      }
    } catch (_) {
      // 读不到时间戳就当没有缓存，继续走翻译
    }

    await _translateExtSubtitle(path);
  }

  Future<void> _loadExtCuesFile(String path, String label) async {
    try {
      final cues = await SubtitleTranslator.loadCues(path);
      if (!mounted) return;
      if (cues.isEmpty) {
        AppToast.message('这个字幕文件没解析出内容');
        return;
      }
      _extSetState(() {
        _extCues = cues;
        _extOn = true;
      });
      AppToast.message('$label 已显示（${cues.length} 条）');
    } catch (e) {
      if (mounted) AppToast.message('加载字幕失败：$e');
    }
  }

  /// 带进度弹窗的翻译（可取消；取消不写文件）
  Future<void> _translateExtSubtitle(String path) async {
    final done = ValueNotifier<int>(0);
    var total = 0;
    var cancelled = false;
    final nav = Navigator.of(context, rootNavigator: true);
    var closed = false;
    void closeDialog() {
      if (closed) return;
      closed = true;
      try {
        if (nav.canPop()) nav.pop();
      } catch (_) {
        // 页面已被关掉，导航器不可用 —— 忽略
      }
    }

    unawaited(showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        title: const Text(
          '翻译字幕',
          style: TextStyle(color: Colors.white, fontSize: 16),
        ),
        content: ValueListenableBuilder<int>(
          valueListenable: done,
          builder: (_, d, __) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: total <= 0 ? null : (d / total).clamp(0.0, 1.0),
                  minHeight: 6,
                  backgroundColor: Colors.white12,
                  color: AppTheme.accentColor,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                total <= 0 ? '正在解析字幕…' : '已翻译 $d / $total 行',
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => cancelled = true,
            child: const Text('取消'),
          ),
        ],
      ),
    ));

    try {
      final r = await SubtitleTranslator.translateFile(
        path,
        onProgress: (d, t) {
          done.value = d;
          total = t;
        },
        isCancelled: () => cancelled,
      );
      closeDialog();
      if (!mounted) return;
      _extSetState(() {
        _extCues = r.cues;
        _extOn = true;
      });
      AppToast.message(r.translated == 0
          ? '字幕里没有需要翻译的行（可能已是中文）'
          : '译文已显示（${r.translated}/${r.total} 行）');
    } catch (e) {
      closeDialog();
      if (mounted) AppToast.message('翻译失败：$e');
    }
  }
}
