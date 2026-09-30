import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../services/rfw_theme_service.dart';
import '../../widgets/common_widgets.dart';

/// 首页主题管理页（RFW 自定义首页）
///
/// RFW = Remote Flutter Widgets。主题是纯文本 `.rfwtxt`，用 Flutter 组件
/// 描述首页内容区的排版与配色，运行时解析渲染 —— 换主题不需要重新编译 App。
class RfwThemePage extends StatefulWidget {
  const RfwThemePage({super.key});

  static const String routeName = '/rfw-theme';

  @override
  State<RfwThemePage> createState() => _RfwThemePageState();
}

class _RfwThemePageState extends State<RfwThemePage> {
  RfwThemeService get _svc => RfwThemeService.instance;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        elevation: 0,
        title: Text('首页主题',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
      ),
      body: Obx(() {
        final svc = _svc;
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            // ---------- 总开关 ----------
            AppCard(
              child: SettingsRow(
                icon: Icons.dashboard_customize_outlined,
                title: '启用自定义首页主题',
                value: svc.enabled.value ? '已开启' : '已关闭',
                trailingSwitch: true,
                switchValue: svc.enabled.value,
                onSwitchChanged: (v) => svc.setEnabled(v),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 12),
              child: Text(
                '关闭时使用原生首页。主题只影响首页内容区，详情页与播放器不变。',
                style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption),
              ),
            ),

            // ---------- 导入 ----------
            const SectionHeader(title: '导入主题'),
            AppCard(
              child: Column(
                children: [
                  OutlinedButton.icon(
                    onPressed: _importFromClipboard,
                    icon: const Icon(Icons.content_paste_go, size: 18),
                    label: const Text('从剪贴板导入 .rfwtxt'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.accentColor,
                      side: BorderSide(
                          color: AppTheme.accentColor.withValues(alpha: 0.5)),
                      minimumSize: const Size.fromHeight(44),
                      shape: RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.circular(AppTheme.radiusMD)),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '把主题文本复制到剪贴板后点这里；导入前会自动做语法检查',
                    style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption),
                  ),
                  if (svc.lastError.value.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.10),
                        borderRadius:
                            BorderRadius.circular(AppTheme.radiusMD),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('语法检查未通过',
                              style: TextStyle(
                                  color: Colors.redAccent,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                          const SizedBox(height: 4),
                          Text(
                            svc.lastError.value,
                            style: const TextStyle(
                                color: Colors.redAccent, fontSize: 11.5),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),

            // ---------- 已导入主题 ----------
            const SizedBox(height: 20),
            SectionHeader(title: '我的主题 (${svc.userThemes.length})'),
            if (svc.userThemes.isEmpty)
              AppCard(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Column(
                    children: [
                      Icon(Icons.auto_awesome_outlined,
                          size: 32, color: AppTheme.textTertiary),
                      const SizedBox(height: 8),
                      Text('还没有导入主题',
                          style: TextStyle(
                              color: AppTheme.textSecondary, fontSize: 13)),
                      const SizedBox(height: 4),
                      Text('可从 PeekPro 主题包复制 .rfwtxt 内容导入',
                          style: TextStyle(
                              color: AppTheme.textTertiary, fontSize: 11.5)),
                    ],
                  ),
                ),
              )
            else
              AppCard(
                child: Column(
                  children: [
                    for (var i = 0; i < svc.userThemes.length; i++) ...[
                      if (i > 0)
                        Divider(
                            height: 1,
                            color: Colors.white.withValues(alpha: 0.06)),
                      _themeRow(svc.userThemes[i]),
                    ],
                  ],
                ),
              ),

            // ---------- 说明 ----------
            const SizedBox(height: 20),
            const SectionHeader(title: '说明'),
            AppCard(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  '主题文件使用 RFW（Remote Flutter Widgets）语法，由 Flutter 原生组件渲染，'
                  '不是网页也不是脚本，无法访问文件、网络或执行任意代码。\n\n'
                  '主题里若引用了 App 未提供的组件，或存在语法错误，首页会自动回退到原生界面，'
                  '不会白屏。',
                  style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                      height: 1.6),
                ),
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _themeRow(RfwTheme t) {
    final selected = _svc.currentThemeId.value == t.id;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        selected ? Icons.check_circle : Icons.circle_outlined,
        color: selected ? AppTheme.accentColor : AppTheme.textTertiary,
        size: 20,
      ),
      title: Text(t.name,
          style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      subtitle: Text('${t.source.length} 字符',
          style:
              TextStyle(color: AppTheme.textTertiary, fontSize: 11.5)),
      onTap: () async {
        await _svc.setCurrent(t.id);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('已选择主题：${t.name}'),
              duration: const Duration(milliseconds: 1200)),
        );
      },
      trailing: IconButton(
        onPressed: () => _confirmDelete(t),
        icon: const Icon(Icons.delete_outline,
            size: 20, color: Colors.redAccent),
        tooltip: '删除',
      ),
    );
  }

  Future<void> _importFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text ?? '';
      if (text.trim().isEmpty) {
        _toast('剪贴板为空');
        return;
      }
      final id = await _svc.importFromText(text);
      if (!mounted) return;
      if (id == null) {
        // lastError 会被 Obx 自动刷新出来
        setState(() {});
        _toast('导入失败：语法检查未通过');
      } else {
        await _svc.setCurrent(id);
        if (!mounted) return;
        setState(() {});
        _toast('导入成功');
      }
    } catch (e) {
      _toast('导入异常：$e');
    }
  }

  Future<void> _confirmDelete(RfwTheme t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('删除主题', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('确定删除「${t.name}」？',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消',
                style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('删除', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _svc.deleteUserTheme(t.id);
      if (mounted) setState(() {});
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }
}
