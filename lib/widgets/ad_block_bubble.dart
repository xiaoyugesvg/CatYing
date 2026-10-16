import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../common/theme.dart';
import '../services/ad_block_service.dart';
import 'app_toast.dart';

/// 网页上的**去广告悬浮球**：点一下进入"点选元素"模式，选中后把规则存下来。
///
/// 用法（放进页面已有的 Stack 里，与 WebViewWidget 同级）：
/// ```dart
/// Stack(children: [
///   Positioned.fill(child: WebViewWidget(controller: _controller)),
///   if (AdBlockService.instance.showBubble)
///     AdBlockBubble(controller: _controller, pageUrl: _url),
/// ])
/// ```
/// 前提：建 controller 后要 `AdBlockService.attach(controller)`（挂 JS 通道），
/// 并在 `onPageStarted`/`onPageFinished` 调 `injectInto`（见该服务说明）。
class AdBlockBubble extends StatefulWidget {
  final WebViewController controller;

  /// 当前页地址（兜底用；确认规则时会再向 WebView 要一次真实地址）
  final String pageUrl;

  /// 与屏幕边缘 / 顶底栏的留白
  final EdgeInsets margin;

  const AdBlockBubble({
    super.key,
    required this.controller,
    required this.pageUrl,
    this.margin = const EdgeInsets.only(right: 12, bottom: 96),
  });

  @override
  State<AdBlockBubble> createState() => _AdBlockBubbleState();
}

class _AdBlockBubbleState extends State<AdBlockBubble> {
  Offset? _pos; // 左上角坐标；null = 默认右下角
  bool _picking = false;
  double _size = 44;

  @override
  void initState() {
    super.initState();
    AdBlockService.instance.lastPick.addListener(_onPicked);
  }

  @override
  void dispose() {
    AdBlockService.instance.lastPick.removeListener(_onPicked);
    super.dispose();
  }

  void _onPicked() {
    final pick = AdBlockService.instance.lastPick.value;
    if (pick != null) _confirm(pick);
  }

  Future<void> _togglePick() async {
    final svc = AdBlockService.instance;
    if (_picking) {
      await svc.stopPick(widget.controller);
      if (mounted) setState(() => _picking = false);
      return;
    }
    await svc.startPick(widget.controller);
    if (!mounted) return;
    setState(() => _picking = true);
    AppToast.message('点页面上要隐藏的广告（再点悬浮球取消）');
  }

  /// 选中元素 → 让用户确认（可改选择器、可改成"所有网站"）→ 存规则并立即生效
  Future<void> _confirm(AdBlockPick pick) async {
    AdBlockService.instance.consumePick();
    if (mounted) setState(() => _picking = false);

    var url = widget.pageUrl;
    try {
      url = (await widget.controller.currentUrl()) ?? url;
    } catch (_) {}
    final host = AdBlockService.hostOf(url);

    final ctrl = TextEditingController(text: pick.selector);
    var global = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: AppTheme.backgroundSecondary,
          title: Text('隐藏这个广告',
              style: TextStyle(color: AppTheme.textPrimary)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '这条选择器在页面上命中 ${pick.count} 处'
                '${pick.count > 1 ? '（同类的一起隐藏）' : ''}',
                style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontSubhead),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: ctrl,
                maxLines: 3,
                minLines: 1,
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontFootnote,
                    fontFamily: 'monospace'),
                decoration: InputDecoration(
                  labelText: 'CSS 选择器（可改）',
                  labelStyle: TextStyle(color: AppTheme.textTertiary),
                  helperText: '改宽一点能一次去掉更多同类元素',
                  helperStyle: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Checkbox(
                    value: global,
                    onChanged: (v) => setDlg(() => global = v == true),
                  ),
                  Expanded(
                    child: Text(
                      global ? '所有网站都隐藏' : '只在 $host 生效',
                      style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: AppTheme.fontFootnote),
                    ),
                  ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('取消',
                  style: TextStyle(color: AppTheme.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('保存并隐藏',
                  style: TextStyle(color: AppTheme.accentOnSurface)),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final selector = ctrl.text.trim();
    if (selector.isEmpty) return;
    await AdBlockService.instance
        .addRule(host: global ? '' : host, selector: selector);
    // 规则存完立即重注入 —— 页面当场就干净了，也不用刷新
    await AdBlockService.instance.injectInto(widget.controller, url);
    AppToast.message(global
        ? '已保存（所有网站生效）'
        : '已保存（$host 生效）');
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final pos = _pos ??
        Offset(
          mq.size.width - widget.margin.right - _size,
          mq.size.height - widget.margin.bottom - _size - mq.padding.bottom,
        );
    return Positioned(
      left: pos.dx.clamp(0.0, (mq.size.width - _size).clamp(0.0, double.infinity)),
      top: pos.dy.clamp(0.0, (mq.size.height - _size).clamp(0.0, double.infinity)),
      child: GestureDetector(
        onTap: _togglePick,
        onPanUpdate: (d) => setState(() => _pos = pos + d.delta),
        child: Tooltip(
          message: _picking ? '取消选元素' : '点选广告并隐藏',
          child: Container(
            width: _size,
            height: _size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _picking
                  ? AppTheme.accentColor
                  : AppTheme.backgroundCard.withValues(alpha: 0.86),
              border: Border.all(
                  color: _picking ? AppTheme.accentColor : AppTheme.borderMedium),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              _picking ? Icons.ads_click_rounded : Icons.block_rounded,
              size: 20,
              color: _picking ? Colors.white : AppTheme.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}
