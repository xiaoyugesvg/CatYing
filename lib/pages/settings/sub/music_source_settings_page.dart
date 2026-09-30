import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../services/music_service.dart';
import '../../../widgets/common_widgets.dart';
import 'music/script_import_page.dart';
import 'settings_shared.dart';

/// 设置 → 音乐音源
///
/// 主通道：**落雪(LX)自定义音源脚本**
///   · 从本地文件 / 粘贴导入
///   · 从 URL 下载导入
///   · 一键测试（真的搜一首歌 + 取一次播放地址）
///
/// 备用通道：通用 HTTP 音源地址（兼容 Aurora 那类协议）
class MusicSourceSettingsPage extends StatefulWidget {
  const MusicSourceSettingsPage({super.key});

  @override
  State<MusicSourceSettingsPage> createState() =>
      _MusicSourceSettingsPageState();
}

class _MusicSourceSettingsPageState extends State<MusicSourceSettingsPage> {
  MusicService get svc => MusicService.instance;

  final _urlCtrl = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '音乐音源',
      children: [
        // ================= 落雪音源（主）=================
        Obx(() {
          final has = svc.hasLxScript;
          return AppCard(
            dense: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: AppTheme.accentColor.withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                              color:
                                  AppTheme.accentColor.withValues(alpha: 0.22),
                              width: 0.5),
                        ),
                        child: Icon(Icons.extension,
                            size: 18, color: AppTheme.accentColor),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('落雪(LX)音源脚本',
                                style: TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: AppTheme.fontSubhead + 1,
                                    fontWeight: FontWeight.w600)),
                            const SizedBox(height: 2),
                            Text(
                              has
                                  ? svc.lxName.value
                                  : '未导入 —— 这是主要的音乐来源',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  color: has
                                      ? AppTheme.accentColor
                                      : AppTheme.textTertiary,
                                  fontSize: AppTheme.fontCaption),
                            ),
                          ],
                        ),
                      ),
                      if (has)
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _confirmRemove,
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(Icons.delete_outline,
                                size: 18, color: Colors.redAccent),
                          ),
                        ),
                    ],
                  ),
                ),
                // 从文件 / 粘贴导入
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _button('导入脚本（文件 / 粘贴）',
                      filled: true, onTap: _openImport),
                ),
                const SizedBox(height: 10),
                // 从 URL 导入
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('或从 URL 下载导入',
                          style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: AppTheme.fontSubhead)),
                      const SizedBox(height: 6),
                      Container(
                        decoration: BoxDecoration(
                          color: AppTheme.backgroundTertiary,
                          borderRadius: BorderRadius.circular(
                              AppTheme.glassRadiusSmall),
                          border: Border.all(
                              color: AppTheme.borderLight, width: 0.5),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: TextField(
                          controller: _urlCtrl,
                          cursorColor: AppTheme.accentColor,
                          style: TextStyle(
                              color: AppTheme.textPrimary, fontSize: 13.5),
                          decoration: InputDecoration(
                            hintText: 'https://…/source.js',
                            hintStyle: TextStyle(
                                color: AppTheme.textTertiary,
                                fontSize: 12.5),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding:
                                const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: _button(
                    _busy ? '下载中…' : '从 URL 下载并导入',
                    filled: false,
                    onTap: _busy ? null : _importFromUrl,
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: _button(
                    _busy ? '测试中…' : '测试音源（搜索 + 取链）',
                    filled: false,
                    onTap: _busy ? null : _runTest,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  child: Text(
                    '脚本在 App 内置的 Node 沙箱里执行：只允许发网络请求，'
                    '不能读写文件。请只导入你信任的来源。',
                    style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                        height: 1.5),
                  ),
                ),
              ],
            ),
          );
        }),
        const SizedBox(height: AppTheme.spacingLG),

        // ================= HTTP 音源（备用）=================
        SettingsGroup(
          title: '备用：通用 HTTP 音源',
          children: [
            Obx(() => SettingsRow(
                  icon: Icons.language,
                  title: 'HTTP 音源地址',
                  value: svc.sourceUrl.value.isEmpty ? '未配置' : '已配置',
                  onTap: _editHttpSource,
                )),
            Obx(() => SettingsRow(
                  icon: Icons.high_quality_outlined,
                  title: '音质',
                  value: svc.quality.value,
                  onTap: _pickQuality,
                )),
          ],
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ================= 说明 =================
        const SettingsGroup(
          title: '关于',
          children: [
            SettingsRow(
              icon: Icons.info_outline,
              title: 'App 不内置任何音源',
              value: '',
            ),
            SettingsRow(
              icon: Icons.code,
              title: '支持的脚本协议',
              value: '',
            ),
            SettingsRow(
              icon: Icons.swap_horiz,
              title: '取链返回兼容',
              value: '',
            ),
          ],
        ),
      ],
    );
  }

  // ============================================================
  // 组件
  // ============================================================

  Widget _button(String text, {required bool filled, VoidCallback? onTap}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: filled
              ? AppTheme.accentColor
              : AppTheme.accentColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
          border: filled
              ? null
              : Border.all(
                  color: AppTheme.accentColor.withValues(alpha: 0.5),
                  width: 0.8),
        ),
        child: Text(
          text,
          style: TextStyle(
              color: filled ? Colors.white : AppTheme.accentColor,
              fontSize: 14,
              fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  // ============================================================
  // 行为
  // ============================================================

  Future<void> _openImport() async {
    await Get.to(() => const MusicScriptImportPage());
    // 回来后刷新（Obx 会自动更新，这里只是保险）
    if (mounted) setState(() {});
  }

  Future<void> _importFromUrl() async {
    final messenger = ScaffoldMessenger.of(context);
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('请先填写脚本地址')));
      return;
    }
    setState(() => _busy = true);
    final r = await svc.importFromUrl(url);
    if (!mounted) return;
    setState(() => _busy = false);
    messenger.showSnackBar(SnackBar(
      content: Text(r.message),
      backgroundColor: r.ok ? null : Colors.redAccent,
    ));
  }

  Future<void> _confirmRemove() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppTheme.glassRadius)),
        title: Text('移除音源', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text('将删除已导入的脚本，确定？',
            style: TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                Text('取消', style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await svc.clearLxScript();
    messenger.showSnackBar(const SnackBar(content: Text('已移除')));
  }

  Future<void> _runTest() async {
    if (!svc.configured) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请先导入音源')));
      return;
    }
    setState(() => _busy = true);
    final r = await svc.testConnection();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r.message),
      backgroundColor: r.ok ? null : Colors.redAccent,
    ));
  }

  Future<void> _editHttpSource() async {
    final r = await SettingsDialogs.editText(
      context: context,
      title: 'HTTP 音源地址',
      initial: svc.sourceUrl.value,
      hint: 'https://host/aurora?key=xxx',
      helper: '支持三种写法：\n'
          '· 服务地址 → 自动补 /aurora?query=…\n'
          '· 含 {query} 的模板 → 原样替换\n'
          '· 其它 → 直接把 query 拼上去',
    );
    if (r == null) return;
    await svc.setSourceUrl(r);
    if (mounted) setState(() {});
  }

  Future<void> _pickQuality() async {
    final v = await SettingsDialogs.pick<String>(
      context: context,
      title: '音质',
      options: const ['128', '320', 'flac'],
      selected: svc.quality.value,
      labelBuilder: (x) => switch (x) {
        '128' => '128k',
        'flac' => 'FLAC',
        _ => '320k',
      },
    );
    if (v != null) await svc.setQuality(v);
  }
}
