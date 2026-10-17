import 'dart:async';

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
  Offset? _pos; // 左上角坐标；null = 默认屏幕右侧中间
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

  /// 选中元素 → 让用户确认（可改选择器、可微调、可改成"所有网站"）
  /// → 存规则并立即生效；「继续选下一个」= 连续处理多个广告。
  ///
  /// ── 用户 2026-10-16：「功能更细化加强」────────────────────────
  ///   · 改选择器时**实时**重画页面橙框 + 实时显示命中数（所见即所得）
  ///   · 一排微调：**放大范围 / 精确到这一个 / 上一层**（点不准时的出路）
  ///   · 命中过多（>80）红字警告，避免"点一下整页空白"
  ///   · 「继续选下一个」：存完立刻重新进点选模式，连续去掉多个广告
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
    var count = pick.count;
    var busy = false;

    /// 改选择器后：重画橙框 + 更新命中数（200ms 防抖，别每敲一个字都打一次 JS）
    StateSetter? dlgSet;
    Timer? debounce;
    void refreshCount(String sel) {
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 220), () async {
        await AdBlockService.instance.previewSelector(widget.controller, sel);
        final n = await AdBlockService.instance
            .countSelector(widget.controller, sel);
        if (!mounted) return;
        // ⚠️ 必须用**弹窗自己的** setState，否则计数变了界面不刷新
        dlgSet?.call(() => count = n);
      });
    }

    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) {
          dlgSet = setDlg;
          final bad = count > 80;
          return AlertDialog(
            backgroundColor: AppTheme.backgroundSecondary,
            title: Text('隐藏这个广告',
                style: TextStyle(color: AppTheme.textPrimary)),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 命中情况（实时）
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: AppTheme.backgroundTertiary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      count < 0
                          ? '选择器写错了（页面认不出来）'
                          : '会隐藏 $count 处'
                              '${count > 1 ? '（同类的一起藏）' : ''}',
                      style: TextStyle(
                          color: bad
                              ? Colors.orange.shade400
                              : AppTheme.textSecondary,
                          fontSize: AppTheme.fontSubhead),
                    ),
                  ),
                  if (bad)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text('命中太多，可能把正常内容也藏掉 —— 建议先点「精确」',
                          style: TextStyle(
                              color: Colors.orange.shade400,
                              fontSize: AppTheme.fontCaption)),
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
                    onChanged: (v) => refreshCount(v.trim()),
                    decoration: InputDecoration(
                      labelText: 'CSS 选择器（可改，页面实时预览）',
                      labelStyle: TextStyle(color: AppTheme.textTertiary),
                      helperText: '不确定就点下面三个按钮微调',
                      helperStyle: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontCaption),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // 微调：点不准时的三条出路
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _tuneChip(ctx, busy, Icons.zoom_out_map_rounded, '放大范围',
                          () async {
                        setDlg(() => busy = true);
                        final r = await AdBlockService.instance
                            .adjustPick(widget.controller, 'wide');
                        if (r != null) ctrl.text = r.selector;
                        setDlg(() {
                          busy = false;
                          if (r != null) count = r.count;
                        });
                      }),
                      _tuneChip(ctx, busy, Icons.center_focus_strong_rounded,
                          '精确', () async {
                        setDlg(() => busy = true);
                        final r = await AdBlockService.instance
                            .adjustPick(widget.controller, 'narrow');
                        if (r != null) ctrl.text = r.selector;
                        setDlg(() {
                          busy = false;
                          if (r != null) count = r.count;
                        });
                      }),
                      _tuneChip(ctx, busy, Icons.arrow_upward_rounded, '上一层',
                          () async {
                        setDlg(() => busy = true);
                        final r = await AdBlockService.instance
                            .adjustPick(widget.controller, 'parent');
                        if (r != null) ctrl.text = r.selector;
                        setDlg(() {
                          busy = false;
                          if (r != null) count = r.count;
                        });
                      }),
                    ],
                  ),
                  const SizedBox(height: 6),
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
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('取消',
                    style: TextStyle(color: AppTheme.textTertiary)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'next'),
                child: Text('继续选下一个',
                    style: TextStyle(color: AppTheme.textSecondary)),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, 'save'),
                child: Text('保存并隐藏',
                    style: TextStyle(color: AppTheme.accentOnSurface)),
              ),
            ],
          );
        },
      ),
    );
    debounce?.cancel();
    // 弹窗已关：把 setState 句柄断掉，避免防抖回调晚到一步、去 setState 已经销毁的弹窗
    dlgSet = null;
    // 用户在点选那一下已经看到"将命中"的橙框（见 kPickStartJs），
    // 这里无论是确认还是取消，都要把框清掉（否则一直挂在页面上）
    if (action == null) {
      await AdBlockService.instance.clearPickPreview(widget.controller);
      return;
    }
    final selector = ctrl.text.trim();
    if (selector.isEmpty) {
      await AdBlockService.instance.clearPickPreview(widget.controller);
      return;
    }
    final targetHost = global ? '' : host;
    await AdBlockService.instance
        .addRule(host: targetHost, selector: selector);
    await AdBlockService.instance.clearPickPreview(widget.controller);

    // 总开关关着的话，注入会被直接跳过 —— 这时刷新多少次都没用，
    // 直接说清楚（否则用户会以为"这功能没成功"，实际是开关没开）
    if (!AdBlockService.instance.enabled) {
      AppToast.message('规则已保存，但「网页去广告」总开关是关的：'
          '去 设置 → 广告管理 打开它');
      return;
    }

    // ── 立刻生效 + 校验（用户 2026-10-16）─────────────────────────
    // 「点击去掉广告后应该自动刷新，感觉这个功能没成功」：
    // 先靠重注入当场生效（不用等刷新）；**校验**没生效时再自动 reload 兜底。
    final applied = await AdBlockService.instance
        .applyAndVerify(widget.controller, url, selector);
    if (!mounted) return;
    if (!applied) {
      // 注入没落地（CSP / 元素还没挂上）→ 按用户要求自动刷新一次
      try {
        await widget.controller.reload();
      } catch (_) {}
    }

    // 「恢复」入口（用户 2026-10-16：「点击去掉广告…能不能恢复」）：
    // 存完给一根 6 秒的撤销条 —— 点「撤销」把刚加的这条删掉并重注入，广告立刻回来。
    // 用 SnackBar 而不是 AppToast，是因为只有它带得了按钮。
    final msg = applied
        ? (global ? '已隐藏（所有网站）' : '已隐藏（$host）')
        : '已保存并刷新页面';
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) {
      AppToast.message(msg);
      _maybeContinue(action);
      return;
    }
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 6),
        behavior: SnackBarBehavior.floating,
        action: SnackBarAction(
          label: '撤销',
          onPressed: () async {
            // 撤销新增：**不进回收站**（它本来就不该存在）
            await AdBlockService.instance.removeRule(
              AdBlockRule(host: targetHost, selector: selector),
              toTrash: false,
            );
            await AdBlockService.instance.injectInto(widget.controller, url);
            AppToast.message('已撤销，广告已恢复显示');
          },
        ),
      ),
    );
    _maybeContinue(action);
  }

  /// 用户点了「继续选下一个」→ 立刻重新进点选模式（连续去掉多个广告）
  void _maybeContinue(String action) {
    if (action != 'next') return;
    unawaited(() async {
      await AdBlockService.instance.startPick(widget.controller);
      if (!mounted) return;
      setState(() => _picking = true);
      AppToast.message('继续点下一个要隐藏的广告');
    }());
  }

  /// 确认框里的小胶囊按钮（放大 / 精确 / 上一层）
  Widget _tuneChip(
    BuildContext ctx,
    bool busy,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: AppTheme.accentOnSurface),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontCaption)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    // 用户 2026-10-17：默认位置改为**屏幕右侧中间**（原来在右下角，
    // 经常压住网页底部的翻页/播放控件），仍可自由拖动。
    final pos = _pos ??
        Offset(
          mq.size.width - widget.margin.right - _size,
          mq.padding.top +
              (mq.size.height - mq.padding.top - mq.padding.bottom - _size) / 2,
        );
    final maxX = (mq.size.width - _size).clamp(0.0, double.infinity);
    final minY = mq.padding.top;
    final maxY = (mq.size.height - mq.padding.bottom - _size)
        .clamp(minY, double.infinity);
    return Positioned(
      left: pos.dx.clamp(0.0, maxX),
      top: pos.dy.clamp(minY, maxY),
      child: GestureDetector(
        onTap: _togglePick,
        // 拖动后把坐标**钳在屏幕内**：原来只钳渲染位置、不钳 _pos，
        // 于是拖出屏幕后要反向拖回来很远才“重新出现”。
        onPanUpdate: (d) {
          final next = pos + d.delta;
          setState(() => _pos = Offset(
                next.dx.clamp(0.0, maxX),
                next.dy.clamp(minY, maxY),
              ));
        },
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
                color: _picking ? AppTheme.accentColor : AppTheme.borderMedium,
                width: _picking ? 2 : 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            // 猫影自己的**小猫头像**（用户 2026-10-16：「改成小猫头像」）；
            // 「点选模式」时叠一个准星图标 + 强调色圆环，状态一眼能看出来
            child: Stack(
              alignment: Alignment.center,
              children: [
                ClipOval(
                  child: Image.asset(
                    'assets/images/cat_logo.png',
                    width: _size,
                    height: _size,
                    fit: BoxFit.cover,
                    // 资源读不出来就退回原来的图标，别让它变空白
                    errorBuilder: (_, __, ___) => Icon(
                      _picking ? Icons.ads_click_rounded : Icons.block_rounded,
                      size: 20,
                      color: _picking ? Colors.white : AppTheme.textSecondary,
                    ),
                  ),
                ),
                if (_picking)
                  const Icon(
                    Icons.ads_click_rounded,
                    size: 20,
                    color: Colors.white,
                    shadows: [Shadow(blurRadius: 6, color: Colors.black54)],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
