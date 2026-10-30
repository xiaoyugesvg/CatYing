import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/parse_lines.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';

/// 「解析线路」管理页。
///
/// 只做三件事：**选一条**（或自动）、**加/改自定义线路**、**删自定义线路**。
/// 订阅线路是只读的 —— 它来自影视配置的 `parses`，改了也会被下次刷新覆盖。
class ParseLinesPage extends StatefulWidget {
  const ParseLinesPage({super.key});

  @override
  State<ParseLinesPage> createState() => _ParseLinesPageState();
}

class _ParseLinesPageState extends State<ParseLinesPage> {
  final _store = ParseLineStore.instance;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _store.addListener(_onChanged);
    _refreshFromConfig();
  }

  @override
  void dispose() {
    _store.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// 从当前影视配置拉一次 `parses`（失败就用已有的）
  ///
  /// 走 [ParseLineStore.refreshFromConfig]：它会把失败原因记进
  /// `store.syncError`，页面底部据此显示"为什么 0 条"，
  /// 而不是让用户对着一片空白猜。
  Future<void> _refreshFromConfig() async {
    setState(() => _loading = true);
    try {
      await _store.refreshFromConfig();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit({ParseLine? line}) async {
    final nameCtrl = TextEditingController(text: line?.name ?? '');
    final urlCtrl = TextEditingController(text: line?.url ?? '');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          line == null ? '新增解析线路' : '修改解析线路',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              decoration: const InputDecoration(
                labelText: '名称',
                hintText: '例如：解析一',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: urlCtrl,
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
              decoration: const InputDecoration(
                labelText: '地址模板',
                hintText: 'https://jiexi.xx/?url={url}',
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '模板里写 {url} 表示把原始播放地址编码后填进去；'
              '不写则直接拼在模板末尾。',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
                height: 1.4,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (urlCtrl.text.trim().isEmpty) {
      AppToast.error('地址模板不能为空');
      return;
    }
    if (line == null) {
      await _store.addCustom(nameCtrl.text, urlCtrl.text);
    } else {
      await _store.updateCustom(line.id, nameCtrl.text, urlCtrl.text);
    }
  }

  Future<void> _delete(ParseLine line) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text(
          '删除线路',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontHeadline,
          ),
        ),
        content: Text(
          '确定删除「${line.name}」吗？',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok == true) await _store.removeCustom(line.id);
  }

  @override
  Widget build(BuildContext context) {
    final sub = _store.subscriptionLines;
    final custom = _store.customLines;
    return SettingsSubPage(
      title: '解析线路',
      help: const [
        SettingsHelpItem(
          icon: Icons.auto_mode_rounded,
          title: '方式一：自动（推荐）',
          body: '按下面列表的顺序一条条试，直到解析出真正的媒体地址。'
              '某条挂了会自动跳下一条，是日常最省心的选法。',
        ),
        SettingsHelpItem(
          icon: Icons.rss_feed,
          title: '方式二：订阅线路',
          body: '来自影视配置里的 parses，随订阅一起下发，**只读** —— '
              '改了也会被下次刷新覆盖。源作者维护得好的话，这条最不容易失效。',
        ),
        SettingsHelpItem(
          icon: Icons.edit_note_rounded,
          title: '方式三：自定义线路',
          body: '自己加一条：起个名字 + 填解析接口地址（支持带 ?url= 的模板）。'
              '加完会排在订阅线路之后参与「自动」；想固定用它就点一下选中。'
              '右上角「+」新增，长按或点进去可改可删。',
        ),
        SettingsHelpItem(
          icon: Icons.link_off_rounded,
          title: '解析失败是什么样',
          body: '点播放后一直转圈、或直接弹「解析失败」，通常是这条线路挂了。'
              '切「自动」再试，或在列表里换一条；'
              '全都失败说明这个源的播放地址需要登录/付费，换源更快。',
        ),
      ],
      action: IconButton(
        tooltip: '新增',
        icon: Icon(Icons.add_rounded, color: AppTheme.textSecondary),
        onPressed: () => _edit(),
      ),
      children: [
        if (_loading)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
        SettingsGroup(
          title: '使用哪条',
          hint: '选「自动」时按下面的顺序依次尝试，直到解析出媒体地址。',
          children: [
            _row(
              title: '自动',
              subtitle: '按顺序全部试一遍（推荐）',
              selected: _store.selectedId.isEmpty,
              onTap: () => _store.setSelected(''),
            ),
          ],
        ),
        if (sub.isNotEmpty)
          SettingsGroup(
            title: '订阅线路（${sub.length}）',
            children: [
              for (final l in sub)
                _row(
                  title: l.name,
                  subtitle: l.url,
                  selected: _store.selectedId == l.id,
                  onTap: () => _store.setSelected(l.id),
                ),
            ],
          ),
        // ── 订阅线路为空时**必须说清原因**（2026-10-30）──────────────
        //
        // 用户截图里这一组直接不出现，只剩「自动」一条 —— 看起来像
        // "解析线路根本没导入"。真实原因是线路**懒同步**（见
        // `ParseLineStore.ensureSyncedFromConfig`）：没同步过就是 0 条。
        // 现在空着也把这组画出来，并给一个「重新读取」入口。
        if (sub.isEmpty)
          SettingsGroup(
            title: '订阅线路（0）',
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _loading ? null : _refreshFromConfig,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                  child: Row(
                    children: [
                      Icon(
                        _store.syncError.isEmpty
                            ? Icons.cloud_sync_outlined
                            : Icons.error_outline_rounded,
                        size: 18,
                        color: _store.syncError.isEmpty
                            ? AppTheme.textSecondary
                            : AppTheme.accentColor,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _store.syncError.isNotEmpty
                              ? '读取订阅配置失败，点这里重试'
                              : '当前订阅里没有 parses，点这里重新读取',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: AppTheme.fontSubhead,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        SettingsGroup(
          title: '自定义线路（${custom.length}）',
          children: [
            for (final l in custom)
              _row(
                title: l.name,
                subtitle: l.url,
                selected: _store.selectedId == l.id,
                onTap: () => _store.setSelected(l.id),
                onLongPress: () => _customActions(l),
                trailing: _store.selectedId == l.id
                    ? Icon(Icons.check_rounded,
                        color: AppTheme.accentColor, size: 18)
                    : null,
              ),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _edit(),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Row(
                  children: [
                    Icon(Icons.add_circle_outline_rounded,
                        size: 18, color: AppTheme.accentColor),
                    const SizedBox(width: 10),
                    Text(
                      '新增自定义线路',
                      style: TextStyle(
                        color: AppTheme.accentColor,
                        fontSize: AppTheme.fontSubhead,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _customActions(ParseLine line) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('修改'),
              onTap: () => Navigator.pop(ctx, 'edit'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded),
              title: const Text('删除'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'edit') {
      await _edit(line: line);
    } else if (action == 'delete') {
      await _delete(line);
    }
  }

  Widget _row({
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    Widget? trailing,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
        child: Row(
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 17,
              color: selected ? AppTheme.accentColor : AppTheme.textTertiary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
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
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }
}
