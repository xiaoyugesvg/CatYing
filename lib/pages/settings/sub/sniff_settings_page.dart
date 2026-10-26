import 'package:flutter/material.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/services/parse_service.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/services/play_route.dart';
import 'package:tvbox/services/sniff_filter.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';

/// 设置 → 播放设置 → 嗅探设置
///
/// 用户 2026-10-15：
///   「嗅探只要 m3u8、MP4、flv 等等影视链接」
///   「增加不嗅探哪些链接、指定嗅探哪些链接，有助去掉广告」
///   「解析也是解析哪些类型的网页的」
///   「能添加指定嗅探哪些内容吗？……嗅探到了视频给播放器用」
///
/// 规则分组（落盘在 [PlayerPrefs]，判定集中在 services/sniff_filter.dart）：
///   · 总开关     —— 自动嗅探 / 解析接口；
///   · 嗅探过滤   —— 媒体格式白名单 + 链接黑名单 + 链接白名单（去广告）；
///   · 解析范围   —— 哪些网站先过解析接口 + 解析结果的格式。
///
/// 注意：**嗅探的目标始终是"拿到视频直链交给原生播放器"**，不会把网页或
/// 播放器元素本身当播放地址（非影视直链一律丢弃，见 SniffFilter.acceptSniffUrl）。
class SniffSettingsPage extends StatefulWidget {
  const SniffSettingsPage({super.key});

  @override
  State<SniffSettingsPage> createState() => _SniffSettingsPageState();
}

class _SniffSettingsPageState extends State<SniffSettingsPage> {
  PlayerPrefs get prefs => PlayerPrefs.instance;

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '嗅探设置',
      action: TextButton(
        onPressed: _reset,
        child: Text('恢复默认',
            style: TextStyle(color: AppTheme.textTertiary, fontSize: 13)),
      ),
      children: [
        // ---------- 总开关 ----------
        SettingsGroup(
          title: '总开关',
          children: [
            Obx(() => unifiedSwitchRow(
                  icon: Icons.travel_explore,
                  title: '自动嗅探',
                  subtitle: '网页视频自动抓取 m3u8、mp4 等直链，无需手点',
                  value: prefs.sniffEnabled.value,
                  onChanged: prefs.setSniffEnabled,
                )),
            Obx(() => unifiedSwitchRow(
                  icon: Icons.api,
                  title: '解析接口',
                  subtitle: '命中规则的网站先请求解析接口（优爱腾芒 B 等）',
                  value: prefs.parseEnabled.value,
                  onChanged: prefs.setParseEnabled,
                )),
            Obx(() => unifiedSwitchRow(
                  icon: Icons.link_outlined,
                  title: '播放带 Referer',
                  subtitle: '用页面地址做防盗链，部分站点必须带才能播',
                  value: prefs.sniffSendReferer.value,
                  onChanged: prefs.setSniffSendReferer,
                )),
          ],
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- 规则说明 ----------
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 10, right: 4),
          child: Text(
            '嗅探只识别「影视直链后缀」清单里的格式（可在下面增删），'
            '普通网页链接不会被当成播放地址。规则每行填一个，不区分大小写。',
            style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
                height: 1.5),
          ),
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- 嗅探过滤 ----------
        SettingsGroup(
          title: '嗅探过滤（去广告）',
          children: [
            Obx(() => SettingsRow(
                  icon: Icons.block,
                  title: '不嗅探的链接',
                  subtitle: '链接包含关键词即跳过，用于过滤切片广告',
                  value: '${prefs.sniffBlacklist.length} 条',
                  onTap: () => _editList(
                    title: '不嗅探的链接（黑名单）',
                    lines: prefs.sniffBlacklist.toList(),
                    helper: '每行一个关键词，链接中包含该词即丢弃。\n'
                        '例如：/ads/、/guanggao/、doubleclick',
                    onSave: prefs.setSniffBlacklist,
                  ),
                )),
            Obx(() => SettingsRow(
                  icon: Icons.filter_alt_outlined,
                  title: '只嗅探的链接',
                  subtitle: '非空时仅放行命中的链接，留空表示不限制',
                  value: prefs.sniffWhitelist.isEmpty
                      ? '未限制'
                      : '${prefs.sniffWhitelist.length} 条',
                  onTap: () => _editList(
                    title: '只嗅探的链接（白名单）',
                    lines: prefs.sniffWhitelist.toList(),
                    helper: '每行一个关键词，非空时只嗅探命中的链接。\n'
                        '例如：/video/、cdn.example.com',
                    onSave: prefs.setSniffWhitelist,
                  ),
                )),
            Obx(() => SettingsRow(
                  icon: Icons.video_file_outlined,
                  title: '影视直链后缀',
                  subtitle: '决定什么算可播放的直链，也决定嗅探只收哪些格式',
                  value: _formatSummary(SniffFilter.mediaExtensions),
                  onTap: () => _editList(
                    title: '影视直链后缀',
                    lines: SniffFilter.mediaExtensions,
                    hint: '.m3u8',
                    helper: '每行一个后缀（带点），例如 .m3u8 / .mp4 / .flv。\n'
                        '它同时决定「什么算可播放的直链」和「嗅探只接受哪些格式」，'
                        '例如去掉 .ts 就不会把站点的 .ts 广告切片当播放地址。\n'
                        '清单为空时回退出厂默认（13 种）。',
                    normalize: _normalizeExt,
                    onSave: (v) async {
                      await prefs.setMediaExtensions(v);
                      // 后缀清单变了 → 旧的解析结果可能已不符合新规则，清缓存
                      ParseService.instance.clearCache();
                    },
                  ),
                )),
          ],
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- 解析范围 ----------
        SettingsGroup(
          title: '解析范围（哪些网页先过解析接口）',
          children: [
            SettingsRow(
              icon: Icons.public,
              title: '内置主流站点',
              subtitle: '优爱腾芒 B 等必须走解析的站点',
              value: '${kParseFirstHosts.length} 个',
              onTap: _showBuiltinHosts,
            ),
            Obx(() => SettingsRow(
                  icon: Icons.playlist_add,
                  title: '追加解析的网站',
                  subtitle: '在内置清单之外，额外需要解析的域名',
                  value: prefs.parseHostsExtra.isEmpty
                      ? '未添加'
                      : '${prefs.parseHostsExtra.length} 个',
                  onTap: () => _editList(
                    title: '追加解析的网站',
                    lines: prefs.parseHostsExtra.toList(),
                    helper: '每行一个域名，自动包含其子域名。\n'
                        '例如：example.com 会同时命中 www.example.com',
                    onSave: prefs.setParseHostsExtra,
                  ),
                )),
            Obx(() => SettingsRow(
                  icon: Icons.do_disturb_on_outlined,
                  title: '不解析的网站',
                  subtitle: '优先级最高，命中后直接嗅探；可关闭内置站点',
                  value: prefs.parseHostsBlock.isEmpty
                      ? '未添加'
                      : '${prefs.parseHostsBlock.length} 个',
                  onTap: () => _editList(
                    title: '不解析的网站',
                    lines: prefs.parseHostsBlock.toList(),
                    helper: '每行一个域名，命中后不再请求解析接口。\n'
                        '例如填 qq.com 可关闭腾讯视频的内置解析',
                    onSave: prefs.setParseHostsBlock,
                  ),
                )),
            Obx(() => SettingsRow(
                  icon: Icons.high_quality_outlined,
                  title: '解析结果的格式',
                  subtitle: '解析出的直链只要勾选的格式，其余视为未命中',
                  value: _formatSummary(prefs.parseFormats),
                  onTap: () => _pickFormats(
                    title: '解析结果的格式',
                    helper: '解析接口返回的直链只采用勾选的格式，'
                        '不在列表内的结果会被跳过、继续试其它接口。\n'
                        '选项来自上面的「影视直链后缀」清单。',
                    current: prefs.parseFormats.toList(),
                    onSave: (v) async {
                      await prefs.setParseFormats(v);
                      // 结果格式筛选变了 → 旧缓存可能不合规，清掉
                      ParseService.instance.clearCache();
                    },
                  ),
                )),
          ],
        ),
      ],
    );
  }

  // ============================================================
  // 多行列表编辑
  // ============================================================

  /// 弹出多行编辑框（每行一条），保存时按换行拆分后交 [onSave] 落盘。
  ///
  /// [normalize] 可选：把每行归一化（例如后缀统一补前导点 `.m3u8`）。
  Future<void> _editList({
    required String title,
    required List<String> lines,
    required String helper,
    required Future<void> Function(List<String>) onSave,
    String hint = '每行一个',
    List<String> Function(List<String>)? normalize,
  }) async {
    final text = await SettingsDialogs.editText(
      context: context,
      title: title,
      initial: lines.join('\n'),
      hint: hint,
      maxLines: 10,
      helper: helper,
    );
    if (text == null) return;
    var parts = text.split(RegExp(r'[\r\n]+'));
    if (normalize != null) parts = normalize(parts);
    await onSave(parts);
    if (mounted) setState(() {});
  }

  /// 后缀归一化：去空白、转小写、补前导点（`m3u8` → `.m3u8`）。
  List<String> _normalizeExt(List<String> raw) {
    return raw
        .map((e) => e.trim().toLowerCase())
        .where((e) => e.isNotEmpty)
        .map((e) => e.startsWith('.') ? e : '.$e')
        .toList();
  }

  // ============================================================
  // 媒体格式多选
  // ============================================================

  /// 列表值摘要：空 = 全部；少量直接列出，多了省略。
  String _formatSummary(List<String> formats) {
    if (formats.isEmpty) return '全部';
    String name(String e) => e.replaceFirst('.', '');
    if (formats.length <= 3) return formats.map(name).join('、');
    return '${formats.take(3).map(name).join('、')} 等 ${formats.length} 种';
  }

  /// 媒体格式多选弹窗（选项来自**当前生效的影视直链后缀清单**，
  /// 用户在「影视直链后缀」里加了新后缀这里会自动出现）。
  ///
  /// 语义：**空列表 = 不限**（= 清单内全收）。用户全选时也存空列表。
  Future<void> _pickFormats({
    required String title,
    required String helper,
    required List<String> current,
    required Future<void> Function(List<String>) onSave,
  }) async {
    final all = SniffFilter.mediaExtensions;
    final draft = <String>{
      if (current.isEmpty) ...all else ...current,
    };

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: AppTheme.backgroundSecondary,
          title: Text(title, style: TextStyle(color: AppTheme.textPrimary)),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(helper,
                      style: TextStyle(
                          color: AppTheme.textTertiary,
                          fontSize: AppTheme.fontFootnote,
                          height: 1.5)),
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final ext in all)
                        FilterChip(
                          label: Text(ext.replaceFirst('.', ''),
                              style: TextStyle(
                                  fontSize: AppTheme.fontFootnote,
                                  color: draft.contains(ext)
                                      ? AppTheme.accentOnSurface
                                      : AppTheme.textSecondary)),
                          selected: draft.contains(ext),
                          showCheckmark: false,
                          selectedColor: AppTheme.accentSurface,
                          backgroundColor: AppTheme.backgroundPrimary,
                          side: BorderSide(
                            color: draft.contains(ext)
                                ? AppTheme.accentOnSurface
                                : AppTheme.textTertiary.withValues(alpha: 0.35),
                          ),
                          onSelected: (v) => setLocal(() {
                            if (v) {
                              draft.add(ext);
                            } else {
                              draft.remove(ext);
                            }
                          }),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child:
                  Text('取消', style: TextStyle(color: AppTheme.textTertiary)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text('确定',
                  style: TextStyle(color: AppTheme.accentOnSurface)),
            ),
          ],
        ),
      ),
    );

    if (saved != true) return;
    await onSave(draft.length == all.length ? const [] : draft.toList());
    if (mounted) setState(() {});
  }

  // ============================================================
  // 内置站点只读展示
  // ============================================================

  Future<void> _showBuiltinHosts() {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.backgroundSecondary,
        title: Text('内置主流站点',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final h in kParseFirstHosts)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      // 暗色下不能再用"墨色淡底 + 墨色字"（用户 2026-10-15：
                      // 晚上完全看不清）⇒ 统一走 accentSurface / accentOnSurface
                      color: AppTheme.accentSurface,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(h,
                        style: TextStyle(
                            color: AppTheme.accentOnSurface,
                            fontSize: AppTheme.fontFootnote)),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text('知道了',
                style: TextStyle(color: AppTheme.accentOnSurface)),
          ),
        ],
      ),
    );
  }

  // ============================================================
  // 恢复默认
  // ============================================================

  Future<void> _reset() async {
    final ok = await SettingsDialogs.confirm(
      context: context,
      title: '恢复默认',
      message: '黑名单恢复为出厂广告规则；白名单、自定义解析域名、'
          '媒体格式筛选全部清空（格式清空 = 不限）。',
      confirmText: '恢复',
      confirmColor: AppTheme.accentOnSurface,
    );
    if (!ok) return;
    await prefs.resetSniffRules();
    if (mounted) setState(() {});
  }
}
