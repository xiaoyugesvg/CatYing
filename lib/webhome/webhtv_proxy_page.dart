import 'package:flutter/material.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/reading/services/settings_service.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/widgets/app_toast.dart';

/// 「网络代理」（原 Webhtv → APP 代理）。
///
/// 入口现为「设置 → 通用设置 → 网络代理」（Webhtv 模块下线后搬过来的，
/// 用户 2026-10-16）。
///
/// 对齐 WebHomeTV 的「APP 代理」：**按域名匹配的代理规则**。
/// 全项目所有请求都走 `applyGlobalProxy`（27 处），所以这里只需要维护规则，
/// **不用改任何请求点**：
///   · 「只对规则里的域名走代理」**关**（默认）= 全部走代理 = 原行为不变
///   · **开** = 只有命中的域名走代理，其余直连
///
/// 代理地址 / 总开关本身仍在「通用设置 → 网络代理」里（那是既有入口，不重复造）。
///
/// 未接入：WebHomeTV 还有"按当前站点自动建议整片代理域名"，本版只做
/// **从当前影视源 / 当前网页源的建议**（一键加入），够用且不猜。
class WebhtvProxyPage extends StatefulWidget {
  const WebhtvProxyPage({super.key});

  @override
  State<WebhtvProxyPage> createState() => _WebhtvProxyPageState();
}

class _WebhtvProxyPageState extends State<WebhtvProxyPage> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  static String? _hostOf(String url) {
    final t = url.trim();
    if (t.isEmpty) return null;
    final u = Uri.tryParse(t.startsWith('http') ? t : 'https://$t');
    final h = u?.host ?? '';
    return h.isEmpty ? null : h;
  }

  /// 从"当前影视源 + 当前网页源"提取建议域名
  List<String> _suggestions() {
    final out = <String>[];
    void add(String? h) {
      if (h == null || h.isEmpty) return;
      if (out.contains(h)) return;
      out.add(h);
    }

    final api = ApiConfig.instance.sourceBeanList;
    final cur = ApiConfig.instance.homeSourceBean.value;
    if (cur != null) add(_hostOf(cur.api));
    for (final s in api.take(3)) {
      add(_hostOf(s.api));
    }
    final have = SettingsService().proxyDomainRules;
    return out
        .where((h) => !SettingsService.hostMatchesProxyRules(h, have))
        .toList();
  }

  Future<void> _add() async {
    final v = _ctrl.text.trim();
    if (v.isEmpty) return;
    final rules = [...SettingsService().proxyDomainRules, v];
    await SettingsService().setProxyDomainRules(rules);
    _ctrl.clear();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fg = isDark ? Colors.white : AppTheme.textPrimary;
    final sub = isDark
        ? Colors.white.withValues(alpha: 0.55)
        : AppTheme.textSecondary;
    final s = SettingsService();
    final rules = s.proxyDomainRules;
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleSpacing: 16,
        iconTheme: IconThemeData(color: fg),
        title: Text('APP 代理',
            style: TextStyle(
                color: fg,
                fontSize: AppTheme.fontTitle3,
                fontWeight: FontWeight.w600)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 28),
        children: [
          Text(
            '代理地址与总开关在「设置 → 通用设置 → 网络代理」；这里只管'
            '**哪些域名走代理**。',
            style:
                TextStyle(fontSize: AppTheme.fontCaption, color: sub, height: 1.5),
          ),
          const SizedBox(height: 4),
          Text(
            s.globalProxyEnabled
                ? '当前代理：${s.globalProxy.isEmpty ? "未填地址" : s.globalProxy}'
                : '当前：全局代理**未开启**（规则暂不生效）',
            style:
                TextStyle(fontSize: AppTheme.fontCaption, color: sub, height: 1.5),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : const Color(0xFFF4F5F7),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('只对规则里的域名走代理',
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead,
                              fontWeight: FontWeight.w600,
                              color: fg)),
                      const SizedBox(height: 2),
                      Text('关闭 = 全部走代理（默认，原行为）',
                          style: TextStyle(
                              fontSize: AppTheme.fontCaption, color: sub)),
                    ],
                  ),
                ),
                Switch(
                  value: s.proxyDomainOnly,
                  onChanged: (v) async {
                    await s.setProxyDomainOnly(v);
                    if (mounted) setState(() {});
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Text('域名规则（${rules.length}）',
                  style: TextStyle(
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                      color: fg)),
              const Spacer(),
              TextButton.icon(
                onPressed: () async {
                  final sug = _suggestions();
                  if (sug.isEmpty) {
                    AppToast.message('没有可建议的域名');
                    return;
                  }
                  await s.setProxyDomainRules([...rules, ...sug]);
                  if (mounted) {
                    setState(() {});
                    AppToast.message('已加入 ${sug.length} 条建议域名');
                  }
                },
                icon: Icon(Icons.auto_fix_high_rounded, size: 16, color: sub),
                label: Text('从当前源建议',
                    style: TextStyle(
                        fontSize: AppTheme.fontCaption, color: sub)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          if (rules.isEmpty)
            Text('还没有规则。可以手填 `*.example.com`，或点右上「从当前源建议」。',
                style: TextStyle(
                    fontSize: AppTheme.fontCaption, color: sub, height: 1.5))
          else
            for (final r in rules)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.06)
                      : const Color(0xFFF4F5F7),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(r,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: AppTheme.fontSubhead, color: fg)),
                    ),
                    IconButton(
                      tooltip: '删除',
                      onPressed: () async {
                        final list = List<String>.of(rules)..remove(r);
                        await s.setProxyDomainRules(list);
                        if (mounted) setState(() {});
                      },
                      icon: Icon(Icons.close_rounded, size: 18, color: sub),
                    ),
                  ],
                ),
              ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  style: TextStyle(fontSize: AppTheme.fontSubhead, color: fg),
                  onSubmitted: (_) => _add(),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '添加域名（如 *.example.com）',
                    hintStyle: TextStyle(
                        fontSize: AppTheme.fontSubhead, color: sub),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accentSurface,
                  foregroundColor: AppTheme.accentOnSurface,
                ),
                onPressed: _add,
                child: const Text('添加'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
