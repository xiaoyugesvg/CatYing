part of 'video_player.dart';

class _ProgressBarGesture extends StatelessWidget {
  final double progress;
  final void Function(double ratio) onSeekToRatio;
  final void Function(double ratio) onDrag;
  final VoidCallback onDragEnd;

  const _ProgressBarGesture({
    required this.progress,
    required this.onSeekToRatio,
    required this.onDrag,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            final ratio = (details.localPosition.dx / w).clamp(0.0, 1.0);
            onDrag(ratio);
            onSeekToRatio(ratio);
          },
          onHorizontalDragStart: (details) {
            final ratio = (details.localPosition.dx / w).clamp(0.0, 1.0);
            onDrag(ratio);
          },
          onHorizontalDragUpdate: (details) {
            final ratio = (details.localPosition.dx / w).clamp(0.0, 1.0);
            onDrag(ratio);
          },
          onHorizontalDragEnd: (_) => onDragEnd(),
          child: CustomPaint(
            size: Size(w, 20),
            painter: _ProgressBarPainter(progress: progress),
          ),
        );
      },
    );
  }
}

class _ProgressBarPainter extends CustomPainter {
  final double progress;
  _ProgressBarPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    const trackHeight = 3.5;
    const thumbRadius = 7.0;

    final trackRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, centerY - trackHeight / 2, size.width, trackHeight),
      Radius.circular(trackHeight / 2),
    );
    canvas.drawRRect(
      trackRect,
      Paint()..color = Colors.white.withValues(alpha: 0.2),
    );

    if (progress > 0) {
      final progressRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(
          0,
          centerY - trackHeight / 2,
          size.width * progress,
          trackHeight,
        ),
        Radius.circular(trackHeight / 2),
      );
      canvas.drawRRect(progressRect, Paint()..color = Colors.white);
    }

    final thumbX = (size.width * progress).clamp(
      thumbRadius,
      size.width - thumbRadius,
    );
    canvas.drawCircle(
      Offset(thumbX, centerY),
      thumbRadius,
      Paint()..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(_ProgressBarPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

// ============================================================
// 通用 UI 组件
// ============================================================

class _IndicatorBadge extends StatelessWidget {
  final IconData icon;
  final String text;
  const _IndicatorBadge({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(40),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 28),
          const SizedBox(height: 6),
          Text(
            text,
            style: const TextStyle(
              color: Colors.white,
              fontSize: AppTheme.fontSubhead,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}

class _GestureHintBubble extends StatelessWidget {
  final String text;
  const _GestureHintBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: AppTheme.fontSubhead,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

/// 跨 widget rebuild 持久化的 player 状态（静态缓存的值对象）
class _PersistedPlayerState {
  bool isNativeFullscreen = false;
  bool isImmersive = false;
  /// 续播是否已应用：跨 widget Element 重建持久化。
  bool resumeApplied = false;
  /// 「进入即短剧竖屏」是否已执行过 —— 防止换集重建时反复锁屏/切方向
  bool dramaApplied = false;
}

class _SettingsRowLabel extends StatelessWidget {
  final String text;
  const _SettingsRowLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: Colors.white,
        fontSize: AppTheme.fontSubhead,
        fontWeight: FontWeight.w500,
      ),
    );
  }
}

/// 跳过片头/片尾时间编辑器
class _SkipSecondsEditor extends StatefulWidget {
  final int value;
  final ValueChanged<int> onChange;
  final List<int> presets;
  final int maxSeconds;

  const _SkipSecondsEditor({
    required this.value,
    required this.onChange,
    required this.presets,
    required this.maxSeconds,
  });

  @override
  State<_SkipSecondsEditor> createState() => _SkipSecondsEditorState();
}

class _SkipSecondsEditorState extends State<_SkipSecondsEditor> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
    _focusNode = FocusNode();
    _focusNode.addListener(() {
      if (!_focusNode.hasFocus) {
        _submit();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _SkipSecondsEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value && !_focusNode.hasFocus) {
      _controller.text = widget.value.toString();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      _controller.text = widget.value.toString();
      setState(() => _errorText = null);
      return;
    }
    final n = int.tryParse(text);
    if (n == null) {
      setState(() => _errorText = '请输入数字');
      return;
    }
    if (n < 0) {
      setState(() => _errorText = '不能小于 0');
      return;
    }
    if (n > widget.maxSeconds) {
      setState(() => _errorText = '不能超过 ${widget.maxSeconds} 秒');
      return;
    }
    setState(() => _errorText = null);
    if (n != widget.value) {
      widget.onChange(n);
    }
  }

  void _applyPreset(int s) {
    _controller.text = s.toString();
    setState(() => _errorText = null);
    widget.onChange(s);
    _focusNode.unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: _errorText != null
                        ? Colors.red
                        : Colors.white.withValues(alpha: 0.1),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Icon(
                        Icons.timer_outlined,
                        color: Colors.white70,
                        size: 16,
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        keyboardType: TextInputType.number,
                        textInputAction: TextInputAction.done,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: AppTheme.fontBody,
                        ),
                        cursorColor: AppTheme.accentColor,
                        decoration: const InputDecoration(
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.symmetric(vertical: 10),
                          isDense: true,
                          hintText: '秒',
                          hintStyle: TextStyle(
                            color: Colors.white24,
                            fontSize: AppTheme.fontBody,
                          ),
                        ),
                        onSubmitted: (_) {
                          _submit();
                          _focusNode.unfocus();
                        },
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        '秒',
                        style: TextStyle(
                          color: Colors.white54,
                          fontSize: AppTheme.fontFootnote,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                _submit();
                _focusNode.unfocus();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.accentColor,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  '应用',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_errorText != null) ...[const SizedBox(height: 4), Text(_errorText!, style: const TextStyle(color: Colors.red, fontSize: AppTheme.fontCaption))],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: widget.presets.map((s) {
            final selected = widget.value == s;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _applyPreset(s),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: selected
                      ? AppTheme.accentColor
                      : Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  s == 0 ? '关闭' : '${s}秒',
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.white70,
                    fontSize: AppTheme.fontFootnote,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}

/// 听剧模式旋转音乐图标（装饰动画）
class _PipAudioModeMusicIcon extends StatefulWidget {
  final double size;
  final Color color;

  const _PipAudioModeMusicIcon({
    required this.size,
    required this.color,
  });

  @override
  State<_PipAudioModeMusicIcon> createState() => _PipAudioModeMusicIconState();
}

class _PipAudioModeMusicIconState extends State<_PipAudioModeMusicIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: Icon(
        Icons.graphic_eq,
        size: widget.size,
        color: widget.color,
      ),
    );
  }
}

// ============================================================
// 弹幕（Logvr-danmu / 弹弹play / B站 XML 兼容解析与渲染）
