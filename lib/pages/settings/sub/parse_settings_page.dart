// lib/pages/settings/sub/parse_settings_page.dart
//
// 设置 → 订阅管理 → 解析线路管理。
//
// ── 解决什么（用户 2026-10-14）────────────────────────────────
// 解析线路（TVBox 配置的 `parses`）以前是「订阅里有什么就是什么」：换一个不带
// parses 的订阅 → 整表清空，之前拉到的线路全没了，播放器底栏的「解析」按钮
// 也就没线路可切。
// 现在线路落在 [ParseStore]（prefs + Documents 文件备份）：
//   · 这里能看到**全部**线路（历次订阅下发的 + 手动添加的），换订阅不消失；
//   · 点一行 = 选为**当前解析线路**（播放器底栏「解析」按钮切的就是它；
//     「自动」= 按列表顺序依次尝试，命中即用）；
//   · 可删除、可手动添加。

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../models/app_config.dart';
import '../../../services/api_config.dart';
import '../../../services/parse_store.dart';
import '../../../widgets/common_widgets.dart';
import 'settings_shared.dart';

class ParseSettingsPage extends StatefulWidget {
  const ParseSettingsPage({super.key});

  @override
  State<ParseSettingsPage> createState() => _ParseSettingsPageState();
}

class _ParseSettingsPageState extends State<ParseSettingsPage> {
  /// 列表与选中态的唯一事实来源是 ParseStore；改完把它灌回 ApiConfig 的 Rx，
  /// 订阅管理页的条数、播放器弹层才会同步。
  Future<void> _sync() async {
    ApiConfig.instance.parseBeanList.value = ParseStore.instance.list;
    if (mounted) setState(() {});
  }

  Future<void> _selectAuto() async {
    await ParseStore.instance.setActive('');
    await _sync();
  }

  Future<void> _select(ParseBean b) async {
    await ParseStore.instance.setActive(b.url);
    await _sync();
  }

  Future<void> _remove(ParseBean b) async {
    final label = b.name.trim().isEmpty ? b.url : '${b.name}\n${b.url}';
    final ok = await SettingsDialogs.confirm(
      context: context,
      title: '删除解析线路',
      message: '$label\n\n删除后从解析列表移除（点「自动」仍会尝试剩下的线路）。',
    );
    if (!ok) return;
    await ParseStore.instance.remove(b.url);
    await _sync();
  }

  Future<void> _add() async {
    final name = await SettingsDialogs.editText(
      context: context,
      title: '线路名称',
      initial: '',
      hint: '如：量子解析',
    );
    if (name == null || name.trim().isEmpty) return;
    if (!mounted) return;
    final url = await SettingsDialogs.editText(
      context: context,
      title: '线路地址',
      initial: '',
      hint: 'https://…/jx?url=',
      helper: '支持 {url} 占位符 / url= 参数 / 直接拼接（与 TVBox 一致）',
    );
    if (url == null || url.trim().isEmpty) return;
    await ParseStore.instance.addOrUpdate(ParseBean(
      name: name.trim(),
      url: url.trim(),
      type: 1,
    ));
    await _sync();
  }

  @override
  Widget build(BuildContext context) {
    final lines = ApiConfig.instance.parseBeanList;
    final active = ParseStore.instance.activeUrl;
    return SettingsSubPage(
      title: '解析线路管理',
      action: IconButton(
        icon: Icon(Icons.add, color: AppTheme.textPrimary),
        onPressed: _add,
      ),
      children: [
        SettingsGroup(
          title: '当前解析线路',
          hint: '播放器底栏「解析」按钮切换的就是这里选中的线路。'
              '「自动」= 按下面列表顺序依次尝试，命中即用。',
          children: [
            SettingsRow(
              icon: Icons.auto_awesome,
              title: '自动（按顺序尝试）',
              value: active.isEmpty ? '使用中' : '',
              titleColor: active.isEmpty ? AppTheme.accentColor : null,
              onTap: _selectAuto,
            ),
          ],
        ),
        const SizedBox(height: AppTheme.spacingXXL),
        SettingsGroup(
          title: '全部线路（${lines.length}）',
          hint: lines.isEmpty
              ? '还没有解析线路。带 parses 的订阅加载时会自动并入这里；'
                  '也可以点右上角「+」手动添加。'
              : '订阅下发的线路只并入、不清空 —— 换订阅也不会丢。',
          children: [
            for (final b in lines)
              SettingsRow(
                icon: Icons.link_rounded,
                iconColor: active == b.url
                    ? AppTheme.accentColor
                    : AppTheme.textTertiary,
                title: b.name.trim().isEmpty ? b.url : b.name,
                subtitle: '${b.type == 1 ? '解析' : '嗅探'} · ${b.url}',
                titleColor: active == b.url ? AppTheme.accentColor : null,
                onTap: () => _select(b),
                trailing: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _remove(b),
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.delete_outline,
                        size: 18, color: Colors.redAccent),
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
