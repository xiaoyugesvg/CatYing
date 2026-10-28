// lib/widgets/parse_sniff_sheet.dart
//
// 「嗅探 / 解析」面板（2026-10-28 初版，2026-10-28 重构）。
//
// ── 解决什么 ─────────────────────────────────────────────────
// 用户 2026-10-28 两版诉求：
//   ①「将嗅探开关和解析切换放在一个按钮以及弹出面板」→ 初版合成一个按钮；
//   ② 随后改为「嗅探和解析是单独的，不是要开嗅探才有按钮」→ 本版拆回两个
//      独立按钮，但面板仍按 `section` 聚焦（嗅探区 / 解析区 / 两者），避免
//      一个按钮里塞太多东西。
//
// 关键约束（来自用户 2026-10-28 长消息）：
//   · 播放器上的「嗅探」「解析」两个按钮**无论设置开关是否打开都必须存在**
//     （`video_player.dart` 底栏据此常驻显示，`onSniff`/`onSwitchParse` 不为
//     null 即显示），否则「嗅探关着 → 按钮消失 → 点不开 → 死循环」。
//   · 面板里的开关要和「设置」实时同步 —— 这里全部用 `Obx` 直读
//     `PlayerPrefs` 的 Rx，任何一处改动另一处立刻反映。
//
// 面板本身不持有播放器状态，全部通过回调交给页面，避免和详情页/短剧页耦合。

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/app_config.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/parse_service.dart';
import 'package:tvbox/services/parse_store.dart';
import 'package:tvbox/services/player_prefs.dart';

/// 面板聚焦区域：决定只显示嗅探相关、还是只显示解析相关、还是全部。
enum ParseSniffSection {
  /// 两者都显示（详情页 WebView 兜底播放的右上角入口可用它）。
  both,

  /// 只显示嗅探区（底栏「嗅」按钮入口）。
  sniff,

  /// 只显示解析区（底栏「解析」按钮入口）。
  parse,
}

class ParseSniffSheet extends StatelessWidget {
  const ParseSniffSheet({
    super.key,
    this.section = ParseSniffSection.both,
    this.onSniff,
    this.onPickLine,
  });

  /// 聚焦区域。
  final ParseSniffSection section;

  /// 点「立即嗅探当前页」。null = 当前页面没有可嗅探的网页地址（按钮禁用）。
  final VoidCallback? onSniff;

  /// 选中解析线路后回调（`''` = 自动）。调用方负责用新线路重解当前集。
  final ValueChanged<String>? onPickLine;

  /// 统一入口：从任意页面弹出这个面板。
  static Future<void> show(
    BuildContext context, {
    ParseSniffSection section = ParseSniffSection.both,
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
      builder: (_) => ParseSniffSheet(
        section: section,
        onSniff: onSniff,
        onPickLine: onPickLine,
      ),
    );
  }

  bool get _showSniff => section != ParseSniffSection.parse;
  bool get _showParse => section != ParseSniffSection.sniff;

  String get _title {
    switch (section) {
      case ParseSniffSection.sniff:
        return '嗅探';
      case ParseSniffSection.parse:
        return '解析线路';
      case ParseSniffSection.both:
        return '解析 / 嗅探';
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = ParseStore.instance.list;
    final active = ParseStore.instance.activeUrl;
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
                  _title,
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (_showParse)
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

          // ── 嗅探区 ─────────────────────────────────────────────
          if (_showSniff) _sniffSection(context),

          // 两个区都显示时，中间加一条分隔
          if (_showSniff && _showParse)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Divider(
                height: 0.5,
                color: AppTheme.textTertiary.withValues(alpha: 0.18),
              ),
            ),

          // ── 解析区 ─────────────────────────────────────────────
          if (_showParse) _parseSection(context: context, lines: lines, active: active),

          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 嗅探区：嗅探总开关（实时同步设置）+ 「立即嗅探当前页」。
  Widget _sniffSection(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            // 嗅探总开关：直读 PlayerPrefs（Obx），与「设置」实时同步。
            Obx(() => _switchRow(
                  icon: Icons.travel_explore_rounded,
                  title: '自动嗅探',
                  subtitle: '网页播放页抓不到地址时，用网页嗅探找媒体链接',
                  value: PlayerPrefs.instance.sniffEnabled.value,
                  onChanged: (v) => PlayerPrefs.instance.setSniffEnabled(v),
                )),
            Divider(
              height: 0.5,
              indent: 46,
              endIndent: 12,
              color: AppTheme.textTertiary.withValues(alpha: 0.18),
            ),
            // 「播发带 Referer」也归到嗅探区（防盗链，常和嗅探一起用）
            Obx(() => _switchRow(
                  icon: Icons.link_outlined,
                  title: '播放带 Referer',
                  subtitle: '用页面地址做防盗链，部分站点必须带才能播',
                  value: PlayerPrefs.instance.sniffSendReferer.value,
                  onChanged: (v) =>
                      PlayerPrefs.instance.setSniffSendReferer(v),
                )),
            // 「立即嗅探当前页」：常驻显示（用户要求"不管设置有没有打开"
            // 都要能点到）。嗅探关着时点它会先开嗅探再嗅探，避免死循环。
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: Obx(() {
                final sniffOn = PlayerPrefs.instance.sniffEnabled.value;
                final disabled = onSniff == null;
                return SizedBox(
                  width: double.infinity,
                  child: FilledButton.tonalIcon(
                    onPressed: disabled
                        ? null
                        : () {
                            // 没开嗅探 → 先开（写入即与设置同步），再嗅探
                            if (!sniffOn) {
                              PlayerPrefs.instance.setSniffEnabled(true);
                            }
                            Navigator.of(context).pop();
                            onSniff!();
                          },
                    icon: const Icon(Icons.radar_rounded, size: 18),
                    label: Text(disabled
                        ? '当前没有可嗅探的网页'
                        : (sniffOn
                            ? '立即嗅探当前页'
                            : '开启嗅探并嗅探')),
                  ),
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  /// 解析区：解析总开关（实时同步）+ 脚本内置优先级 + 线路列表。
  Widget _parseSection({
    required BuildContext context,
    required List<ParseBean> lines,
    required String active,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          children: [
            Obx(() => _switchRow(
                  icon: Icons.workspace_premium_rounded,
                  title: '解析接口',
                  subtitle: '用解析线路把网页地址换成可播放直链',
                  value: PlayerPrefs.instance.parseEnabled.value,
                  onChanged: (v) => PlayerPrefs.instance.setParseEnabled(v),
                )),
            Divider(
              height: 0.5,
              indent: 46,
              endIndent: 12,
              color: AppTheme.textTertiary.withValues(alpha: 0.18),
            ),
            // 脚本自带解析时的优先级（尊重脚本 / 一律用你的线路）
            Obx(() => _switchRow(
                  icon: Icons.extension_rounded,
                  title: '优先用脚本内置解析',
                  subtitle: PlayerPrefs.instance.preferScriptParse.value
                      ? '脚本声明要解析时，直接用它自己的解析站'
                      : '一律用你的解析线路（会剥掉脚本解析地址的外壳重解）',
                  value: PlayerPrefs.instance.preferScriptParse.value,
                  onChanged: (v) =>
                      PlayerPrefs.instance.setPreferScriptParse(v),
                )),
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
                  Flexible(
                    child: Obx(() => Text(
                      !PlayerPrefs.instance.parseEnabled.value
                          ? '解析开关已关闭'
                          : (PlayerPrefs.instance.preferScriptParse.value
                              ? '选线路会自动改为优先用你的线路'
                              : '选中后重新解析当前集'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: 11,
                      ),
                    )),
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
                      onTap: () => _pick('', context),
                    );
                  }
                  final b = lines[i - 1];
                  return _lineTile(
                    title: b.name.trim().isEmpty ? b.url : b.name,
                    subtitle: b.url,
                    selected: active == b.url,
                    onTap: () => _pick(b.url, context),
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
          ],
        ),
      ),
    );
  }

  Future<void> _pick(String url, BuildContext context) async {
    await ParseStore.instance.setActive(url);
    // 与「解析线路管理」同一套同步：灌回 Rx + 清缓存，保证改完立即生效。
    ApiConfig.instance.parseBeanList.value = ParseStore.instance.list;
    ParseService.instance.clearCache();
    if (url.isNotEmpty && !PlayerPrefs.instance.parseEnabled.value) {
      // 用户主动选线路 = 明确要用解析：解析总开关若关着，顺手打开，
      // 否则 ParseService.enabled 为 false，选了也不生效。
      await PlayerPrefs.instance.setParseEnabled(true);
    }
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    onPickLine?.call(url);
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
