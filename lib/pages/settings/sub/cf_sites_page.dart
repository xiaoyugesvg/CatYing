import 'package:flutter/material.dart';

import '../../../services/cf_session.dart';
import '../../cf_verify_page.dart';

/// 「Cloudflare 站点验证」管理页。
///
/// 作用：把"点一次、以后不再点"的体验变成可见、可控的入口。
///   · 列出已验证的站点 + 验证时间（用户能确认"确实记住了"）；
///   · 可手动补验证某个站点（常用于"某个源一直 403"）；
///   · 可单独删除 / 全部清除（换 IP、Cookie 失效时用）。
class CfSitesPage extends StatefulWidget {
  const CfSitesPage({super.key});

  @override
  State<CfSitesPage> createState() => _CfSitesPageState();
}

class _CfSitesPageState extends State<CfSitesPage> {
  List<String> _hosts = const [];
  final Map<String, DateTime?> _times = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final hosts = await CfSession.instance.hosts();
    final times = <String, DateTime?>{};
    for (final h in hosts) {
      times[h] = await CfSession.instance.savedAt(h);
    }
    if (!mounted) return;
    setState(() {
      _hosts = hosts;
      _times
        ..clear()
        ..addAll(times);
      _loading = false;
    });
  }

  String _ago(DateTime? t) {
    if (t == null) return '已验证';
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚验证';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    if (d.inDays < 1) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  Future<void> _add() async {
    final ctrl = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('要验证哪个站点？'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            hintText: '如 missav.ws 或 https://xxx.com',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(c, ctrl.text.trim()),
            child: const Text('去验证'),
          ),
        ],
      ),
    );
    if (input == null || input.isEmpty || !mounted) return;
    final host = CfSession.hostOf(input);
    if (host.isEmpty) return;
    await _verify(host);
  }

  Future<void> _verify(String host) async {
    final ok = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => CfVerifyPage(url: 'https://$host/', host: host),
      ),
    );
    if (ok == true) await _reload();
  }

  Future<void> _remove(String host) async {
    await CfSession.instance.invalidate(host);
    await _reload();
  }

  Future<void> _clearAll() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('清除全部验证'),
        content: const Text('清除后，下次访问需要重新点一次验证。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('清除')),
        ],
      ),
    );
    if (yes != true) return;
    await CfSession.instance.clearAll();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloudflare 验证'),
        actions: [
          if (_hosts.isNotEmpty)
            IconButton(
              tooltip: '清除全部',
              onPressed: _clearAll,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _add,
        icon: const Icon(Icons.add),
        label: const Text('添加站点'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Text(
                      '这些站点已经完成过人机验证，之后所有模块（视频源 / 网页 / 图片）'
                      '都会自动复用，不会再反复要求你操作。\n\n'
                      '如果某个站点又开始 403，说明验证过期，重新验证一次即可。',
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.55,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                if (_hosts.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 40),
                    child: Center(
                      child: Text(
                        '还没有验证过任何站点',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                for (final h in _hosts)
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.verified_user_outlined),
                      title: Text(h),
                      subtitle: Text(_ago(_times[h])),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          TextButton(
                            onPressed: () => _verify(h),
                            child: const Text('重新验证'),
                          ),
                          IconButton(
                            tooltip: '删除',
                            onPressed: () => _remove(h),
                            icon: const Icon(Icons.close, size: 18),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
