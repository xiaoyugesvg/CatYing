import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/tmdb_service.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';
import 'package:tvbox/widgets/app_toast.dart';

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

        // ---------- 媒体库模式 ----------
        Obx(
          () => AppCard(
            dense: true,
            child: unifiedSwitchRow(
              icon: Icons.video_library_outlined,
              title: '媒体库模式',
              value: tmdb.libraryMode.value,
              onChanged: tmdb.setLibraryMode,
              subtitle: '开启后视频详情页与播放器切换为媒体库界面（TMDB 数据驱动）',
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
                hint: '填基础链接即可（自动补 /3），如 https://tmdb.huamu.shop',
                onChanged: tmdb.setApiProxy,
                trailing: _copyButton(tmdb.apiProxy.value),
              ),
              Divider(color: AppTheme.borderLight, height: 1, thickness: 0.5),
              _labeledField(
                label: '图片代理地址',
                controller: TextEditingController(text: tmdb.imgProxy.value),
                hint: '留空自动复用 API 代理（补 /t/p），也可单独填',
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
              // 刮削数据测试：真实片名搜索，验证整条刮削链路
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: _outlineButton('刮削数据测试', _runScrapeTest),
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

  /// 刮削数据测试：自己输入片名 → 真实搜索 TMDB → 弹出候选的原始 JSON 数据
  Future<void> _runScrapeTest() async {
    final input = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.glassRadius),
        ),
        title: Text(
          '刮削数据测试',
          style: TextStyle(color: AppTheme.textPrimary),
        ),
        content: TextField(
          controller: input,
          autofocus: true,
          style: TextStyle(color: AppTheme.textPrimary),
          decoration: InputDecoration(
            hintText: '输入视频名称，例如：大唐妖探',
            hintStyle: TextStyle(
              color: AppTheme.textTertiary,
              fontSize: AppTheme.fontFootnote,
            ),
            filled: true,
            fillColor: AppTheme.backgroundTertiary,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
              borderSide: BorderSide.none,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              '取消',
              style: TextStyle(color: AppTheme.textTertiary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, input.text),
            child: Text(
              '开始测试',
              style: TextStyle(color: AppTheme.accentColor),
            ),
          ),
        ],
      ),
    );
    final kw = title?.trim() ?? '';
    if (kw.isEmpty || !mounted) return;
    setState(() => _testing = true);
    final r = await tmdb.testScrape(kw);
    if (!mounted) return;
    setState(() => _testing = false);
    _showScrapeResult(kw, r);
  }

  void _showScrapeResult(
    String kw,
    ({
      bool ok,
      String message,
      List<(String, Map<String, dynamic>)> candidates,
    }) r,
  ) {
    // 原始 JSON：把每个候选（含 type 标记）序列化成缩进 JSON，可直接复制核对
    final jsonText = const JsonEncoder.withIndent('  ').convert(
      r.candidates
          .map((e) => <String, dynamic>{'type': e.$1, ...e.$2})
          .toList(),
    );
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.glassRadius),
        ),
        title: Text('刮削结果', style: TextStyle(color: AppTheme.textPrimary)),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                r.message,
                style: TextStyle(
                  color: r.ok ? Colors.greenAccent : Colors.redAccent,
                  fontSize: AppTheme.fontSubhead,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              if (r.candidates.isNotEmpty) ...[
                Text(
                  '候选 JSON（${r.candidates.length} 条，可长按复制）：',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontFootnote,
                  ),
                ),
                const SizedBox(height: 6),
                Container(
                  height: 180,
                  width: double.maxFinite,
                  decoration: BoxDecoration(
                    color: AppTheme.backgroundTertiary,
                    borderRadius:
                        BorderRadius.circular(AppTheme.glassRadiusSmall),
                  ),
                  padding: const EdgeInsets.all(8),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      jsonText,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 10.5,
                        height: 1.45,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '点击候选查看详情刮削（与媒体库同一链路）：',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontFootnote,
                  ),
                ),
                const SizedBox(height: 4),
                Flexible(
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: r.candidates.length,
                    separatorBuilder: (_, __) =>
                        Divider(color: AppTheme.borderLight, height: 1),
                    itemBuilder: (_, i) {
                      final (type, item) = r.candidates[i];
                      final name =
                          (item['title'] ?? item['name'] ?? '').toString();
                      final date = (item['release_date'] ??
                              item['first_air_date'] ??
                              '')
                          .toString();
                      final year = date.length >= 4 ? date.substring(0, 4) : '';
                      final vote = (item['vote_average'] as num?)?.toDouble() ?? 0;
                      final poster = (item['poster_path'] ?? '').toString();
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        // 点击候选 → 跑完整详情刮削（与媒体库详情页同一链路）
                        onTap: () => _runDetailTest(type, item),
                        leading: poster.isNotEmpty
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: CachedNetworkImage(
                                  imageUrl:
                                      '${tmdb.effectiveImgBase}/w92$poster',
                                  width: 46,
                                  height: 64,
                                  fit: BoxFit.cover,
                                  placeholder: (_, __) => Container(
                                    width: 46,
                                    height: 64,
                                    color: AppTheme.backgroundTertiary,
                                  ),
                                  errorBuilder: (_, __, ___) => Container(
                                    width: 46,
                                    height: 64,
                                    color: AppTheme.backgroundTertiary,
                                    child: Icon(
                                      Icons.broken_image_outlined,
                                      color: AppTheme.textTertiary,
                                      size: 18,
                                    ),
                                  ),
                                ),
                              )
                            : Container(
                                width: 46,
                                height: 64,
                                color: AppTheme.backgroundTertiary,
                                child: Icon(
                                  Icons.movie_outlined,
                                  color: AppTheme.textTertiary,
                                  size: 20,
                                ),
                              ),
                        title: Text(
                          name,
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: AppTheme.fontSubhead,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${type == 'movie' ? '电影' : '剧集'}'
                          '${year.isNotEmpty ? ' · $year' : ''}'
                          '${vote > 0 ? ' · ${vote.toStringAsFixed(1)}★' : ''}',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: AppTheme.fontFootnote,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              '完成',
              style: TextStyle(color: AppTheme.accentColor),
            ),
          ),
        ],
      ),
    );
  }

  /// 点击候选 → 跑完整详情刮削（与媒体库详情页同一 enrich 链路）
  Future<void> _runDetailTest(String type, Map<String, dynamic> item) async {
    if (!mounted) return;
    Navigator.pop(context); // 关闭候选列表框
    setState(() => _testing = true);
    final r = await tmdb.testScrapeDetail(type, item);
    if (!mounted) return;
    setState(() => _testing = false);
    _showDetailResult(r.summary, r.ok, r.message);
  }

  void _showDetailResult(
    Map<String, dynamic> s,
    bool ok,
    String message,
  ) {
    final rating = (s['rating'] as num?)?.toDouble() ?? 0;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppTheme.glassRadius),
        ),
        title: Text('详情刮削验证', style: TextStyle(color: AppTheme.textPrimary)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  message,
                  style: TextStyle(
                    color: ok ? Colors.greenAccent : Colors.redAccent,
                    fontSize: AppTheme.fontSubhead,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 12),
                _kv('标题', s['title']),
                _kv('类型', s['typeName']),
                _kv('年份', s['year']),
                _kv('评分', rating > 0 ? '${rating.toStringAsFixed(1)}★' : ''),
                _kv('状态', s['status']),
                _kv('导演', s['director']),
                _kv('演职员', '${s['castCount']} 位'),
                _kv('类似作品', '${s['similarCount']} 部'),
                _kv('剧集剧照', '${s['stillsCount']} 张'),
                _kv('总集数', '${s['episodeCount']}'),
                _kv('背景图', s['hasBackdrop'] == true ? '✅ 有' : '❌ 无'),
                _kv('海报', s['hasPoster'] == true ? '✅ 有' : '❌ 无'),
                if ('${s['overview'] ?? ''}'.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '简介',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: AppTheme.fontSubhead,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${s['overview']}',
                    maxLines: 6,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: AppTheme.fontFootnote,
                      height: 1.5,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('完成', style: TextStyle(color: AppTheme.accentColor)),
          ),
        ],
      ),
    );
  }

  /// 键值行：空值自动隐藏
  Widget _kv(String k, dynamic v) {
    final s = '$v';
    if (s.isEmpty || s == 'null' || s == '0') return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 62,
            child: Text(
              k,
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontFootnote,
              ),
            ),
          ),
          Expanded(
            child: Text(
              s,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontFootnote,
              ),
            ),
          ),
        ],
      ),
    );
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
