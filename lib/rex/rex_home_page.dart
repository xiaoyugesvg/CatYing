import 'package:flutter/material.dart';

import '../common/theme.dart';
import '../widgets/app_toast.dart';
import 'rex_models.dart';
import 'rex_module_page.dart';
import 'rex_service.dart';

/// 「REX」模块首页：导入 / 管理 ForwardWidget 模块。
///
/// 底栏里的「REX」tab（默认不启用，用户在「设置 → 主页页面」打开）。
/// 支持粘贴：
///   · 单个模块 raw 地址（返回 JS 的地址）
///   · `.rex` 集合地址（`widgets[]` 会被自动展开成多个模块）
class RexHomePage extends StatefulWidget {
  const RexHomePage({super.key});

  @override
  State<RexHomePage> createState() => _RexHomePageState();
}

class _RexHomePageState extends State<RexHomePage> {
  final _service = RexService.instance;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _service.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  bool get _isDark => Theme.of(context).brightness == Brightness.dark;
  Color get _fg => _isDark ? Colors.white : AppTheme.textPrimary;
  Color get _sub => _isDark ? Colors.white60 : Colors.black54;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        title: Text('REX',
            style: TextStyle(
                fontSize: AppTheme.fontHeadline,
                fontWeight: FontWeight.w600,
                color: _fg)),
        actions: [
          IconButton(
            tooltip: '导入模块',
            icon: Icon(Icons.add_link_rounded, color: _fg),
            onPressed: _busy ? null : _showImport,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: _service.revision,
        builder: (context, _, __) {
          final list = _service.modules;
          if (list.isEmpty) return _empty();
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 120),
            itemCount: list.length + 1,
            itemBuilder: (context, i) {
              if (i == list.length) {
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '模块来自第三方 JS，执行在 Node 沙箱里；'
                    '解析失败时先检查模块地址是否仍可访问。',
                    style: TextStyle(
                        color: _sub,
                        fontSize: AppTheme.fontCaption,
                        height: 1.5),
                  ),
                );
              }
              return _moduleCard(list[i]);
            },
          );
        },
      ),
    );
  }

  Widget _empty() => Center(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(36, 0, 36, 80),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.extension_outlined,
                  size: 38, color: _sub.withValues(alpha: 0.6)),
              const SizedBox(height: 12),
              Text('还没有 REX 模块',
                  style: TextStyle(
                      color: _fg,
                      fontSize: AppTheme.fontHeadline,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text(
                '右上角「导入模块」可以粘贴：\n'
                '· 单个模块地址（返回 JS）\n'
                '· .rex 集合地址（会自动展开里面的模块）',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: _sub, fontSize: AppTheme.fontFootnote, height: 1.7),
              ),
              const SizedBox(height: 18),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: AppTheme.accentColor,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 42),
                ),
                onPressed: _busy ? null : _showImport,
                icon: const Icon(Icons.add_link_rounded, size: 18),
                label: Text(_busy ? '导入中…' : '导入模块'),
              ),
            ],
          ),
        ),
      );

  Widget _moduleCard(RexModule m) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).push(MaterialPageRoute(
        settings: const RouteSettings(name: 'rex:module'),
        builder: (_) => RexModulePage(module: m),
      )),
      onLongPress: () => _confirmRemove(m),
      child: Container(
        margin: const EdgeInsets.only(top: 10),
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: _isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusCard),
          border: Border.all(
              color: _isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.06),
              width: 0.8),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.accentColor.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(Icons.extension_rounded,
                  size: 20, color: AppTheme.accentColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(m.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: _fg,
                                fontSize: AppTheme.fontHeadline,
                                fontWeight: FontWeight.w600)),
                      ),
                      if (m.version.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Text('v${m.version}',
                            style: TextStyle(
                                color: _sub,
                                fontSize: AppTheme.fontCaption)),
                      ],
                    ],
                  ),
                  if (m.description.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(m.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: _sub,
                            fontSize: AppTheme.fontFootnote,
                            height: 1.35)),
                  ],
                  const SizedBox(height: 5),
                  Text(
                    '${m.listFunctions.length} 个分类'
                    '${m.canSearch ? ' · 可搜索' : ''}'
                    '${m.canPlay ? ' · 可播放' : ''}'
                    '${m.author.isNotEmpty ? ' · ${m.author}' : ''}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: _sub, fontSize: AppTheme.fontCaption),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: _sub),
          ],
        ),
      ),
    );
  }

  Future<void> _showImport() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入 REX 模块'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              maxLines: 3,
              minLines: 1,
              decoration: const InputDecoration(
                hintText: 'https://…/api/modules/<id>/raw\n或 https://…/api/collections/xxx.rex',
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '支持单个模块地址或 .rex 集合；集合会一次导入里面的所有模块。',
              style: TextStyle(
                  fontSize: AppTheme.fontCaption,
                  color: Theme.of(ctx).brightness == Brightness.dark
                      ? Colors.white54
                      : Colors.black54,
                  height: 1.5),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('导入')),
        ],
      ),
    );
    if (ok != true || !mounted) {
      ctrl.dispose();
      return;
    }
    final input = ctrl.text;
    ctrl.dispose();
    await _import(input);
  }

  Future<void> _import(String input) async {
    setState(() => _busy = true);
    try {
      final loaded = await _service.importFrom(input);
      await _service.addAll(loaded);
      if (!mounted) return;
      AppToast.show(
        loaded.length == 1 ? '已导入「${loaded.first.title}」' : '已导入 ${loaded.length} 个模块',
        '',
      );
    } catch (e) {
      if (mounted) AppToast.show('$e', '');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _confirmRemove(RexModule m) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除模块？'),
        content: Text('「${m.title}」会从列表移除（不影响本地其他数据）。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              child: const Text('移除')),
        ],
      ),
    );
    if (ok == true) await _service.remove(m.url);
  }
}
