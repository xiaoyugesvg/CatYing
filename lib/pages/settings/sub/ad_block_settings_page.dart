import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../common/theme.dart';
import '../../../services/ad_block_service.dart';
import '../../../widgets/app_toast.dart';
import '../../../widgets/common_widgets.dart';
import 'settings_shared.dart';

/// 「广告管理」——网页去广告的**统一设置入口**。
///
/// 这里管的是**页面层**的广告（把广告元素的 CSS 选择器注入网页隐藏掉）：
///   · RSS 正文 / 站点型源 / 网页播放页 / 小程序 / 在线阅读 / 网页首页 都会套用；
///   · 网页里那个悬浮球点选的广告，也会变成一条规则出现在下面。
///
/// 注意与**播放地址层**的过滤（`AdFilterService`，数据来自订阅配置的
/// `ads` / `rules`）不是一回事：那个拦的是播放地址，配置在订阅里，不在这一页。
///
/// UI 约定（用户 2026-10-16）：「弹窗要卡片/网格，不要列表」⇒
///   · 内置规则、我的规则都用**卡片网格**（一行两个）呈现，点卡片即开关；
///   · 新增规则的弹窗也是**卡片**（选作用范围 + 选域名的卡片），不是表单列表。
class AdBlockSettingsPage extends StatefulWidget {
  const AdBlockSettingsPage({super.key});

  @override
  State<AdBlockSettingsPage> createState() => _AdBlockSettingsPageState();
}

class _AdBlockSettingsPageState extends State<AdBlockSettingsPage> {
  final _svc = AdBlockService.instance;

  /// 每条内置选择器的**中文说明** —— 让用户一眼看懂"填的是什么内容"
  static const Map<String, String> _notes = {
    '.adsbygoogle': 'Google 广告位',
    'ins.adsbygoogle': 'Google 广告位（ins）',
    'iframe[src*="doubleclick"]': 'DoubleClick 广告框',
    'iframe[src*="googlesyndication"]': 'Google 广告联盟框',
    'iframe[src*="googleadservices"]': 'Google 广告服务框',
    '[id^="ad_"]': 'id 以 ad_ 开头',
    '[class^="ad_"]': 'class 以 ad_ 开头',
    '[class*="advert"]': '名字含 advert',
    '[id*="advert"]': 'id 含 advert',
    '[class*="ad-banner"]': '横幅广告位',
    '[class*="banner-ad"]': '横幅广告位（倒写）',
    '[class*="popup-ad"]': '弹窗广告',
    '[class*="pop-under"]': 'pop-under 弹窗',
    '[class*="float-ad"]': '漂浮广告',
    '[class*="ad-overlay"]': '广告蒙层',
    '[class*="ad-mask"]': '广告遮罩',
  };

  @override
  void initState() {
    super.initState();
    _svc.ensureLoaded();
  }

  // ============================================================
  // 新增规则：**卡片式弹窗**（不是表单列表）
  // ============================================================
  Future<void> _addRuleSheet() async {
    var scopeAll = true;
    var host = '';
    final selCtrl = TextEditingController();
    final hostCtrl = TextEditingController();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: 16 + MediaQuery.of(ctx).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('加到哪些网站',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                // 两块卡片二选一（不用 RadioListTile 那种列表样式）
                Row(
                  children: [
                    Expanded(
                      child: _pickCard(
                        title: '所有网站',
                        subtitle: '任何网页都隐藏',
                        selected: scopeAll,
                        onTap: () => setSheet(() => scopeAll = true),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _pickCard(
                        title: '指定网站',
                        subtitle: '只在某个域名下',
                        selected: !scopeAll,
                        onTap: () => setSheet(() => scopeAll = false),
                      ),
                    ),
                  ],
                ),
                if (!scopeAll) ...[
                  const SizedBox(height: 10),
                  _field(
                    controller: hostCtrl,
                    hint: 'example.com（含子域）',
                    label: '域名',
                    onChanged: (v) => host = v,
                  ),
                ],
                const SizedBox(height: 16),
                Text('选择器',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontHeadline,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text('例：.ad-banner　#ads　div[class*="gg"]　（一行一条，可一次粘多条）',
                    style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption)),
                const SizedBox(height: 8),
                _field(
                  controller: selCtrl,
                  hint: '.ad-banner',
                  label: 'CSS 选择器',
                  mono: true,
                  maxLines: 4,
                  autofocus: true,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => Navigator.pop(ctx),
                        child: const Text('取消'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton(
                        onPressed: () async {
                          final raw = selCtrl.text.trim();
                          if (raw.isEmpty) {
                            AppToast.message('先填一个选择器');
                            return;
                          }
                          // 多行时按"每行一条"处理；域名只对"指定网站"那张卡生效
                          final text = scopeAll
                              ? raw.split('\n').map((l) => l.trim()).join('\n')
                              : raw
                                  .split('\n')
                                  .map((l) => l.trim())
                                  .where((l) => l.isNotEmpty)
                                  .map((l) => '${host.trim()}##$l')
                                  .join('\n');
                          final (ok, skip) = await _svc.importText(text);
                          if (ctx.mounted) Navigator.pop(ctx);
                          AppToast.message(ok > 0
                              ? '已添加 $ok 条${skip > 0 ? '，跳过 $skip 条' : ''}'
                              : '没识别出规则，检查一下写法');
                        },
                        child: const Text('添加'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 弹窗里的"选项卡片"（选中 = 强调色描边）
  Widget _pickCard({
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppTheme.accentColor : AppTheme.borderLight,
            width: selected ? 1.4 : 0.6,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(selected ? Icons.check_circle_rounded : Icons.circle_outlined,
                    size: 15,
                    color: selected ? AppTheme.accentColor : AppTheme.textTertiary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: AppTheme.fontFootnote,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontCaption)),
          ],
        ),
      ),
    );
  }

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required String label,
    bool mono = false,
    int maxLines = 1,
    bool autofocus = false,
    ValueChanged<String>? onChanged,
  }) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      autofocus: autofocus,
      onChanged: onChanged,
      style: TextStyle(
        color: AppTheme.textPrimary,
        fontSize: mono ? AppTheme.fontFootnote : AppTheme.fontSubhead,
        fontFamily: mono ? 'monospace' : null,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: AppTheme.textTertiary),
        hintStyle: TextStyle(color: AppTheme.textTertiary),
        border: const OutlineInputBorder(),
      ),
    );
  }

  Future<void> _importFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text ?? '';
    if (text.trim().isEmpty) {
      AppToast.message('剪贴板是空的');
      return;
    }
    final (ok, skip) = await _svc.importText(text);
    if (!mounted) return;
    AppToast.message(ok > 0
        ? '导入 $ok 条${skip > 0 ? '，跳过 $skip 条（网络过滤语法不支持）' : ''}'
        : '没识别出规则（uBlock 的 ||域名^ 这类要拦请求，本模块做不到）');
  }

  Future<void> _editRule(AdBlockRule r) async {
    final text = await SettingsDialogs.editText(
      context: context,
      title: '编辑规则',
      initial: r.asText,
      hint: '域名##选择器',
      helper: r.host.isEmpty ? '当前：所有网站' : '当前：${r.host}',
    );
    if (text == null || text.trim().isEmpty) return;
    await _svc.removeRule(r);
    await _svc.importText(text);
    if (mounted) AppToast.message('已更新');
  }

  Future<void> _clearAll() async {
    final ok = await SettingsDialogs.confirm(
      context: context,
      title: '清空全部规则？',
      message: '手选和导入的规则都会被删掉（内置通用选择器不受影响）',
    );
    if (ok != true) return;
    await _svc.clearRules();
    if (mounted) AppToast.message('已清空');
  }

  // ── CSS 过滤器（整份注入）──────────────────────────────────

  Future<void> _importLimbo() => _importFilterUrl(AdBlockService.kLimboCssUrl);

  Future<void> _importAnyFilter() async {
    final u = await SettingsDialogs.editText(
      context: context,
      title: '从网址导入 CSS 过滤器',
      initial: '',
      hint: 'https://…/xxx.css',
      helper: '只要是一份 CSS（元素隐藏规则）就行；'
          'Quantumult X / Surge 那种 rewrite 规则不吃',
    );
    if (u == null || u.trim().isEmpty) return;
    await _importFilterUrl(u.trim());
  }

  Future<void> _importFilterUrl(String url) async {
    AppToast.message('正在下载…');
    final (ok, msg) = await _svc.importFilterFromUrl(url);
    if (!mounted) return;
    if (ok) {
      AppToast.message(msg);
    } else {
      AppToast.error(msg);
    }
  }

  Future<void> _revertFilter() async {
    final ok = await SettingsDialogs.confirm(
      context: context,
      title: '恢复内置版？',
      message: '导入的那份会被删除，回到随包的 18008 条通用选择器',
    );
    if (ok != true) return;
    await _svc.revertToBuiltinFilter();
    if (mounted) AppToast.message('已恢复内置版');
  }

  Future<void> _copyLimboHome() async {
    await Clipboard.setData(const ClipboardData(text: AdBlockService.kLimboHome));
    if (mounted) AppToast.message('来源已复制');
  }

  String _short(String s) => s.length <= 40 ? s : '${s.substring(0, 38)}…';

  /// 一行两个的卡片网格（用外层宽度算，避免 GridView 的滚动嵌套）
  Widget _grid(BuildContext context, List<Widget> cards) {
    return LayoutBuilder(
      builder: (_, c) {
        final w = (c.maxWidth - 10) / 2;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final x in cards) SizedBox(width: w, child: x),
          ],
        );
      },
    );
  }

  /// 内置通用选择器卡片：点一下开关这一条
  Widget _builtinCard(String sel) {
    final on = _svc.builtinItemEnabled(sel);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _svc.setBuiltinItemEnabled(sel, !on),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: on ? AppTheme.accentColor : AppTheme.borderLight,
            width: on ? 1.2 : 0.6,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(on ? Icons.check_circle_rounded : Icons.circle_outlined,
                    size: 14,
                    color: on ? AppTheme.accentColor : AppTheme.textTertiary),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(_notes[sel] ?? '通用广告位',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: AppTheme.fontCaption)),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(sel,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontCaption,
                    fontFamily: 'monospace',
                    height: 1.25)),
          ],
        ),
      ),
    );
  }

  /// 我的规则卡片：点卡片开关；右上角 ✕ 删除；长按改
  Widget _ruleCard(AdBlockRule r) {
    final on = r.enabled && _svc.enabled;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _svc.setRuleEnabled(r, !r.enabled),
      onLongPress: () => _editRule(r),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 6, 10),
        decoration: BoxDecoration(
          color: AppTheme.backgroundTertiary,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: on ? AppTheme.accentColor : AppTheme.borderLight,
            width: on ? 1.2 : 0.6,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(on ? Icons.check_circle_rounded : Icons.circle_outlined,
                    size: 14,
                    color: on ? AppTheme.accentColor : AppTheme.textTertiary),
                const SizedBox(width: 5),
                Expanded(
                  child: Text(r.host.isEmpty ? '所有网站' : r.host,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: AppTheme.fontCaption)),
                ),
                InkWell(
                  onTap: () => _svc.removeRule(r),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(Icons.close_rounded,
                        size: 14, color: AppTheme.textTertiary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 5),
            Text(_short(r.selector),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: AppTheme.fontCaption,
                    fontFamily: 'monospace',
                    height: 1.25)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _svc,
      builder: (context, _) => SettingsSubPage(
        title: '广告管理',
        children: [
          SettingsGroup(
            children: [
              SettingsRow(
                icon: Icons.block_rounded,
                title: '网页去广告',
                subtitle: 'RSS · 站点型源 · 网页播放页 · 小程序 · 在线阅读 · 网页首页',
                trailingSwitch: true,
                switchValue: _svc.enabled,
                onSwitchChanged: (v) => _svc.setEnabled(v),
              ),
              SettingsRow(
                icon: Icons.ads_click_rounded,
                title: '悬浮按钮',
                subtitle: '网页里显示一个圆钮：点它再点广告即可隐藏',
                trailingSwitch: true,
                switchValue: _svc.showBubble,
                onSwitchChanged: (v) => _svc.setShowBubble(v),
              ),
            ],
          ),

          SettingsGroup(
            title: '内置通用选择器（点卡片开关）',
            hint: '这些是"名字里明确就是广告"的通用位；站点自己的广告靠悬浮球点选，'
                '点出来的规则会出现在下面「我的规则」里。',
            children: [
              _grid(context, [
                for (final s in AdBlockService.kBuiltinSelectors) _builtinCard(s),
              ]),
            ],
          ),

          SettingsGroup(
            title: 'CSS 过滤器（整份注入 · 已内置）',
            hint: '默认用**内置版**：来自 Adblock4limbo（MIT）的 18008 条通用广告选择器，'
                '不用联网就生效。毒奶那套 .conf 是 Quantumult X 的 rewrite（拦请求 / '
                '改响应体，需要 MITM），webview 吃不下；能吃的是它背后这份 CSS。',
            children: [
              SettingsRow(
                icon: Icons.code_rounded,
                title: 'CSS 过滤器',
                subtitle: _svc.hasFilter
                    ? '${(_svc.filterBytes / 1024).round()} KB · ${_svc.filterOriginLabel}'
                        '${_svc.filterIsCustom ? ' · ${_svc.filterSource}' : ''}'
                    : '读不到内置过滤器（asset 缺失？）',
                trailingSwitch: true,
                switchValue: _svc.filterSwitch,
                onSwitchChanged: (v) => _svc.setFilterEnabled(v),
              ),
              SettingsRow(
                icon: Icons.download_rounded,
                title: _svc.filterIsCustom ? '联网更新（覆盖自定义）' : '联网更新内置版',
                subtitle: '约 320 KB；更新后会变成"自定义"',
                onTap: _importLimbo,
              ),
              SettingsRow(
                icon: Icons.link_rounded,
                title: '换成其它网址的 CSS',
                onTap: _importAnyFilter,
              ),
              if (_svc.filterIsCustom)
                SettingsRow(
                  icon: Icons.settings_backup_restore_rounded,
                  title: '恢复内置版',
                  subtitle: '删掉导入的那份，回到随包的 18008 条',
                  onTap: _revertFilter,
                ),
            ],
          ),

          SettingsGroup(
            title: '我的规则（${_svc.rules.length}）',
            hint: _svc.rules.isEmpty
                ? '还没有：打开任意网页/RSS 正文，点右下角圆钮再点广告即可添加。'
                : '点卡片 = 开关这条；右上角 ✕ = 删除；长按 = 改域名/选择器。',
            children: [
              if (_svc.rules.isEmpty)
                SettingsRow(
                  icon: Icons.info_outline_rounded,
                  title: '还没有手选规则',
                  subtitle: '网页里点悬浮球 → 点广告 → 保存，就会出现在这里',
                  onTap: _addRuleSheet,
                )
              else
                _grid(context, [for (final r in _svc.rules) _ruleCard(r)]),
            ],
          ),

          SettingsGroup(
            children: [
              SettingsRow(
                icon: Icons.add_rounded,
                title: '手动加一条规则',
                value: '卡片式',
                onTap: _addRuleSheet,
              ),
              SettingsRow(
                icon: Icons.content_paste_rounded,
                title: '从剪贴板导入',
                subtitle: '支持 uBlock / AdGuard 的「元素隐藏」写法',
                onTap: _importFromClipboard,
              ),
              SettingsRow(
                icon: Icons.delete_sweep_rounded,
                title: '清空我的规则',
                value: '${_svc.rules.length} 条',
                onTap: _svc.rules.isEmpty ? null : _clearAll,
              ),
            ],
          ),

          SettingsGroup(
            title: '说明',
            children: [
              const SettingsRow(
                icon: Icons.help_outline_rounded,
                title: '为什么有些规则导入不了',
                subtitle: '本模块靠"给网页注入 CSS"隐藏元素，所以只支持选择器写法；'
                    'uBlock 的 ||域名^ / /ads/* 属于拦请求，webview 拿不到请求层，做不到',
              ),
              const SettingsRow(
                icon: Icons.warning_amber_rounded,
                title: '选择器别写太宽',
                subtitle: '像 [class*="ad"] 会误伤 adaptive / load / header 这类正常元素，'
                    '尽量带上连字符或明确单词（.ad-banner、#ads）',
              ),
              SettingsRow(
                icon: Icons.copyright_rounded,
                title: '内置过滤器的来源',
                subtitle: 'Adblock4limbo · MIT License · github.com/limbopro/Adblock4limbo'
                    '（点一下复制地址）',
                onTap: _copyLimboHome,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
