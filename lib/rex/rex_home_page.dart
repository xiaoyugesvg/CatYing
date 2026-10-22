import 'package:flutter/material.dart';

import '../common/theme.dart';
import 'rex_import.dart';
import 'rex_manage_page.dart';
import 'rex_models.dart';
import 'rex_module_page.dart';
import 'rex_service.dart';

/// 「REX」模块首页：只展示启用中的模块。
///
/// 底栏里的「REX」tab（默认开启，可在「设置 → 主页页面」关闭）。
/// 导入 / 启停 / 排序 / 改地址 / 删除统一放在「REX 订阅管理」页。
class RexHomePage extends StatefulWidget {
  const RexHomePage({super.key});

  @override
  State<RexHomePage> createState() => _RexHomePageState();
}

class _RexHomePageState extends State<RexHomePage> {
  final _service = RexService.instance;

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
            tooltip: 'REX 订阅管理',
            icon: Icon(Icons.tune_rounded, color: _fg),
            onPressed: _openManage,
          ),
          IconButton(
            tooltip: '导入模块',
            icon: Icon(Icons.add_link_rounded, color: _fg),
            onPressed: () => showRexImportDialog(context),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ValueListenableBuilder<int>(
        valueListenable: _service.revision,
        builder: (context, _, __) {
          final list = _service.enabledModules;
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

  Future<void> _openManage() async {
    await Navigator.of(context).push(MaterialPageRoute(
      settings: const RouteSettings(name: 'rex:manage'),
      builder: (_) => const RexManagePage(),
    ));
    if (mounted) setState(() {});
  }

  Widget _empty() {
    final all = _service.modules;
    final allDisabled = all.isNotEmpty;
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(36, 0, 36, 80),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.extension_outlined,
                size: 38, color: _sub.withValues(alpha: 0.6)),
            const SizedBox(height: 12),
            Text(allDisabled ? '模块都被停用了' : '还没有 REX 模块',
                style: TextStyle(
                    color: _fg,
                    fontSize: AppTheme.fontHeadline,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              allDisabled
                  ? '去「REX 订阅管理」把要用的模块打开。'
                  : '右上角「导入模块」可以粘贴：\n'
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
              onPressed: allDisabled
                  ? _openManage
                  : () => showRexImportDialog(context),
              icon: Icon(
                  allDisabled
                      ? Icons.tune_rounded
                      : Icons.add_link_rounded,
                  size: 18),
              label: Text(allDisabled ? '打开订阅管理' : '导入模块'),
            ),
          ],
        ),
      ),
    );
  }

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
