import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../common/theme.dart';
import '../../../services/music_service.dart';
import '../../../widgets/common_widgets.dart';
import 'settings_shared.dart';

/// 设置 → 音乐音源
///
/// 按「最小公约数」对接任意 HTTP 音源：填地址即可，协议自适应
/// （模板占位符 / Aurora 约定 / 直接拼 query 参数）。
class MusicSourceSettingsPage extends StatefulWidget {
  const MusicSourceSettingsPage({super.key});

  @override
  State<MusicSourceSettingsPage> createState() =>
      _MusicSourceSettingsPageState();
}

class _MusicSourceSettingsPageState extends State<MusicSourceSettingsPage> {
  MusicService get svc => MusicService.instance;

  late final TextEditingController _urlCtrl =
      TextEditingController(text: svc.sourceUrl.value);
  late final TextEditingController _headersCtrl =
      TextEditingController(text: svc.headersJson.value);

  bool _testing = false;

  @override
  void dispose() {
    _urlCtrl.dispose();
    _headersCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '音乐音源',
      children: [
        // ---------- 地址 ----------
        AppCard(
          dense: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _label('音源地址'),
              _field(
                controller: _urlCtrl,
                hint: 'https://host/aurora?key=xxx',
                onChanged: svc.setSourceUrl,
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 2, right: 2),
                child: Text(
                  '支持三种写法：\n'
                  '· 服务地址（推荐）：自动补 /aurora?query=…&quality=…\n'
                  '· 含 {query} 的模板：原样替换，适配第三方接口\n'
                  '· 其它地址：直接把 query 作为查询参数拼上\n'
                  '密钥直接写在链接里（如 ?key=xxx）即可。',
                  style: TextStyle(
                      color: AppTheme.textTertiary,
                      fontSize: AppTheme.fontCaption,
                      height: 1.55),
                ),
              ),
              const SizedBox(height: 14),
              _label('期望音质'),
              const SizedBox(height: 6),
              _qualitySelector(),
              const SizedBox(height: 14),
              _label('自定义请求头（可选）'),
              _field(
                controller: _headersCtrl,
                hint: '{"Referer":"https://music.163.com"}',
                onChanged: svc.setHeaders,
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 2, right: 2),
                child: Text('JSON 对象，用于鉴权或特定 Referer / User-Agent。',
                    style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                        height: 1.5)),
              ),
              const SizedBox(height: 16),
              // 保存 + 测试
              Row(
                children: [
                  Expanded(
                    child: _button(
                      '保存',
                      filled: true,
                      onTap: () async {
                        // 先取 messenger：await 之后再用 context 会跨异步间隙
                        final messenger = ScaffoldMessenger.of(context);
                        await svc.setSourceUrl(_urlCtrl.text);
                        await svc.setHeaders(_headersCtrl.text);
                        if (!mounted) return;
                        messenger.showSnackBar(
                            const SnackBar(content: Text('已保存')));
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _button(
                      _testing ? '测试中…' : '测试连接',
                      filled: false,
                      onTap: _testing ? null : _runTest,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- 说明 ----------
        SettingsGroup(
          title: '关于',
          children: [
            SettingsRow(
              icon: Icons.info_outline,
              title: 'App 不内置任何音源',
              subtitle: '在线搜索与试听依赖你自行部署的 HTTP 接口',
              value: '',
            ),
            SettingsRow(
              icon: Icons.code,
              title: '响应格式',
              subtitle: '数组 或 {results}/{data}/{songs}/{list} 包裹；'
                  '每项需含 title 与 audioUrl',
              value: '',
            ),
            SettingsRow(
              icon: Icons.swap_horiz,
              title: '字段别名兼容',
              subtitle: 'title/songName/name、artist/singer、cover/pic 等自动识别',
              value: '',
            ),
          ],
        ),
        const SizedBox(height: AppTheme.spacingLG),

        // ---------- 当前状态 ----------
        Obx(() => SettingsGroup(
              title: '当前状态',
              children: [
                SettingsRow(
                  icon: svc.configured
                      ? Icons.check_circle_outline
                      : Icons.error_outline,
                  iconColor:
                      svc.configured ? AppTheme.accentColor : Colors.orange,
                  title: '音源',
                  subtitle: svc.configured
                      ? svc.sourceUrl.value
                      : '未配置，音乐页会显示引导',
                  value: svc.configured ? '已配置' : '未配置',
                ),
                SettingsRow(
                  icon: Icons.high_quality_outlined,
                  title: '音质',
                  subtitle: '搜索时作为 quality 参数传给音源',
                  value: svc.quality.value,
                ),
              ],
            )),
      ],
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 6),
        child: Text(t,
            style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: AppTheme.fontSubhead)),
      );

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required ValueChanged<String> onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.backgroundTertiary,
        borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
        border: Border.all(color: AppTheme.borderLight, width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        cursorColor: AppTheme.accentColor,
        style: TextStyle(color: AppTheme.textPrimary, fontSize: 13.5),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle:
              TextStyle(color: AppTheme.textTertiary, fontSize: 12.5),
          border: InputBorder.none,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }

  Widget _qualitySelector() {
    const opts = [('128', '128k'), ('320', '320k'), ('flac', 'FLAC')];
    return Obx(() => Container(
          height: 38,
          decoration: BoxDecoration(
            color: AppTheme.backgroundTertiary,
            borderRadius: BorderRadius.circular(AppTheme.glassRadiusSmall),
          ),
          child: Row(
            children: [
              for (var i = 0; i < opts.length; i++) ...[
                if (i > 0)
                  Container(
                    width: 1,
                    height: 15,
                    color: AppTheme.borderMedium.withValues(alpha: 0.6),
                  ),
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => svc.setQuality(opts[i].$1),
                    child: Container(
                      alignment: Alignment.center,
                      margin: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: svc.quality.value == opts[i].$1
                            ? AppTheme.backgroundElevated
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(9),
                        border: svc.quality.value == opts[i].$1
                            ? Border.all(
                                color: AppTheme.glassBorder, width: 0.6)
                            : null,
                      ),
                      child: Text(
                        opts[i].$2,
                        style: TextStyle(
                          color: svc.quality.value == opts[i].$1
                              ? AppTheme.textPrimary
                              : AppTheme.textSecondary,
                          fontSize: AppTheme.fontSubhead,
                          fontWeight: svc.quality.value == opts[i].$1
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
        ));
  }

  Widget _button(String text,
      {required bool filled, VoidCallback? onTap}) {
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

  Future<void> _runTest() async {
    // 先落盘，保证测的就是当前填的
    await svc.setSourceUrl(_urlCtrl.text);
    await svc.setHeaders(_headersCtrl.text);
    if (!mounted) return;
    setState(() => _testing = true);
    final r = await svc.testConnection();
    if (!mounted) return;
    setState(() => _testing = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(r.message),
      backgroundColor: r.ok ? null : Colors.redAccent,
    ));
  }
}
