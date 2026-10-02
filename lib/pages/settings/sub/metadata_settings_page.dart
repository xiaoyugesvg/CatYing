import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../services/player_prefs.dart';
import '../../../services/tmdb_service.dart';
import '../../../widgets/common_widgets.dart';
import 'settings_shared.dart';
import '../../../widgets/app_toast.dart';

/// 设置 → 元数据（TMDB 刮削详细配置）
///
/// 对应参考图：启用开关 → 海报展示样式（固定/随机/轮播）→
/// API Key / API 代理 / 图片代理（含复制按钮）→ 测试两个代理 → 断开连接
class MetadataSettingsPage extends StatefulWidget {
  const MetadataSettingsPage({super.key});

  @override
  State<MetadataSettingsPage> createState() => _MetadataSettingsPageState();
}

class _MetadataSettingsPageState extends State<MetadataSettingsPage> {
  TmdbService get tmdb => TmdbService.instance;

  bool _testing = false;

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: 'TMDB 配置',
      children: [
        // ---------- 启用 ----------
        Obx(
          () => AppCard(
            dense: true,
            child: unifiedSwitchRow(
              icon: Icons.movie_creation_outlined,
              title: '启用 TMDB',
              value: tmdb.enabled.value,
              onChanged: tmdb.setEnabled,
            ),
          ),
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- 海报展示样式 ----------
        Obx(
          () => AppCard(
            dense: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                  child: Text(
                    '海报展示样式',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead + 0.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _segmented(
                  options: const [
                    ('fixed', '固定'),
                    ('random', '随机'),
                    ('rotate', '轮播'),
                  ],
                  current: tmdb.posterStyle.value,
                  onChanged: tmdb.setPosterStyle,
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- Key / 代理 ----------
        AppCard(
          dense: true,
          child: Column(
            children: [
              _labeledField(
                label: 'API Key',
                controller: TextEditingController(text: tmdb.apiKey.value),
                hint: '粘贴 API Key (v3)',
                onChanged: tmdb.saveApiKey,
                trailing: GestureDetector(
                  onTap: () async {
                    await tmdb.disconnect();
                    if (mounted) setState(() {});
                  },
                  child: Icon(
                    Icons.cancel,
                    size: 17,
                    color: AppTheme.textTertiary,
                  ),
                ),
              ),
              Divider(color: AppTheme.borderLight, height: 1, thickness: 0.5),
              _labeledField(
                label: 'API 代理地址',
                controller: TextEditingController(text: tmdb.apiProxy.value),
                hint: '例如 https://api.themoviedb.org，留空则使用官方地址',
                onChanged: tmdb.setApiProxy,
                trailing: _copyButton(tmdb.apiProxy.value),
              ),
              Divider(color: AppTheme.borderLight, height: 1, thickness: 0.5),
              _labeledField(
                label: '图片代理地址',
                controller: TextEditingController(text: tmdb.imgProxy.value),
                hint: '例如 https://image.tmdb.org/t/p，留空则使用官方地址',
                onChanged: tmdb.setImgProxy,
                trailing: _copyButton(tmdb.imgProxy.value),
              ),
              const SizedBox(height: 12),
              // 测试按钮
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: _outlineButton(
                        '测试 API 代理',
                        () => _runTest(api: true),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _outlineButton(
                        '测试图片代理',
                        () => _runTest(api: false),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- 断开连接 ----------
        Center(
          child: TextButton(
            onPressed: _confirmDisconnect,
            child: const Text(
              '断开连接',
              style: TextStyle(color: Colors.redAccent),
            ),
          ),
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- 详情页展示（原有项，保留）----------
        SettingsGroup(
          title: '详情页展示',
          children: [
            Obx(
              () => SettingsRow(
                icon: Icons.people_alt_outlined,
                title: '显示演职人员',
                value: tmdb.showCast.value ? '已开启' : '已关闭',
                onTap: () => tmdb.setShowCast(!tmdb.showCast.value),
              ),
            ),
            Obx(
              () => SettingsRow(
                icon: Icons.local_movies_outlined,
                title: '显示类似作品',
                value: tmdb.showSimilar.value ? '已开启' : '已关闭',
                onTap: () => tmdb.setShowSimilar(!tmdb.showSimilar.value),
              ),
            ),
            Obx(
              () => SettingsRow(
                icon: Icons.auto_awesome,
                title: '自动刮削元数据',
                value: tmdb.autoScrape.value ? '已开启' : '已关闭',
                onTap: () => tmdb.setAutoScrape(!tmdb.autoScrape.value),
              ),
            ),
            Obx(
              () => SettingsRow(
                icon: Icons.dashboard_customize_outlined,
                title: '详情页样式',
                value: PlayerPrefs.instance.scrapedDetailLayout.value
                    ? '媒体库'
                    : '默认',
                onTap: () async {
                  final cur = PlayerPrefs.instance.scrapedDetailLayout.value;
                  await PlayerPrefs.instance.setScrapedDetailLayout(!cur);
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ============================================================
  // 组件
  // ============================================================
  /// 分段选择（固定 / 随机 / 轮播），中间用竖线分隔
  Widget _segmented({
    required List<(String, String)> options,
    required String current,
    required ValueChanged<String> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
        ),
        child: Row(
          children: [
            for (var i = 0; i < options.length; i++) ...[
              if (i > 0)
                Container(
                  width: 1,
                  height: 16,
                  color: AppTheme.borderMedium.withValues(alpha: 0.6),
                ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onChanged(options[i].$1),
                  child: Container(
                    alignment: Alignment.center,
                    margin: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      color: current == options[i].$1
                          ? AppTheme.backgroundElevated
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(9),
                      border: current == options[i].$1
                          ? Border.all(color: AppTheme.glassBorder, width: 0.6)
                          : null,
                    ),
                    child: Text(
                      options[i].$2,
                      style: TextStyle(
                        color: current == options[i].$1
                            ? AppTheme.textPrimary
                            : AppTheme.textSecondary,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: current == options[i].$1
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _labeledField({
    required String label,
    required TextEditingController controller,
    required String hint,
    required ValueChanged<String> onChanged,
    Widget? trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontSubhead,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            decoration: BoxDecoration(
              color: AppTheme.backgroundTertiary,
              borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
              border: Border.all(color: AppTheme.borderLight, width: 0.5),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    onChanged: onChanged,
                    cursorColor: AppTheme.accentColor,
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontBody,
                    ),
                    decoration: InputDecoration(
                      hintText: hint,
                      hintStyle: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontFootnote,
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 8),
                  trailing,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _copyButton(String value) {
    return GestureDetector(
      onTap: value.trim().isEmpty
          ? null
          : () async {
              await Clipboard.setData(ClipboardData(text: value.trim()));
              if (mounted) {
                AppToast.message('已复制');
              }
            },
      child: Icon(
        Icons.copy,
        size: 17,
        color: value.trim().isEmpty
            ? AppTheme.textTertiary.withValues(alpha: 0.4)
            : AppTheme.textSecondary,
      ),
    );
  }

  Widget _outlineButton(String text, VoidCallback onTap) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _testing ? null : onTap,
      child: Container(
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
          border: Border.all(color: AppTheme.borderMedium, width: 0.8),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: _testing ? AppTheme.textTertiary : AppTheme.textSecondary,
            fontSize: AppTheme.fontSubhead,
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 行为
  // ============================================================

  Future<void> _runTest({required bool api}) async {
    setState(() => _testing = true);
    final r = api ? await tmdb.testApiProxy() : await tmdb.testImgProxy();
    if (!mounted) return;
    setState(() => _testing = false);
    AppToast.message(r.message, isError: true);
  }

  Future<void> _confirmDisconnect() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.glassRadius),
        ),
        title: Text('断开连接', style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          '将清空 TMDB API Key（代理地址保留）。确定？',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: AppTheme.textTertiary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('断开', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await tmdb.disconnect();
    if (mounted) setState(() {});
  }
}
