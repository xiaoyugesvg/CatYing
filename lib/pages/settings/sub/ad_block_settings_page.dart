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
///   · RSS 正文 / 站点型源内嵌网页 / 网页播放页 都会自动套用这里的规则；
///   · 网页里那个悬浮球点选的广告，也会变成一条规则出现在下面。
///
/// 注意与**播放地址层**的过滤（`AdFilterService`，数据来自订阅配置的
/// `ads` / `rules`）不是一回事：那个拦的是播放地址，配置在订阅里，不在这一页。
class AdBlockSettingsPage extends StatefulWidget {
  const AdBlockSettingsPage({super.key});

  @override
  State<AdBlockSettingsPage> createState() => _AdBlockSettingsPageState();
}

class _AdBlockSettingsPageState extends State<AdBlockSettingsPage> {
  final _svc = AdBlockService.instance;

  @override
  void initState() {
    super.initState();
    _svc.ensureLoaded();
  }

  /// 新增 = 支持一次粘贴多条（与「从剪贴板导入」共用同一套解析）
  Future<void> _addRules() async {
    final text = await SettingsDialogs.editText(
      context: context,
      title: '新增 / 粘贴规则',
      initial: '##',
      hint: '域名##选择器，一行一条',
      helper: '例：\nexample.com##.ad-box\n.adsbygoogle        （不写域名 = 所有网站）',
      maxLines: 6,
    );
    if (text == null || text.trim().isEmpty) return;
    final (ok, skip) = await _svc.importText(text);
    if (!mounted) return;
    AppToast.message(ok > 0
        ? '新增 $ok 条${skip > 0 ? '，跳过 $skip 条' : ''}'
        : '没识别出规则（只支持「元素隐藏」选择器）');
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
        : '没识别出规则（uBlock 的 ||域名^ 这类要拦截请求，本模块做不到）');
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

  String _short(String s) => s.length <= 46 ? s : '${s.substring(0, 44)}…';

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
                subtitle: 'RSS 正文 / 站点型源 / 网页播放页 / 小程序 / 在线阅读',
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
              SettingsRow(
                icon: Icons.auto_awesome_rounded,
                title: '内置通用选择器',
                subtitle: '${AdBlockService.kBuiltinSelectors.length} 条通用广告位规则',
                trailingSwitch: true,
                switchValue: _svc.builtinEnabled,
                onSwitchChanged: (v) => _svc.setBuiltinEnabled(v),
              ),
            ],
          ),
          SettingsGroup(
            children: [
              SettingsRow(
                icon: Icons.add_rounded,
                title: '新增规则',
                value: '可粘贴多条',
                onTap: _addRules,
              ),
              SettingsRow(
                icon: Icons.content_paste_rounded,
                title: '从剪贴板导入',
                subtitle: '支持 uBlock / AdGuard 的「元素隐藏」写法',
                onTap: _importFromClipboard,
              ),
              SettingsRow(
                icon: Icons.delete_sweep_rounded,
                title: '清空全部规则',
                value: '${_svc.rules.length} 条',
                onTap: _svc.rules.isEmpty ? null : _clearAll,
              ),
            ],
          ),
          if (_svc.rules.isNotEmpty)
            SettingsGroup(
              children: [
                for (final r in _svc.rules)
                  SettingsRow(
                    icon: Icons.visibility_off_rounded,
                    title: _short(r.selector),
                    subtitle: r.host.isEmpty ? '所有网站' : r.host,
                    switchEnabled: _svc.enabled,
                    trailingSwitch: true,
                    switchValue: r.enabled,
                    onSwitchChanged: (v) => _svc.setRuleEnabled(r, v),
                    onTap: () => _editRule(r),
                    trailing: IconButton(
                      tooltip: '删除',
                      icon: Icon(Icons.close_rounded,
                          size: 16, color: AppTheme.textTertiary),
                      onPressed: () => _svc.removeRule(r),
                    ),
                  ),
              ],
            )
          else
            SettingsGroup(
              children: const [
                SettingsRow(
                  icon: Icons.info_outline_rounded,
                  title: '还没有手选规则',
                  subtitle: '打开任意网页/RSS 正文，点右下角圆钮再点广告即可添加',
                ),
              ],
            ),
          SettingsGroup(
            children: const [
              SettingsRow(
                icon: Icons.help_outline_rounded,
                title: '为什么有些规则导入不了',
                subtitle:
                    '本模块靠"给网页注入 CSS"隐藏元素，所以只支持选择器写法；'
                    'uBlock 的 ||域名^ / /ads/* 属于拦请求，webview 拿不到请求层，做不到',
              ),
            ],
          ),
        ],
      ),
    );
  }
}
