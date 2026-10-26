import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/models/subscription.dart';
import 'package:tvbox/services/moontv_converter.dart';
import 'package:tvbox/services/network_manager.dart';
import 'package:tvbox/widgets/app_toast.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/pages/settings/controller.dart';
import 'package:tvbox/pages/settings/sub/settings_shared.dart';

/// 影视模块 · 影视仓转换器。
///
/// 输入 MoonTV / LunaTV 的 `video.json`（地址或直接粘贴 JSON），
/// 把其中的 `api_site` 转成标准 TVBox `sites`，保存成订阅并立即启用。
///
/// 说明：
///   · 输入是**远程地址** → 订阅里存原地址，`ApiConfig` 每次加载时现场转换，
///     上游更新后重新加载即可，不需要重新点转换。
///   · 输入是**粘贴的 JSON** → 转换结果落到 Documents，订阅地址用
///     `local://<name>` 伪协议引用（见 ConvertedConfigStore）。
class MoonTvConverterPage extends StatefulWidget {
  const MoonTvConverterPage({super.key});

  @override
  State<MoonTvConverterPage> createState() => _MoonTvConverterPageState();
}

class _MoonTvConverterPageState extends State<MoonTvConverterPage> {
  final _input = TextEditingController();

  bool _busy = false;
  String? _error;
  String? _warningsText;

  /// 预览用站点（MoonTV 与「已是 TVBox」两种输入都会填）
  List<MoonTvSite> _sites = const [];

  /// 输入是 URL 时保存原地址；粘贴 JSON 时为空
  String? _sourceUrl;

  /// 需要写入本地的配置文本（仅粘贴 JSON 时使用）
  String? _localJson;

  bool get _hasResult => _sites.isNotEmpty;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  Future<void> _convert() async {
    final text = _input.text.trim();
    if (text.isEmpty) {
      AppToast.message('请输入 video.json 地址或粘贴 JSON');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
      _warningsText = null;
      _sites = const [];
      _sourceUrl = null;
      _localJson = null;
    });

    try {
      final isJson = text.startsWith('{') || text.startsWith('[');
      if (!isJson &&
          !text.startsWith('http://') &&
          !text.startsWith('https://')) {
        throw '请输入 http(s) 地址，或直接粘贴 JSON';
      }

      final raw = isJson ? text : await NetworkManager.instance.getString(text);
      final decoded = jsonDecode(raw);

      // 已经是 TVBox 配置：不需要转换，直接可存
      if (MoonTvConverter.isTvBoxConfig(decoded)) {
        final list = (decoded['sites'] as List)
            .whereType<Map>()
            .map((e) => MoonTvSite(
                  key: '${e['key'] ?? ''}',
                  name: '${e['name'] ?? e['key'] ?? '未命名'}',
                  api: '${e['api'] ?? ''}',
                  detail: '',
                ))
            .where((e) => e.api.isNotEmpty)
            .toList();
        setState(() {
          _sites = list;
          _sourceUrl = isJson ? null : text;
          _localJson = isJson ? raw : null;
          _warningsText = list.isEmpty ? '配置里没有可用的站点' : null;
          _busy = false;
        });
        return;
      }

      final result = MoonTvConverter.tryConvert(decoded);
      if (result == null) {
        throw '不是 MoonTV / LunaTV 的影视仓（缺少 api_site 字段）';
      }
      setState(() {
        _sites = result.sites;
        _sourceUrl = isJson ? null : text;
        _localJson = isJson ? result.toJsonString() : null;
        _warningsText = result.warnings.isEmpty
            ? null
            : '已跳过 ${result.warnings.length} 条：\n${result.warnings.take(8).join('\n')}'
                '${result.warnings.length > 8 ? '\n…' : ''}';
        _busy = false;
      });
    } catch (e) {
      setState(() {
        _error = '$e';
        _busy = false;
      });
    }
  }

  Future<void> _pickFile() async {
    try {
      final f = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const ['json', 'txt'],
      );
      if (f == null) return;
      final text = utf8.decode(await f.readAsBytes(), allowMalformed: true);
      if (text.trim().isEmpty) {
        AppToast.message('文件为空或无法读取');
        return;
      }
      _input.text = text;
      await _convert();
    } catch (e) {
      AppToast.message('选择文件失败：$e');
    }
  }

  Future<void> _saveAndActivate() async {
    if (!_hasResult) return;
    setState(() => _busy = true);
    try {
      final svc = SubscriptionService.instance;
      final label = '影视仓 · ${_sites.length} 个源';

      String url;
      if (_sourceUrl != null) {
        url = _sourceUrl!;
      } else {
        final json = _localJson ??
            MoonTvConvertResult(sites: _sites, warnings: const [])
                .toJsonString();
        final name = 'moontv_${DateTime.now().millisecondsSinceEpoch}';
        url = await ConvertedConfigStore.write(name, json);
      }

      final sub = await svc.add(
        url: url,
        name: label,
        kind: SubscriptionKind.tvbox,
      );
      await svc.setActive(sub.id);

      final sc = Get.isRegistered<SettingsController>()
          ? Get.find<SettingsController>()
          : Get.put(SettingsController());
      sc.vodApiUrl.value = sub.url;
      await sc.loadConfig();

      if (!mounted) return;
      setState(() => _busy = false);
      if (sc.configError.value != null) {
        AppToast.message('已保存为订阅，但加载失败：${sc.configError.value}');
      } else {
        AppToast.message('已保存并启用「$label」');
        Get.back();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      AppToast.message('保存失败：$e');
    }
  }

  void _copyResult() {
    final json = _localJson ??
        MoonTvConvertResult(sites: _sites, warnings: const []).toJsonString();
    Clipboard.setData(ClipboardData(text: json));
    AppToast.message('转换结果已复制（标准 TVBox JSON）');
  }

  @override
  Widget build(BuildContext context) {
    return SettingsSubPage(
      title: '影视仓转换器',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 12),
          child: Text(
            '支持 MoonTV / LunaTV 的 video.json（api_site 格式）。'
            '转换后就是标准 TVBox 站点，可直接保存为订阅并启用。',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: AppTheme.fontFootnote,
              height: 1.5,
            ),
          ),
        ),
        AppCard(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _input,
                minLines: 3,
                maxLines: 8,
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: AppTheme.fontSubhead,
                  height: 1.4,
                ),
                decoration: InputDecoration(
                  hintText: 'https://…/video.json\n或直接粘贴 {"api_site":{…}}',
                  hintStyle: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: AppTheme.fontFootnote,
                  ),
                  filled: true,
                  fillColor: AppTheme.backgroundTertiary,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AppTheme.radiusSM),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 40,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : _convert,
                        icon: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.swap_horiz_rounded, size: 18),
                        label: Text(_busy ? '转换中…' : '转换'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.accentOnSurface,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(AppTheme.radiusSM),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    height: 40,
                    child: OutlinedButton(
                      onPressed: _busy ? null : _pickFile,
                      child: const Text('导入文件'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  SizedBox(
                    height: 40,
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                                _input.clear();
                                _sites = const [];
                                _error = null;
                                _warningsText = null;
                                _sourceUrl = null;
                                _localJson = null;
                              }),
                      child: const Text('清空'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          _notice(_error!, danger: true),
        ],
        if (_warningsText != null) ...[
          const SizedBox(height: 12),
          _notice(_warningsText!),
        ],
        if (_hasResult) ...[
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
            child: Text(
              '转换结果 · ${_sites.length} 个源'
              '${_sourceUrl == null ? "（保存到本地）" : "（订阅原地址，自动跟随更新）"}',
              style: TextStyle(
                color: AppTheme.textTertiary,
                fontSize: AppTheme.fontCaption,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ),
          AppCard(
            dense: true,
            child: Column(
              children: [
                for (var i = 0; i < _sites.length && i < 80; i++) ...[
                  if (i > 0)
                    Divider(
                      color: AppTheme.borderLight,
                      height: 1,
                      thickness: 0.5,
                    ),
                  ListTile(
                    dense: true,
                    visualDensity: VisualDensity.compact,
                    title: Text(
                      _sites[i].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: AppTheme.fontSubhead,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: Text(
                      _sites[i].api,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                      ),
                    ),
                  ),
                ],
                if (_sites.length > 80)
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text(
                      '仅预览前 80 个，实际已全部转换',
                      style: TextStyle(
                        color: AppTheme.textTertiary,
                        fontSize: AppTheme.fontCaption,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: FilledButton(
                    onPressed: _busy ? null : _saveAndActivate,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accentOnSurface,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppTheme.radiusSM),
                      ),
                    ),
                    child: const Text('保存为订阅并启用'),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 44,
                child: OutlinedButton(
                  onPressed: _busy ? null : _copyResult,
                  child: const Text('复制 JSON'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  Widget _notice(String text, {bool danger = false}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: (danger ? Colors.redAccent : AppTheme.accentOnSurface)
            .withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppTheme.radiusSM),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: danger ? Colors.redAccent : AppTheme.textSecondary,
          fontSize: AppTheme.fontCaption,
          height: 1.5,
        ),
      ),
    );
  }
}
