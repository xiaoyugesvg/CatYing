import 'dart:async';

import 'package:flutter/material.dart';

import '../common/theme.dart';

/// 全局轻量气泡服务（**全 App 统一的提示组件**）。
///
/// ── 为什么要有它（统一三套提示）────────────────────────────────
/// 之前三个模块各显示各的：
///   · **影视**：`ScaffoldMessenger.showSnackBar`（44 处）
///   · **音乐**：`MusicPlayerManager.lastError`（ValueNotifier）+ SnackBar（10 处）
///   · **阅读**：本组件 `AppToast`（顶部气泡）
///
/// 结果同一个 App 里"提示"有三种位置和三种长相：底部黑条 / 页面内嵌文字 /
/// 顶部气泡。用户很难形成肌肉记忆。
///
/// 现在收口到这一个组件。**数据流不动**（音乐那边 `lastError` 照样更新，
/// 只是在 UI 层改成 `AppToast` 展示）—— 只换展示层。
///
/// ── 为什么在 `lib/widgets/` 而不是 `reading/utils/` ────────────
/// 原来它在阅读模块里，影视/音乐要用就会形成
/// "底层依赖阅读模块"的反向依赖。提到公共层后三个模块平级引用。
/// 阅读侧的 `reading/utils/app_toast.dart` 保留为**薄委托**，
/// 调用点一行不用改。
///
/// ── 特性 ──────────────────────────────────────────────────────
///   · **不依赖 `BuildContext`**：持有 `MaterialApp` 的全局 `navigatorKey`，
///     通过 root `Overlay` 插入，因此浮在**所有路由之上**
///     （含 push 出去的详情页 / 播放器 / 阅读器）
///   · 同时只显示一条，后到的覆盖前一条（不会堆叠刷屏）
///   · 内容拆成 [title]（可截断）+ [status]（始终完整），
///     保证"保存失败"这类关键状态在长标题下仍可见
class AppToast {
  AppToast._();

  static GlobalKey<NavigatorState>? _key;
  static OverlayEntry? _current;

  /// 在 App 顶层调用一次，注入 `MaterialApp` 的 navigatorKey。
  static void init(GlobalKey<NavigatorState> key) => _key = key;

  /// 显示一条顶部气泡。
  ///
  /// [title] 超长会被截断；[status] 始终完整显示。新气泡覆盖旧的。
  static void show(
    String title,
    String status, {
    bool isError = false,
    /// 显示时长。默认 2 秒 —— 原来各处的 SnackBar 用了 900ms~3s 不等的
    /// 时长，迁移时保留它们的语义（内部字段照旧那样传即可）。
    Duration duration = const Duration(seconds: 2),
  }) {
    final overlay = _key?.currentState?.overlay;
    if (overlay == null) return;
    _current?.remove();
    _current = null;
    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _ToastView(
        title: title,
        status: status,
        isError: isError,
        duration: duration,
        onDone: () {
          if (identical(_current, entry)) _current = null;
          entry.remove();
        },
      ),
    );
    _current = entry;
    overlay.insert(entry);
  }

  /// 便捷：只给一句话（不区分 title/status）。
  ///
  /// 供"影视/音乐那种一句话提示"直接替换 `showSnackBar` 使用 ——
  /// 它们的文案本来就不分主次，硬拆成两段反而别扭。
  static void message(
    String text, {
    bool isError = false,
    Duration duration = const Duration(seconds: 2),
  }) =>
      show(text, '', isError: isError, duration: duration);

  /// 便捷：成功提示
  static void success(String text) => show(text, '', isError: false);

  /// 便捷：错误提示
  static void error(String text) => show(text, '', isError: true);
}

/// 顶部气泡视图：淡入 + 下滑入场，约 2s 后反向淡出并移除。
class _ToastView extends StatefulWidget {
  const _ToastView({
    required this.title,
    required this.status,
    required this.isError,
    required this.duration,
    required this.onDone,
  });

  final String title;
  final String status;
  final bool isError;
  final Duration duration;
  final VoidCallback onDone;

  @override
  State<_ToastView> createState() => _ToastViewState();
}

class _ToastViewState extends State<_ToastView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
    )..forward();
    _timer = Timer(widget.duration, () {
      if (mounted) _ctrl.reverse().then((_) => widget.onDone());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final slide = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    final mq = MediaQuery.of(context);
    final style = TextStyle(
      fontSize: AppTheme.fontBody,
      color: widget.isError
          ? const Color(0xFFE57373)
          : (isDark ? Colors.white : Colors.black87),
    );
    return Positioned(
      top: mq.padding.top + 12,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: FadeTransition(
          opacity: _ctrl,
          child: SlideTransition(
            position: slide,
            child: Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(maxWidth: mq.size.width - 32),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    // 用 AppTheme（跟当前模块的调色板走），
                    // 而不是原来写死的 JellyTheme（阅读的）——
                    // 否则影视/音乐弹这个气泡时会是阅读的主题色。
                    color: AppTheme.backgroundCard
                        .withValues(alpha: isDark ? 0.92 : 0.96),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: widget.isError
                          ? Colors.red.withValues(alpha: 0.4)
                          : (isDark ? Colors.white : Colors.black).withValues(
                              alpha: 0.06,
                            ),
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.12),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  // 标题可截断，状态固定——保证"下载成功/失败"在长标题下仍可见
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style,
                        ),
                      ),
                      if (widget.status.isNotEmpty)
                        Text(' ${widget.status}', style: style),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
