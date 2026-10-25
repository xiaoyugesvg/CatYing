import 'dart:math';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../pages/settings/sub/ai_settings_page.dart';
import '../../widgets/app_toast.dart';
import '../services/ai_service.dart';
import 'pet_service.dart';
import 'pet_view.dart';

/// 桌宠对话（2026-10-25 重做）
///
/// 三条硬规则（用户明确要求）：
///   1. **宠物只用「AI 管理」里的配置** —— 这里不再有自己的接口表单，
///      没配就直接跳过去配；阅读模块的独立配置不影响宠物。
///   2. 点宠物 = 开这个面板，能打字，也能用系统听写说话（键盘上的麦克风）。
///   3. 布局从"一个裸输入框"改成：头像 + 气泡 + 快捷话题 + 胶囊输入条。
class PetChatSheet extends StatefulWidget {
  const PetChatSheet({super.key, this.anchor});

  /// 宠物在屏幕上的矩形（来自悬浮层）。
  /// 有值时对话卡片**贴着宠物**弹；为空时退回居中（兜底）。
  final Rect? anchor;

  @override
  State<PetChatSheet> createState() => _PetChatSheetState();
}

class _PetChatSheetState extends State<PetChatSheet> {
  final _ai = AiService();
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _focus = FocusNode();

  final List<({bool me, String text})> _messages = [];
  bool _busy = false;
  bool _ready = false;

  /// 手动拖动偏移（用户 2026-10-25：「对话这个能不能移动一哈呢？」）。
  /// 初始位置仍按贴宠物/居中自动计算，用户从头部按住拖动后叠加该偏移。
  Offset _dragOffset = Offset.zero;

  static const int _maxMessages = 100;

  @override
  void initState() {
    super.initState();
    _ai.init().then((_) {
      if (mounted) setState(() => _ready = true);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _append(({bool me, String text}) m) {
    _messages.add(m);
    if (_messages.length > _maxMessages) {
      _messages.removeRange(0, _messages.length - _maxMessages);
    }
  }

  String get _systemPrompt {
    final p = PetService.instance;
    return '你是一只名叫「${p.species.name}」的熊猫桌宠，说话简短、活泼、带一点撒娇，'
        '每次回复不超过 80 字，不要用列表和 Markdown。'
        '当前状态：等级 ${p.level}，饱食度 ${p.hunger.round()}，'
        '心情 ${p.mood.round()}，猫币 ${p.coins}。'
        '如果饱食度低就小声提醒喂饭，心情低就要求陪玩。';
  }

  Future<void> _send([String? preset]) async {
    if (!_ai.isConfigured) {
      await Get.to(() => const AiSettingsPage());
      if (mounted) setState(() {});
      return;
    }
    final text = (preset ?? _input.text).trim();
    if (text.isEmpty || _busy) return;
    setState(() {
      _append((me: true, text: text));
      _busy = true;
    });
    _input.clear();
    _jumpBottom();
    try {
      final recent = _messages.length > 7
          ? _messages.sublist(_messages.length - 7, _messages.length - 1)
          : _messages.sublist(0, _messages.length - 1);
      final ctx =
          recent.map((m) => '${m.me ? "主人" : "我"}：${m.text}').join('\n');
      final user = ctx.isEmpty ? text : '$ctx\n主人：$text\n我：';
      final reply = await _ai.chat(system: _systemPrompt, user: user);
      if (!mounted) return;
      setState(() => _append((me: false, text: reply)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _append((me: false, text: '（说不出话）$e')));
    } finally {
      if (mounted) setState(() => _busy = false);
      _jumpBottom();
    }
  }

  void _jumpBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final anchor = widget.anchor;

    // 没有锚点（异常路径）⇒ 还是居中
    if (anchor == null) {
      return Center(
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            bottom: bottomInset + 24,
            top: 24,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
                maxWidth: 360, maxHeight: size.height * 0.66),
            child: _cardBody(),
          ),
        ),
      );
    }

    // ── 贴着宠物定位（用户 2026-10-25）──
    //   · 宠物两侧空间够（≥250）→ 放侧边，垂直与宠物居中对齐
    //   · 不够 → 放宠物上方/下方，水平居中
    // 之后叠加用户手动拖动偏移 [_dragOffset]，并 clamp 在屏幕内。
    final safeTop = MediaQuery.of(context).padding.top;
    const gap = 10.0;
    final maxCardW = min(340.0, size.width - 24);
    final spaceRight = size.width - anchor.right - 12;
    final spaceLeft = anchor.left - 12;
    final sideSpace = max(spaceRight, spaceLeft);
    final useSide = sideSpace >= 250;
    final cardW = useSide ? min(maxCardW, sideSpace - gap) : maxCardW;

    final availH = size.height - bottomInset - safeTop - 16;
    final cardMaxH = max(180.0, min(availH * 0.72, 430.0));

    double left;
    double top;
    if (useSide) {
      left = spaceRight >= spaceLeft
          ? anchor.right + gap
          : anchor.left - cardW - gap;
      top = anchor.top + anchor.height / 2 - cardMaxH / 2;
    } else {
      left = ((size.width - cardW) / 2).clamp(12.0, size.width - cardW - 12);
      final preferBelow = anchor.center.dy < size.height / 2;
      top = preferBelow
          ? anchor.bottom + gap
          : anchor.top - cardMaxH - gap;
    }
    top = top.clamp(
      safeTop + 8,
      max(safeTop + 8, size.height - bottomInset - 8 - cardMaxH),
    );

    // 手动拖动：叠加偏移后仍限制在可视区内（底部避开键盘）
    final dragLeft = (left + _dragOffset.dx)
        .clamp(0.0, max(0.0, size.width - cardW))
        .toDouble();
    final dragTop = (top + _dragOffset.dy)
        .clamp(safeTop, max(safeTop, size.height - bottomInset - cardMaxH))
        .toDouble();

    return Stack(
      children: [
        Positioned(
          left: dragLeft,
          top: dragTop,
          width: cardW,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: cardMaxH),
            child: _cardBody(),
          ),
        ),
      ],
    );
  }

  /// 对话卡片本体（定位由外层负责）
  Widget _cardBody() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 28,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(),
          const Divider(height: 1, thickness: 0.5),
          if (!_ready)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else if (!_ai.isConfigured)
            _needConfig()
          else ...[
            // 用 Flexible + shrinkWrap：卡片按内容长高（不硬撑满 66%），
            // 消息多了才封顶到 maxHeight 并可滚动。
            Flexible(
              child: _messages.isEmpty
                  ? _emptyHint()
                  : ListView.builder(
                      controller: _scroll,
                      shrinkWrap: true,
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
                      itemCount: _messages.length + (_busy ? 1 : 0),
                      itemBuilder: (context, i) {
                        if (i == _messages.length) {
                          return _bubble(false, '…', typing: true);
                        }
                        final m = _messages[i];
                        return _bubble(m.me, m.text);
                      },
                    ),
            ),
            if (_messages.isEmpty) _quickChips(),
            _inputBar(),
          ],
        ],
      ),
    );
  }

  Widget _header() {
    final p = PetService.instance;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // 只有头部可拖（消息列表要滚动，整卡拖会跟滚动手势打架）
      onPanUpdate: (d) => setState(() => _dragOffset += d.delta),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 10),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppTheme.backgroundTertiary,
              ),
              clipBehavior: Clip.antiAlias,
              child: PetView(
                species: p.species,
                outfit: p.equippedOutfit,
                outfits: p.equippedOutfitsByName,
                t: 0.5,
                size: 38,
                headOnly: true,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    p.species.name,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'Lv.${p.level} · 心情 ${p.mood.round()}',
                    style: TextStyle(color: AppTheme.textTertiary, fontSize: 11),
                  ),
                ],
              ),
            ),
            Tooltip(
              message: '按住头部拖动',
              child: Icon(Icons.drag_handle_rounded,
                  size: 18, color: AppTheme.textTertiary),
            ),
            const SizedBox(width: 2),
            IconButton(
              onPressed: () => Get.back(),
              icon: Icon(Icons.close_rounded,
                  size: 20, color: AppTheme.textTertiary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _needConfig() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 30),
      child: Column(
        children: [
          Icon(Icons.smart_toy_outlined,
              size: 34, color: AppTheme.textTertiary),
          const SizedBox(height: 12),
          Text(
            '还没有配置 AI\n宠物固定使用「设置 → AI 管理」里的配置',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () async {
              await Get.to(() => const AiSettingsPage());
              if (mounted) setState(() {});
            },
            child: const Text('去配置'),
          ),
        ],
      ),
    );
  }

  Widget _emptyHint() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Text(
          '摸摸头也能聊天。\n想说话就点下面的麦克风（用键盘听写）。',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.7,
            color: AppTheme.textTertiary,
          ),
        ),
      ),
    );
  }

  Widget _quickChips() {
    const items = ['今天心情怎么样？', '讲个冷笑话', '推荐一本书', '陪我读一会儿'];
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          return ActionChip(
            label: Text(items[i], style: const TextStyle(fontSize: 12)),
            onPressed: () => _send(items[i]),
            backgroundColor: AppTheme.backgroundTertiary,
            side: BorderSide.none,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
          );
        },
      ),
    );
  }

  Widget _bubble(bool me, String text, {bool typing = false}) {
    final petBg = AppTheme.backgroundCard;
    final meBg = AppTheme.accentOnSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        mainAxisAlignment:
            me ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!me) ...[
            _miniAvatar(),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.68,
              ),
              decoration: BoxDecoration(
                color: me ? meBg : petBg,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(me ? 16 : 4),
                  bottomRight: Radius.circular(me ? 4 : 16),
                ),
              ),
              child: Text(
                typing ? '…' : text,
                style: TextStyle(
                  fontSize: 13.5,
                  height: 1.5,
                  color: me ? Colors.white : AppTheme.textPrimary,
                ),
              ),
            ),
          ),
          if (me) const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _miniAvatar() {
    final p = PetService.instance;
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppTheme.backgroundTertiary,
      ),
      clipBehavior: Clip.antiAlias,
      child: PetView(
        species: p.species,
        outfit: p.equippedOutfit,
        outfits: p.equippedOutfitsByName,
        t: 0.5,
        size: 26,
        headOnly: true,
      ),
    );
  }

  Widget _inputBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(24),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                children: [
                  IconButton(
                    tooltip: '语音输入',
                    onPressed: () {
                      _focus.requestFocus();
                      AppToast.message('点键盘上的麦克风就能说话（系统听写）');
                    },
                    icon: Icon(Icons.mic_none_rounded,
                        size: 20, color: AppTheme.textSecondary),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      focusNode: _focus,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      style: TextStyle(
                          fontSize: 13.5, color: AppTheme.textPrimary),
                      decoration: const InputDecoration(
                        hintText: '跟它说点什么…',
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: AppTheme.accentOnSurface,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _busy ? null : () => _send(),
              child: Padding(
                padding: const EdgeInsets.all(11),
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.arrow_upward_rounded,
                        size: 19, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
