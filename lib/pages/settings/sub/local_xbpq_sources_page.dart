import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/xbpq/xbpq_rule.dart';
import 'package:tvbox/services/xbpq/xbpq_service.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/card_action_sheet.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';

/// 设置 → 订阅管理 → XBPQ 规则源
///
/// 与「本地 Python 源」「本地 JS 源」并列的第三族本地源，但**引擎完全不同**：
///   · PY / JS 源是把脚本交给 Python / Node 运行时去跑；
///   · XBPQ 源是把 huoyi 那套「抓站规则 JSON」交给内置的 Dart 引擎直接解析，
///     不依赖任何外部运行时，装好即用。
///
/// 规则只存 JSON 文本（`SharedPreferences`，与订阅线路分开），key 是规则文本
/// 的 md5 前 12 位 ⇒ 同一条规则反复导入不会产生重复项，改名也不会换 key。
class LocalXbpqSourcesPage extends StatefulWidget {
  const LocalXbpqSourcesPage({super.key});

  @override
  State<LocalXbpqSourcesPage> createState() => _LocalXbpqSourcesPageState();
}

class _LocalXbpqSourcesPageState extends State<LocalXbpqSourcesPage> {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 首次进入先把清单读出来（不依赖设置页是否已 reload）。
    XbpqService.instance.ensureLoaded(force: true).then((_) {
      if (mounted) setState(() {});
    });
  }

  // ============================================================
  // 导入
  // ============================================================

  Future<void> _importPaste() async {
    if (_busy) return;
    final text = await SettingsDialogs.editText(
      context: context,
      title: '粘贴 XBPQ 规则',
      initial: '',
      hint: '{"主页url":"https://…","分类url":"…"}',
      maxLines: 10,
      helper: '把 XBPQ / huoyi 爬虫规则整段贴进来。'
          '规则里没有名字时会用站点域名当名称，之后可以改名。',
    );
    if (text == null || text.trim().isEmpty) return;
    await _importOne(name: '', text: text);
  }

  /// 从文件导入：`.json` / `.txt` 均可，一次可选多个，一个文件算一条规则。
  Future<void> _importFiles() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // file_picker 13 起 `pickFiles` 一律支持多选（`allowMultiple` 已移除）。
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt'],
      );
      if (result.isEmpty) return;

      var ok = 0;
      final errors = <String>[];
      for (final f in result) {
        final bytes = await f.readAsBytes();
        if (bytes.isEmpty) {
          errors.add('${f.name}: 空文件');
          continue;
        }
        final text = utf8.decode(bytes, allowMalformed: true);
        final name = _stripExt(f.name);
        final (success, message) =
            await XbpqService.instance.importRule(name: name, text: text);
        if (success) {
          ok++;
        } else {
          errors.add('${f.name}: $message');
        }
      }

      if (ok > 0) await ApiConfig.instance.reloadLocalVideoSources();
      if (mounted) setState(() {});
      if (ok > 0) {
        final tail = errors.isEmpty ? '' : '，失败 ${errors.length} 个';
        AppToast.message('已导入 $ok 条规则$tail');
        if (errors.isNotEmpty) {
          AppLog.instance.w('[Xbpq] 文件导入失败项: ${errors.join(" | ")}');
        }
      } else {
        AppToast.error(errors.isEmpty ? '没有可导入的规则' : errors.first);
      }
    } catch (e) {
      AppToast.error('导入失败：$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importOne({required String name, required String text}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // 先自己解析一次，只为了拿默认名；`importRule` 内部还会再解析一次并做校验。
      final rule = XbpqRule.parse(text);
      final display = name.trim().isNotEmpty ? name.trim() : _hostName(rule);
      final (ok, message) = await XbpqService.instance.importRule(
        name: display,
        text: text,
      );
      if (!ok) {
        AppToast.error(message);
        return;
      }
      await ApiConfig.instance.reloadLocalVideoSources();
      if (mounted) setState(() {});
      AppToast.message(message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 规则没给名字时，用主页域名当名称（`a.com`），比「XBPQ 源 1」有辨识度。
  static String _hostName(XbpqRule? rule) {
    final url = rule?.homeUrl ?? '';
    final host = Uri.tryParse(url)?.host ?? '';
    return host.isEmpty ? 'XBPQ 源' : host;
  }

  static String _stripExt(String name) {
    final i = name.lastIndexOf('.');
    if (i <= 0) return name;
    return name.substring(0, i);
  }

  // ============================================================
  // 单条操作
  // ============================================================

  Future<void> _select(XbpqEntry entry) async {
    final beans = XbpqService.instance.sourceBeans;
    final hit = beans.where((b) => b.key == entry.key);
    if (hit.isEmpty) {
      AppToast.error('这条规则已失效，请重新导入');
      return;
    }
    // XBPQ 源没有独立子开关，跟着「本地爬虫」总开关走 —— 不打开的话
    // 主页源会被订阅线路覆盖（与 PY / JS 源的处理一致）。
    if (!ApiConfig.instance.localSourcesEnabled.value) {
      await ApiConfig.instance.setLocalSourcesEnabled(true);
    }
    await ApiConfig.instance.setHomeSource(hit.first);
    if (mounted) setState(() {});
    AppToast.message('已切换到「${entry.name}」');
  }

  Future<void> _rename(XbpqEntry entry) async {
    final name = await SettingsDialogs.editText(
      context: context,
      title: '重命名',
      initial: entry.name,
      hint: '显示名称',
      helper: '改名不影响已导入的规则内容，也不会换 key。',
    );
    if (name == null || name.trim().isEmpty) return;
    final (ok, message) = await XbpqService.instance.rename(entry.key, name);
    if (!ok) {
      AppToast.error(message.isEmpty ? '改名失败' : message);
      return;
    }
    // 显示名变了 → 源列表里那一项的 name 也要跟着变。
    await ApiConfig.instance.reloadLocalVideoSources();
    if (mounted) setState(() {});
  }

  Future<void> _share(XbpqEntry entry) async {
    await Clipboard.setData(ClipboardData(text: entry.ruleText));
    AppToast.message('规则内容已复制到剪贴板');
  }

  Future<void> _delete(XbpqEntry entry) async {
    final ok = await SettingsDialogs.confirm(
      context: context,
      title: '删除规则？',
      message: '将删除「${entry.name}」的规则，不可恢复。',
      confirmText: '删除',
    );
    if (!ok) return;
    await XbpqService.instance.remove(entry.key);
    await _afterChange();
    AppToast.message('已删除');
  }

  Future<void> _clearAll() async {
    final total = XbpqService.instance.count;
    if (total == 0) return;
    final ok = await SettingsDialogs.confirm(
      context: context,
      title: '清空全部？',
      message: '将删除全部 $total 条 XBPQ 规则，不可恢复。',
      confirmText: '清空',
    );
    if (!ok) return;
    final n = await XbpqService.instance.clearAll();
    await _afterChange();
    AppToast.message('已清空 $n 条规则');
  }

  /// 规则清单变了 → 让 `ApiConfig` 重新汇总本地源列表。
  ///
  /// 如果删掉的正是当前主页源，`reloadLocalVideoSources` 内部会把主页源
  /// 回退到别的可用源（与 PY / JS 源同一套逻辑，这里不用重复处理）。
  Future<void> _afterChange() async {
    await ApiConfig.instance.reloadLocalVideoSources();
    if (mounted) setState(() {});
  }

  Future<void> _showCardMenu(XbpqEntry entry) async {
    await showCardActions(
      context,
      title: entry.name,
      subtitle: 'XBPQ 规则 · ${entry.rule?.fields.length ?? 0} 个字段',
      actions: [
        CardAction(
          icon: Icons.play_circle_outline_rounded,
          label: '设为当前',
          onTap: () => _select(entry),
        ),
        CardAction(
          icon: Icons.drive_file_rename_outline,
          label: '改名',
          onTap: () => _rename(entry),
        ),
        CardAction(
          icon: Icons.ios_share_rounded,
          label: '分享',
          onTap: () => _share(entry),
        ),
        CardAction(
          icon: Icons.delete_outline_rounded,
          label: '删除',
          danger: true,
          onTap: () => _delete(entry),
        ),
      ],
    );
  }

  // ============================================================
  // UI
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final currentKey = ApiConfig.instance.homeSourceBean.value?.key;
    final all = XbpqService.instance.entries;

    return SettingsSubPage(
      title: 'XBPQ 规则源',
      children: [
        SettingsGroup(
          children: [
            SettingsRow(
              icon: Icons.add_circle_outline_rounded,
              title: '粘贴规则',
              value: _busy ? '处理中…' : '贴 JSON 文本',
              onTap: _busy ? () {} : _importPaste,
            ),
            SettingsRow(
              icon: Icons.file_open_outlined,
              title: '从文件导入',
              value: _busy ? '处理中…' : '.json / .txt，可多选',
              onTap: _busy ? () {} : _importFiles,
            ),
          ],
        ),
        const SizedBox(height: AppTheme.spacingXXL),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'XBPQ 规则源由 App 内置的 Dart 引擎直接按规则抓站解析，'
            '不需要 Node / Python 运行时。规则只存本地，与订阅线路分开保存，'
            '切换订阅不会丢。',
            style: TextStyle(
              fontSize: AppTheme.fontCaption,
              color: AppTheme.textTertiary,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: AppTheme.spacingMD),
        if (all.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              decoration: BoxDecoration(
                color: AppTheme.backgroundSecondary,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.rule_rounded,
                    size: 40,
                    color: AppTheme.textTertiary,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '还没有 XBPQ 规则源',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '点上面的「粘贴规则」贴一段规则 JSON',
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontFootnote,
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _importPaste,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    label: const Text('粘贴规则'),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accentColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
        else ...[
          Row(
            children: [
              Text(
                '已导入（${all.length}）',
                style: TextStyle(
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: _clearAll,
                child: const Text(
                  '清空',
                  style: TextStyle(
                    fontSize: AppTheme.fontSubhead,
                    color: Colors.redAccent,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ...all.map((e) => _row(e, currentKey: currentKey)),
          const SizedBox(height: AppTheme.spacingXXL),
        ],
      ],
    );
  }

  Widget _row(XbpqEntry entry, {required String? currentKey}) {
    final isCurrent = entry.key == currentKey;
    final rule = entry.rule;
    final host = Uri.tryParse(rule?.homeUrl ?? '')?.host ?? '';
    final detail =
        host.isEmpty ? entry.key : '$host · ${rule?.fields.length ?? 0} 个字段';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: AppTheme.backgroundSecondary,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _select(entry),
          onLongPress: () => _showCardMenu(entry),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
            child: Row(
              children: [
                Icon(
                  Icons.rule_rounded,
                  size: 22,
                  color: isCurrent ? AppTheme.accentColor : AppTheme.textSecondary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        entry.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTheme.fontHeadline,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isCurrent ? '当前主页源' : detail,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: AppTheme.fontFootnote,
                          color: isCurrent
                              ? AppTheme.accentColor
                              : AppTheme.textTertiary,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isCurrent)
                  Icon(
                    Icons.check_circle_rounded,
                    size: 18,
                    color: AppTheme.accentColor,
                  ),
                PopupMenuButton<String>(
                  icon: Icon(
                    Icons.more_vert_rounded,
                    size: 20,
                    color: AppTheme.textTertiary,
                  ),
                  onSelected: (v) {
                    switch (v) {
                      case 'rename':
                        _rename(entry);
                      case 'share':
                        _share(entry);
                      case 'delete':
                        _delete(entry);
                    }
                  },
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'rename', child: Text('重命名')),
                    PopupMenuItem(value: 'share', child: Text('分享')),
                    PopupMenuItem(value: 'delete', child: Text('删除')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
