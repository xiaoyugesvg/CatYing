import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../common/theme.dart';
import '../../services/rfw_theme_service.dart';
import '../../widgets/common_widgets.dart';
import 'rfw_theme_editor_page.dart';
import '../../widgets/app_toast.dart';

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
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          '首页主题',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: AppTheme.fontTitle3,
          ),
        ),
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
                  fontSize: AppTheme.fontCaption,
                ),
              ),
            ),

            // 开关开着但没选主题 —— 这时首页不会变，必须明确告知，
            // 否则用户导入完会以为"主题没生效"。
            if (svc.enabled.value && svc.currentThemeId.value.isEmpty)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: AppTheme.accentColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      size: 16,
                      color: AppTheme.accentColor,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '已开启，但还没选择主题 —— 请先导入或选择一个主题，首页才会变化',
                        style: TextStyle(
                          color: AppTheme.accentColor,
                          fontSize: AppTheme.fontFootnote,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // ---------- 导入 / 编辑 ----------
            const SectionHeader(title: '导入主题'),
            AppCard(
              child: Column(
                children: [
                  OutlinedButton.icon(
                    onPressed: _openEditor,
                    icon: const Icon(Icons.edit_note, size: 20),
                    label: const Text('编辑 / 粘贴主题内容'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.accentColor,
                      side: BorderSide(
                        color: AppTheme.accentColor.withValues(alpha: 0.5),
                      ),
                      minimumSize: const Size.fromHeight(46),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextButton.icon(
                          onPressed: _importFromClipboard,
                          icon: const Icon(Icons.content_paste_go, size: 18),
                          label: const Text(
                            '直接从剪贴板导入',
                            style: TextStyle(fontSize: AppTheme.fontSubhead),
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: AppTheme.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '打开编辑器可粘贴或手改主题文本，保存前会自动做语法检查',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                    ),
                  ),
                  if (svc.lastError.value.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: Colors.red.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(AppTheme.radiusMD),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            '语法检查未通过',
                            style: TextStyle(
                              color: Colors.redAccent,
                              fontSize: AppTheme.fontFootnote,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            svc.lastError.value,
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: AppTheme.fontFootnote,
                            ),
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
                      Icon(
                        Icons.auto_awesome_outlined,
                        size: 32,
                        color: AppTheme.textTertiary,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '还没有导入主题',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: AppTheme.fontSubhead,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '可从 PeekPro 主题包复制 .rfwtxt 内容导入',
                        style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontFootnote,
                        ),
                      ),
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
                          color: Colors.white.withValues(alpha: 0.06),
                        ),
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
                    fontSize: AppTheme.fontFootnote,
                    height: 1.6,
                  ),
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
      title: Text(
        t.name,
        style: TextStyle(
          color: AppTheme.textPrimary,
          fontSize: AppTheme.fontBody,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () async {
        await _svc.setCurrent(t.id);
        if (!mounted) return;
        AppToast.message(
          '已选择主题：${t.name}',
          duration: const Duration(milliseconds: 1200),
        );
      },
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            onPressed: () => _openEditor(editing: t),
            icon: Icon(
              Icons.edit_outlined,
              size: 19,
              color: AppTheme.textSecondary,
            ),
            tooltip: '编辑',
          ),
          IconButton(
            onPressed: () => _confirmDelete(t),
            icon: const Icon(
              Icons.delete_outline,
              size: 19,
              color: Colors.redAccent,
            ),
            tooltip: '删除',
          ),
        ],
      ),
    );
  }

  Future<void> _openEditor({RfwTheme? editing}) async {
    final saved = await Get.to<bool>(
      () => RfwThemeEditorPage(editing: editing),
    );
    if (!mounted) return;
    if (saved == true) setState(() {});
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
        // 导入即选中 + 打开总开关，一步到位；否则用户以为"没生效"
        await _svc.setCurrent(id);
        await _svc.setEnabled(true);
        if (!mounted) return;
        setState(() {});
        _toast('导入成功并已启用，回首页即可看到效果');
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
        content: Text(
          '确定删除「${t.name}」？',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: AppTheme.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.redAccent)),
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
    AppToast.message(msg, duration: const Duration(seconds: 2));
  }
}
