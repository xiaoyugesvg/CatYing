// lib/widgets/parse_sniff_sheet.dart
//
// 「解析 / 嗅探」统一面板（2026-10-28）。
//
// ── 解决什么 ─────────────────────────────────────────────────
// 用户 2026-10-28：「将嗅探开关和解析切换放在一个按钮以及弹出面板呢？」
// 原来播放器底栏是**两个独立按钮**（嗅探 / 解析），而且只有当对应总开关
// 已经打开时才出现 —— 用户开了嗅探却看不到按钮、想切解析线路又找不到入口，
// 尤其在「官方聚合 → 爱奇艺链接 → 解析站 IP 超限」这种场景下完全没法自救。
//
// 现在合成一个按钮，点开就是这个面板：
//   · 嗅探开关（写 PlayerPrefs.sniffEnabled）+ 「立即嗅探当前页」
//   · 解析开关（写 PlayerPrefs.parseEnabled）
//   · 解析线路列表（唯一事实来源 = ParseStore，与「设置 → 解析线路管理」同一份）
//     点一条 = 设为当前线路并回调，由调用方重新解析当前集。
//
// 面板本身不持有播放器状态，全部通过回调交给页面，避免和详情页/短剧页耦合。

import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/app_config.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/parse_service.dart';
import 'package:tvbox/services/parse_store.dart';
import 'package:tvbox/services/player_prefs.dart';

class ParseSniffSheet extends StatefulWidget {
  const ParseSniffSheet({
    super.key,
    this.onSniff,
    this.onPickLine,
  });

  /// 点「立即嗅探当前页」。null = 当前页面没有可嗅探的网页地址（按钮禁用）。
  final VoidCallback? onSniff;

  /// 选中解析线路后回调（`''` = 自动）。调用方负责用新线路重解当前集。
  final ValueChanged<String>? onPickLine;

  /// 统一入口：从任意页面弹出这个面板。
  static Future<void> show(
    BuildContext context, {
    VoidCallback? onSniff,
    ValueChanged<String>? onPickLine,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => ParseSniffSheet(onSniff: onSniff, onPickLine: onPickLine),
    );
  }

  @override
  State<ParseSniffSheet> createState() => _ParseSniffSheetState();
}

class _ParseSniffSheetState extends State<ParseSniffSheet> {
  late bool _sniff = PlayerPrefs.instance.sniffEnabled.value;
  late bool _parse = PlayerPrefs.instance.parseEnabled.value;

  List<ParseBean> get _lines => ParseStore.instance.list;
  String get _active => ParseStore.instance.activeUrl;

  Future<void> _toggleSniff(bool v) async {
    setState(() => _sniff = v);
    await PlayerPrefs.instance.setSniffEnabled(v);
  }

  Future<void> _toggleParse(bool v) async {
    setState(() => _parse = v);
    await PlayerPrefs.instance.setParseEnabled(v);
  }

  void _sniffNow() {
    final cb = widget.onSniff;
    if (cb == null) return;
    Navigator.of(context).pop();
    cb();
  }

  Future<void> _pick(String url) async {
    await ParseStore.instance.setActive(url);
    // 与「解析线路管理」同一套同步：灌回 Rx + 清缓存，保证改完立即生效。
    ApiConfig.instance.parseBeanList.value = ParseStore.instance.list;
    ParseService.instance.clearCache();
    if (!mounted) return;
    Navigator.of(context).pop();
    widget.onPickLine?.call(url);
  }

  @override
  Widget build(BuildContext context) {
    final lines = _lines;
    final active = _active;
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 6),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: AppTheme.textTertiary.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // 标题
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Row(
              children: [
                Text(
                  '解析 / 嗅探',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  '${lines.length} 条线路',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          // ── 开关区 ─────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              decoration: BoxDecoration(
                color: AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                children: [
                  _switchRow(
                    icon: Icons.travel_explore_rounded,
                    title: '嗅探',
                    subtitle: '网页播放页抓不到地址时，用网页嗅探找媒体链接',
                    value: _sniff,
                    onChanged: _toggleSniff,
                  ),
                  Divider(
                    height: 0.5,
                    indent: 46,
                    endIndent: 12,
                    color: AppTheme.textTertiary.withValues(alpha: 0.18),
                  ),
                  _switchRow(
                    icon: Icons.workspace_premium_rounded,
                    title: '解析',
                    subtitle: '用解析线路把网页地址换成可播放直链',
                    value: _parse,
                    onChanged: _toggleParse,
                  ),
                ],
              ),
            ),
          ),
          if (_sniff)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.tonalIcon(
                  onPressed: widget.onSniff == null ? null : _sniffNow,
                  icon: const Icon(Icons.radar_rounded, size: 18),
                  label: Text(
                    widget.onSniff == null ? '当前没有可嗅探的网页' : '立即嗅探当前页',
                  ),
                ),
              ),
            ),
          // ── 线路列表 ───────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
            child: Row(
              children: [
                Text(
                  '解析线路',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: AppTheme.fontFootnote,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  _parse ? '选中后重新解析当前集' : '解析开关已关闭',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.42,
            ),
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              itemCount: lines.length + 1,
              separatorBuilder: (_, __) => const SizedBox(height: 6),
              itemBuilder: (c, i) {
                if (i == 0) {
                  return _lineTile(
                    title: '自动（按顺序尝试）',
                    subtitle: '按线路列表顺序依次尝试，命中即用',
                    selected: active.isEmpty,
                    onTap: () => _pick(''),
                  );
                }
                final b = lines[i - 1];
                return _lineTile(
                  title: b.name.trim().isEmpty ? b.url : b.name,
                  subtitle: b.url,
                  selected: active == b.url,
                  onTap: () => _pick(b.url),
                );
              },
            ),
          ),
          if (lines.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
              child: Text(
                '还没有解析线路。\n可在 设置 → 订阅管理 → 解析线路管理 里添加。',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: 12,
                  height: 1.6,
                ),
              ),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _switchRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppTheme.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontBody,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          Switch.adaptive(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _lineTile({
    required String title,
    String? subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Material(
      color: selected
          ? AppTheme.accentColor.withValues(alpha: 0.12)
          : AppTheme.backgroundTertiary,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: selected
                ? Border.all(
                    color: AppTheme.accentColor.withValues(alpha: 0.45),
                    width: 0.8,
                  )
                : null,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
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
                    if (subtitle != null && subtitle.trim().isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        subtitle.trim(),
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
              const SizedBox(width: 8),
              Icon(
                selected
                    ? Icons.check_circle_rounded
                    : Icons.chevron_right_rounded,
                color: selected
                    ? AppTheme.accentColor
                    : AppTheme.textTertiary.withValues(alpha: 0.6),
                size: 19,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
