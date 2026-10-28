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

import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/app_config.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/parse_service.dart';
import 'package:tvbox/services/parse_store.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';

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
    // 线路被增删改（含改请求头/类型）→ 清解析缓存，保证"改完立即生效"；
    // 否则 10 分钟缓存内仍然用旧接口/旧 header 的结果（2026-10-15 深挖）。
    ParseService.instance.clearCache();
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

  /// 启用 / 禁用线路（禁用当前选中项时选中自动回"自动"）
  Future<void> _toggleEnabled(ParseBean b, bool value) async {
    await ParseStore.instance.setEnabled(b.url, value);
    await _sync();
  }

  /// 上移 / 下移线路（调整"优先顺序"，自动模式按顺序依次尝试）
  Future<void> _move(ParseBean b, int delta) async {
    await ParseStore.instance.move(b.url, delta);
    await _sync();
  }

  /// 线路地址必须 http(s) 开头（huoyi 同款校验）：
  /// 没有 scheme 的"地址"发请求必失败，存进去只是占一行，还干扰自动尝试。
  bool _validHttpUrl(String url) {
    final u = url.trim();
    return u.isNotEmpty &&
        (u.startsWith('http://') || u.startsWith('https://'));
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
      helper: '支持 {url} 占位符 / url= 参数 / 直接拼接（与 TVBox 一致）。'
          '地址需以 http:// 或 https:// 开头。',
    );
    if (url == null || url.trim().isEmpty) return;
    if (!_validHttpUrl(url)) {
      AppToast.message('线路地址需以 http:// 或 https:// 开头');
      return;
    }
    if (!mounted) return;
    final type = await _pickType(1);
    if (type == null) return;
    if (!mounted) return;
    final headerText = await _editHeaderText(const <String, String>{});
    if (headerText == null) return;

    await ParseStore.instance.addOrUpdate(ParseBean(
      name: name.trim(),
      url: url.trim(),
      type: type,
      ext: _extOf(_parseHeaders(headerText)),
    ));
    await _sync();
  }

  /// 编辑已有线路（名称 / 地址 / 类型 / 请求头）——订阅下发的线路也能改。
  Future<void> _edit(ParseBean b) async {
    final name = await SettingsDialogs.editText(
      context: context,
      title: '线路名称',
      initial: b.name,
      hint: '如：量子解析',
    );
    if (name == null) return;
    if (!mounted) return;
    final url = await SettingsDialogs.editText(
      context: context,
      title: '线路地址',
      initial: b.url,
      hint: 'https://…/jx?url=',
      helper: '支持 {url} 占位符 / url= 参数 / 直接拼接（与 TVBox 一致）。'
          '地址需以 http:// 或 https:// 开头。',
    );
    if (url == null || url.trim().isEmpty) return;
    if (!_validHttpUrl(url)) {
      AppToast.message('线路地址需以 http:// 或 https:// 开头');
      return;
    }
    if (!mounted) return;
    final type = await _pickType(b.type);
    if (type == null) return;
    if (!mounted) return;
    final headerText = await _editHeaderText(_headersOf(b));
    if (headerText == null) return;

    await ParseStore.instance.addOrUpdate(
      ParseBean(
        name: name.trim(),
        url: url.trim(),
        type: type,
        ext: _extOf(_parseHeaders(headerText)),
        enabled: b.enabled,
      ),
      originalUrl: b.url, // 改了地址时把旧那条摘掉
    );
    await _sync();
  }

  /// 选接口类型：1=解析（直接返回地址），0=嗅探（返回网页播放页）
  Future<int?> _pickType(int current) {
    return SettingsDialogs.pick<int>(
      context: context,
      title: '接口类型',
      options: const [1, 0],
      selected: current,
      labelBuilder: (t) =>
          t == 1 ? '解析（直接返回地址）' : '嗅探（返回网页播放页）',
    );
  }

  /// 请求头编辑弹层（每行一条 `名称: 值`）
  Future<String?> _editHeaderText(Map<String, String> headers) {
    final initial =
        headers.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    return SettingsDialogs.editText(
      context: context,
      title: '请求头（可选）',
      initial: initial,
      hint: 'User-Agent: Mozilla/5.0',
      maxLines: 6,
      helper: '每行一条 `名称: 值`，例如 Referer / User-Agent。\n'
          '有些解析站要求特定 UA / Referer 才返回结果。留空表示不带。',
    );
  }

  /// 文本 → 请求头 Map（每行 `Key: Value`）
  Map<String, String> _parseHeaders(String text) {
    final map = <String, String>{};
    for (final line in text.split(RegExp(r'[\r\n]+'))) {
      final t = line.trim();
      if (t.isEmpty) continue;
      final i = t.indexOf(':');
      if (i <= 0) continue;
      final k = t.substring(0, i).trim();
      final v = t.substring(i + 1).trim();
      if (k.isNotEmpty) map[k] = v;
    }
    return map;
  }

  /// 线路已配置的请求头（与 ParseService._headerOf 的存储格式一致）
  Map<String, String> _headersOf(ParseBean b) {
    final raw = b.ext?['header'];
    if (raw == null || raw.isEmpty) return const <String, String>{};
    try {
      final d = jsonDecode(raw);
      if (d is Map) {
        return d.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (_) {}
    return const <String, String>{};
  }

  /// 请求头 Map → ParseBean.ext（空则不写 ext）
  Map<String, String>? _extOf(Map<String, String> headers) =>
      headers.isEmpty ? null : {'header': jsonEncode(headers)};

  /// 行尾紧凑图标按钮（30×30 约束，tooltip 提示）
  Widget _compactIcon(
    IconData icon,
    String tooltip,
    VoidCallback onTap, {
    Color? color,
  }) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      icon: Icon(icon, size: 17, color: color ?? AppTheme.textTertiary),
      onPressed: onTap,
    );
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
              titleColor: active.isEmpty ? AppTheme.accentOnSurface : null,
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
                    ? AppTheme.accentOnSurface
                    : AppTheme.textTertiary,
                title: b.name.trim().isEmpty ? b.url : b.name,
                // 副标题保持简短（类型/请求头），url 太长会撑高行、挤压 trailing
                subtitle: '${b.type == 1 ? '解析' : '嗅探'}'
                    '${_headersOf(b).isNotEmpty ? ' · 带请求头' : ''}'
                    '${b.enabled ? '' : ' · 已禁用'}',
                titleColor: active == b.url ? AppTheme.accentOnSurface : null,
                // 行点击 = 选中当前线路；右侧开关 = 启用/禁用（huoyi 语义）
                trailingSwitch: true,
                switchValue: b.enabled,
                onSwitchChanged: (v) => _toggleEnabled(b, v),
                onTap: () => _select(b),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 上移/下移（调整优先顺序，huoyi 同款能力）
                    _compactIcon(
                      Icons.arrow_upward_rounded,
                      '上移',
                      () => _move(b, -1),
                    ),
                    _compactIcon(
                      Icons.arrow_downward_rounded,
                      '下移',
                      () => _move(b, 1),
                    ),
                    // 编辑（名称/地址/类型/请求头）——订阅下发的线路也能改
                    _compactIcon(
                      Icons.edit_outlined,
                      '编辑',
                      () => _edit(b),
                    ),
                    _compactIcon(
                      Icons.delete_outline,
                      '删除',
                      () => _remove(b),
                      color: Colors.redAccent,
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }
}
