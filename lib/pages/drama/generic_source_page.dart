import 'package:flutter/material.dart';

import '../../common/theme.dart';
import '../../services/generic_source_service.dart';
import '../../widgets/app_toast.dart';

/// 「通用源」管理页（2026-10-22）。
///
/// 只收标准 MacCMS / TVBox JSON 接口：填域名或 `api.php/provide/vod/`
/// 地址即可，添加后与订阅线路同权（首页分类 / 搜索 / 短剧聚合）。
class GenericSourcePage extends StatefulWidget {
  const GenericSourcePage({super.key});

  @override
  State<GenericSourcePage> createState() => _GenericSourcePageState();
}

class _GenericSourcePageState extends State<GenericSourcePage> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await GenericSourceService.instance.list();
    if (!mounted) return;
    setState(() {
      _items = list;
      _loading = false;
    });
  }

  Future<void> _add() async {
    final nameC = TextEditingController();
    final urlC = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('添加通用源'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameC,
              decoration: const InputDecoration(
                labelText: '名称（可留空）',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: urlC,
              decoration: const InputDecoration(
                labelText: '站点域名 / 接口地址',
                hintText: 'https://example.com 或 …/api.php/provide/vod/',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '只支持标准 MacCMS JSON 接口；私有签名站（红果等）不支持。',
              style: TextStyle(
                fontSize: AppTheme.fontCaption,
                height: 1.4,
                color: AppTheme.textTertiary,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('添加'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    AppToast.message('正在检测接口…');
    final r = await GenericSourceService.instance.add(
      name: nameC.text,
      input: urlC.text,
    );
    AppToast.message(r.message);
    if (r.ok) {
      await _load();
    }
  }

  Future<void> _remove(Map<String, dynamic> item) async {
    final name = (item['name'] ?? '').toString();
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除通用源'),
        content: Text('确定删除「$name」？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await GenericSourceService.instance.remove(
      (item['key'] ?? '').toString(),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        title: const Text('通用源'),
        actions: [
          IconButton(
            tooltip: '添加',
            icon: const Icon(Icons.add_rounded),
            onPressed: _add,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppTheme.backgroundSecondary,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppTheme.borderLight,
                      width: 0.5,
                    ),
                  ),
                  child: Text(
                    '支持标准苹果 CMS（MacCMS）与 TVBox JSON 接口：\n'
                    '填站点域名会自动尝试 /api.php/provide/vod/。\n'
                    '添加后可直接参与「短剧」聚合，也能在首页切换源里选到。',
                    style: TextStyle(
                      fontSize: AppTheme.fontCaption,
                      height: 1.6,
                      color: AppTheme.textTertiary,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                if (_items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 60),
                    child: Column(
                      children: [
                        Icon(Icons.dns_outlined,
                            size: 44,
                            color: AppTheme.textTertiary
                                .withValues(alpha: 0.5)),
                        const SizedBox(height: 12),
                        Text(
                          '还没有添加通用源',
                          style: TextStyle(color: AppTheme.textTertiary),
                        ),
                      ],
                    ),
                  )
                else
                  for (final it in _items)
                    Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: AppTheme.backgroundSecondary,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: AppTheme.borderLight,
                          width: 0.5,
                        ),
                      ),
                      child: ListTile(
                        title: Text(
                          (it['name'] ?? '').toString(),
                          style: TextStyle(
                            fontSize: AppTheme.fontSubhead,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        subtitle: Text(
                          (it['api'] ?? '').toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: AppTheme.fontCaption,
                            color: AppTheme.textTertiary,
                          ),
                        ),
                        trailing: IconButton(
                          tooltip: '删除',
                          icon: Icon(Icons.delete_outline_rounded,
                              color: AppTheme.textTertiary),
                          onPressed: () => _remove(it),
                        ),
                      ),
                    ),
              ],
            ),
    );
  }
}
