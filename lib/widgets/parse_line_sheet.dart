import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/parse_lines.dart';

/// 「切换解析线路」弹层 —— 详情页 / 竖屏播放器 / 海阔 / RSS 共用一个。
///
/// ── 为什么要有它（用户 2026-10-31）──────────────────────────────
/// 用户原话：
///   ·「播放器下面没有切换线路的按钮吗？不管是默认详情里面的还是纯竖屏的播放器呢」
///   ·「那么多线路你一个个弄吗，切换线路就是切换前缀，解析站不行那就是我
///     自己切换线路来」
///
/// 所以「线路」在本 App 里就是**解析线路**（`jx.xx/?url=…` 那个前缀），
/// 不是 CMS 的播放源。App 只试当前这一条（`_platformSniffLines = 1`），
/// 失败后**把决定权交回用户**：这里列出来，点哪条就换成哪条。
///
/// 返回值语义：
///   · `null`      —— 用户取消，什么都不做；
///   · `''`        —— 选「自动（不套线路，直接嗅探原页面）」；
///   · 其它字符串  —— 选中的线路 id（[ParseLineStore.setSelected] 用）。
Future<String?> showParseLineSheet(
  BuildContext context, {
  String title = '切换解析线路',
  String hint = '解析站不行就换一条，换完会自动重新嗅探当前这一集',
}) {
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => _ParseLineSheet(title: title, hint: hint),
  );
}

class _ParseLineSheet extends StatefulWidget {
  const _ParseLineSheet({required this.title, required this.hint});

  final String title;
  final String hint;

  @override
  State<_ParseLineSheet> createState() => _ParseLineSheetState();
}

class _ParseLineSheetState extends State<_ParseLineSheet> {
  final _store = ParseLineStore.instance;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  /// 懒同步订阅线路：设置页没打开过时，这里必须自己拉一次，
  /// 否则弹层永远只有自定义那几条（用户会以为「订阅线路没导入」）。
  Future<void> _boot() async {
    try {
      if (!_store.loaded) await _store.load();
      await _store.ensureSyncedFromConfig();
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final lines = _store.attemptOrder;
    final selectedId = _store.selectedId;
    final maxH = MediaQuery.of(context).size.height * 0.62;

    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: BoxDecoration(
        color: AppTheme.backgroundElevated,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(AppTheme.glassRadius),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppTheme.spacingSM),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.textTertiary.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.spacingLG,
                AppTheme.spacingMD,
                AppTheme.spacingLG,
                AppTheme.spacingSM,
              ),
              child: Row(
                children: [
                  Icon(Icons.alt_route_rounded,
                      size: 18, color: AppTheme.accentColor),
                  const SizedBox(width: AppTheme.spacingSM),
                  Expanded(
                    child: Text(
                      widget.title,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '共 ${lines.length} 条',
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppTheme.spacingLG,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.hint,
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption,
                    height: 1.4,
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppTheme.spacingSM),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 28),
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            else
              Flexible(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppTheme.spacingMD,
                    0,
                    AppTheme.spacingMD,
                    AppTheme.spacingMD,
                  ),
                  children: [
                    // 「自动」= 不套线路。普通网页播放页本来就不需要前缀，
                    // 平台页选了它会直接嗅探平台页（0 候选）——文案里说清楚，
                    // 免得用户以为是"最保险的选项"。
                    _LineTile(
                      name: '自动（不套线路）',
                      subtitle: '直接嗅探原页面；爱优腾这类平台页会抓不到',
                      selected: selectedId.isEmpty,
                      isCustom: false,
                      onTap: () => Navigator.of(context).pop(''),
                    ),
                    const SizedBox(height: AppTheme.spacingXS),
                    for (final l in lines)
                      _LineTile(
                        name: l.name,
                        subtitle: l.url,
                        selected: l.id == selectedId,
                        isCustom: l.isCustom,
                        onTap: () => Navigator.of(context).pop(l.id),
                      ),
                    if (lines.isEmpty) ...[
                      const SizedBox(height: AppTheme.spacingMD),
                      Text(
                        _store.syncError.isEmpty
                            ? '订阅配置里没有 parses 解析线路，'
                                '也没有自定义线路。\n'
                                '去「设置 → 解析线路」加一条，或换一份带 parses 的订阅。'
                            : '读取订阅线路失败：${_store.syncError}',
                        style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontFootnote,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LineTile extends StatelessWidget {
  const _LineTile({
    required this.name,
    required this.subtitle,
    required this.selected,
    required this.isCustom,
    required this.onTap,
  });

  final String name;
  final String subtitle;
  final bool selected;
  final bool isCustom;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppTheme.radiusMD),
      child: Container(
        margin: const EdgeInsets.only(bottom: AppTheme.spacingXS),
        padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacingMD,
          vertical: AppTheme.spacingSM + 2,
        ),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.accentColor.withValues(alpha: 0.12)
              : AppTheme.backgroundTertiary.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(AppTheme.radiusMD),
          border: Border.all(
            color: selected
                ? AppTheme.accentColor.withValues(alpha: 0.55)
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: selected
                                ? AppTheme.accentColor
                                : AppTheme.textPrimary,
                            fontSize: AppTheme.fontBody,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                      ),
                      if (isCustom) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.textTertiary.withValues(alpha: 0.18),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '自定义',
                            style: TextStyle(
                              color: AppTheme.textTertiary,
                              fontSize: 10,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  if (subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_rounded,
                  size: 18, color: AppTheme.accentColor),
          ],
        ),
      ),
    );
  }
}
