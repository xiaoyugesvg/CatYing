import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/common/theme.dart';
import 'package:tvbox/widgets/common_widgets.dart';
import 'package:tvbox/reading/services/ai_service.dart';
import 'package:tvbox/pages/settings/sub/log_diagnosis_page.dart';

/// 一个候选模型。[free] 表示「不花钱就能用」（免费层 / `:free` 后缀）。
class _ModelItem {
  const _ModelItem(this.id, {this.free = false});
  final String id;
  final bool free;
}

/// 一家 AI 服务商的预设（都是 OpenAI 兼容接口）
class _Provider {
  const _Provider(
    this.name,
    this.baseUrl,
    this.model,
    this.hint,
    this.models,
  );
  final String name;
  final String baseUrl;
  final String model;
  final String hint;

  /// 内置候选模型（离线可用；`models` 接口拉不到时也能选）
  final List<_ModelItem> models;
}

const List<_Provider> _providers = [
  // OpenRouter 放第一个（用户 2026-10-27：「将 openrouter 放在第一个」）。
  // 聚合网关，带 `:free` 后缀的模型真免费（有限速）。
  // ⚠️ 2026-10-27：原来的默认模型 `deepseek/deepseek-chat-v3-0324:free`
  //   已被官方下架（返回 404「This model is unavailable for free」），
  //   换成官方的**免费路由** `openrouter/free` —— 它会自动挑一个当前
  //   可用的免费模型，不会因为某个免费模型下架就整个失效。
  _Provider(
    'OpenRouter',
    'https://openrouter.ai/api/v1',
    'openrouter/free',
    '免费路由 openrouter/free',
    [
      _ModelItem('openrouter/free', free: true),
      _ModelItem('nvidia/nemotron-3-ultra-550b-a55b:free', free: true),
      _ModelItem(
          'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free', free: true),
      _ModelItem('nvidia/nemotron-3.5-lightning:free', free: true),
      _ModelItem('nvidia/nemotron-3.5-super-vl:free', free: true),
      _ModelItem('nvidia/nemotron-3.5-content-safety:free', free: true),
      _ModelItem('cohere/north-mini-code:free', free: true),
      _ModelItem('poolside/laguna-s-2.1:free', free: true),
      _ModelItem('dots-studio/dots-3-note-preview:free', free: true),
      _ModelItem('xingchen-agi/xing4.0-29b-a4b:free', free: true),
      _ModelItem('google/gemma-4-31b-it:free', free: true),
      _ModelItem('thinkingmachines/inkling:free', free: true),
      _ModelItem('deepseek/deepseek-chat'),
    ],
  ),
  _Provider('DeepSeek', 'https://api.deepseek.com', 'deepseek-chat', '便宜、中文好', [
    _ModelItem('deepseek-chat'),
    _ModelItem('deepseek-reasoner'),
  ]),
  _Provider('OpenAI', 'https://api.openai.com', 'gpt-4o-mini', '需外网', [
    _ModelItem('gpt-4o-mini'),
    _ModelItem('gpt-4o'),
    _ModelItem('gpt-4.1-mini'),
  ]),
  _Provider(
    '通义千问',
    'https://dashscope.aliyuncs.com/compatible-mode/v1',
    'qwen-plus',
    '阿里云',
    [
      _ModelItem('qwen-plus'),
      _ModelItem('qwen-turbo', free: true), // 有免费额度
      _ModelItem('qwen-max'),
      _ModelItem('qwen-long'),
    ],
  ),
  _Provider('Kimi', 'https://api.moonshot.cn', 'moonshot-v1-8k', '长文本', [
    _ModelItem('moonshot-v1-8k'),
    _ModelItem('moonshot-v1-32k'),
    _ModelItem('moonshot-v1-128k'),
  ]),
  _Provider(
    '智谱',
    'https://open.bigmodel.cn/api/paas/v4',
    // 2026-10 官方免费模型：GLM-4.7-Flash（输入/输出/缓存全免费，200K 上下文）
    'glm-4.7-flash',
    '免费（glm-4.7-flash）',
    [
      _ModelItem('glm-4.7-flash', free: true),
      _ModelItem('glm-4-flash', free: true),
      _ModelItem('glm-4-plus'),
      _ModelItem('glm-4-air'),
    ],
  ),
  // ── 2026-10-25：补几家**真免费**的（都不用绑卡）────────────────
  // 用户问「有没有免费的 AI」，这三家是当下最省事的：
  //   · Groq：免费 30 次/分、1000 次/天，速度极快，但需外网；
  //   · Gemini：Google AI Studio 免费层，需外网（模型名可改成更新的 flash）；
  //   · 硅基流动：国内直连，站内标了「免费」的小模型可用。
  _Provider(
    'Groq（免费）',
    'https://api.groq.com/openai/v1',
    'openai/gpt-oss-120b',
    '免费 1000 次/天 · 需外网',
    [
      _ModelItem('openai/gpt-oss-120b', free: true),
      _ModelItem('llama-3.3-70b-versatile', free: true),
      _ModelItem('llama-3.1-8b-instant', free: true),
      _ModelItem('qwen/qwen3-32b', free: true),
    ],
  ),
  _Provider(
    'Gemini（免费）',
    'https://generativelanguage.googleapis.com/v1beta/openai',
    'gemini-2.5-flash',
    '有免费层 · 需外网',
    [
      _ModelItem('gemini-2.5-flash', free: true),
      _ModelItem('gemini-2.5-flash-lite', free: true),
      _ModelItem('gemini-2.0-flash', free: true),
      _ModelItem('gemini-2.5-pro'),
    ],
  ),
  _Provider(
    '硅基流动（免费）',
    'https://api.siliconflow.cn/v1',
    'Qwen/Qwen2-7B-Instruct',
    '国内直连 · 有免费模型',
    [
      _ModelItem('Qwen/Qwen2-7B-Instruct', free: true),
      _ModelItem('Qwen/Qwen2.5-7B-Instruct', free: true),
      _ModelItem('Qwen/Qwen3-8B', free: true),
      _ModelItem('deepseek-ai/DeepSeek-V3'),
    ],
  ),
];

/// 「AI 管理」——**全 App 唯一的 AI Key 配置入口**。
///
/// 设计要点（用户 2026-10-25）：
///   • 只做**配置与连通性测试**，不重复实现请求逻辑 —— 底层仍走
///     [AiService]（OpenAI 兼容）。宠物对话、各模块 AI 天然共用同一份配置；
///   • 阅读模块原有的 AI 功能与它的界面**不改**：它读的也是这份配置；
///   • Key 只存本机 prefs，不上传、不内置。
class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key});

  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  final AiService _ai = AiService();
  final TextEditingController _base = TextEditingController();
  final TextEditingController _key = TextEditingController();
  final TextEditingController _model = TextEditingController();

  // 阅读独立配置（宠物永远用上面那份）
  final TextEditingController _rBase = TextEditingController();
  final TextEditingController _rKey = TextEditingController();
  final TextEditingController _rModel = TextEditingController();
  bool _readerSeparate = false;

  String? _selected;
  bool _obscure = true;
  bool _testing = false;
  String? _msg;
  bool _ok = false;

  /// 「拉取在线模型」结果（`GET {base}/models`），按免费优先排序
  List<({String id, bool free})> _onlineModels = const [];
  bool _loadingModels = false;

  /// 每个服务商各自记一份 Key（用户 2026-10-25：
  /// 「所有的 AI 密码切换后不变吗？」—— 原来只有一个 Key 输入框，
  /// 切服务商后还留着上一家的 Key，很容易把 A 家的 Key 发给 B 家）。
  static const _kKeys = 'ai.provider_keys.v1';
  Map<String, String> _keys = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _base.dispose();
    _key.dispose();
    _model.dispose();
    _rBase.dispose();
    _rKey.dispose();
    _rModel.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await _ai.init();
    } catch (_) {}
    // 先把「每家各自的 Key」读出来
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kKeys);
      if (raw != null && raw.isNotEmpty) {
        final m = jsonDecode(raw);
        if (m is Map) {
          _keys = {
            for (final e in m.entries) e.key.toString(): e.value.toString(),
          };
        }
      }
    } catch (_) {}
    _base.text = _ai.baseUrl;
    _key.text = _ai.apiKey;
    _model.text = _ai.model;
    _rBase.text = _ai.readerBaseUrl;
    _rKey.text = _ai.readerApiKey;
    _rModel.text = _ai.readerModel;
    _readerSeparate = _ai.readerSeparate;
    for (final p in _providers) {
      if (_ai.baseUrl.startsWith(p.baseUrl)) {
        _selected = p.name;
        break;
      }
    }
    // 当前服务商存过 Key ⇒ 用存过的那份（比全局 Key 更准）
    final own = _keys[_selected ?? ''];
    if (own != null && own.isNotEmpty) _key.text = own;
    if (mounted) setState(() {});
  }

  /// 把当前输入框里的 Key 记到当前服务商名下
  void _rememberKey() {
    final name = _selected;
    final k = _key.text.trim();
    if (name == null || k.isEmpty) return;
    _keys[name] = k;
  }

  Future<void> _persistKeys() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_kKeys, jsonEncode(_keys));
    } catch (_) {}
  }

  Future<void> _pick(_Provider p) async {
    _rememberKey();
    final next = _keys[p.name] ?? '';
    setState(() {
      _selected = p.name;
      _base.text = p.baseUrl;
      _model.text = p.model;
      // 切服务商：有存过 Key 就自动带出来，没有就清空（不再沿用上一家的）
      _key.text = next;
      _msg = null;
      // 在线模型列表属于上一家，清掉免得串到新服务商
      _onlineModels = const [];
    });
    await _persistKeys();
  }

  Future<bool> _save() async {
    if (_key.text.trim().isEmpty) {
      setState(() {
        _ok = false;
        _msg = '请先填写 API Key';
      });
      return false;
    }
    await _ai.saveConfig(
      baseUrl: _base.text,
      apiKey: _key.text,
      model: _model.text,
      readerSeparate: _readerSeparate,
      readerBaseUrl: _rBase.text,
      readerApiKey: _rKey.text,
      readerModel: _rModel.text,
    );
    if (!mounted) return true;
    // 保存成功 ⇒ 把这家的 Key 也记进「按服务商」的表里
    _rememberKey();
    await _persistKeys();
    if (!mounted) return true;
    setState(() {
      _ok = true;
      _msg = _readerSeparate && _rKey.text.trim().isNotEmpty
          ? '已保存：宠物用上面的配置，阅读用下面的独立配置'
          : '已保存，宠物与各模块都用这份配置';
    });
    return true;
  }

  Future<void> _test() async {
    if (_testing) return;
    final saved = await _save();
    if (!saved) return;
    setState(() {
      _testing = true;
      _msg = '正在连接…';
      _ok = false;
    });
    try {
      final r = await _ai.chat(
        system: '这是一次连通性测试，只回复 OK。',
        user: 'ping',
        timeout: const Duration(seconds: 30),
      );
      if (!mounted) return;
      setState(() {
        _ok = true;
        _msg = '连接成功：${r.length > 40 ? '${r.substring(0, 40)}…' : r}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _msg = '连接失败：$e';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  // ── 模型选择（用户 2026-10-27）─────────────────────────────
  // 诉求：「每不同的 AI 可以选哪些模型，和手动输入共存，特别是哪些是免费的」。
  // 做法：
  //   · 内置候选清单（每家一份，带「免费」标记）——离线也能选；
  //   · 「拉取在线模型」用用户自己的 Key 调 `GET {base}/models`，
  //     OpenRouter 这类会给单价，prompt/completion 都是 0 即免费；
  //   · 选中的模型只是**回填输入框**，手动输入随时可改（两者共存）。

  /// 当前服务商的内置候选模型
  List<_ModelItem> _builtinModelsFor(String name) {
    for (final p in _providers) {
      if (p.name == name) return p.models;
    }
    return const [];
  }

  /// 按 baseUrl 反查是哪家（阅读独立配置用）
  String _providerNameOf(String baseUrl) {
    final b = baseUrl.trim();
    for (final p in _providers) {
      if (b.startsWith(p.baseUrl)) return p.name;
    }
    return '';
  }

  Future<void> _fetchOnlineModels({String? baseUrl, String? apiKey}) async {
    if (_loadingModels) return;
    setState(() {
      _loadingModels = true;
      _msg = null;
    });
    try {
      final list = await _ai.fetchModels(
        baseUrlOverride: baseUrl ?? _base.text,
        apiKeyOverride: apiKey ?? _key.text,
      );
      if (!mounted) return;
      setState(() {
        _onlineModels = list;
        _ok = true;
        final freeCount = list.where((m) => m.free).length;
        _msg = '已拉取 ${list.length} 个模型（其中 $freeCount 个免费）';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _msg = '拉取模型失败：$e';
      });
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  /// 合并「在线列表（最新）+ 内置清单（兜底）」，按 id 去重、免费优先
  List<MapEntry<String, bool>> _mergedModels(String providerName) {
    final merged = <String, bool>{};
    for (final m in _builtinModelsFor(providerName)) {
      merged[m.id] = m.free;
    }
    for (final m in _onlineModels) {
      merged[m.id] = (merged[m.id] ?? false) || m.free;
    }
    return merged.entries.toList()
      ..sort((a, b) {
        if (a.value != b.value) return a.value ? -1 : 1;
        return a.key.compareTo(b.key);
      });
  }

  /// 打开「选择模型」面板；选中后只回填 [target] 输入框（不覆盖手动输入）
  void _openModelPicker({
    required TextEditingController target,
    required String baseUrl,
    required String apiKey,
    required String providerName,
  }) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.backgroundSecondary,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        var keyword = '';
        var freeOnly = false;
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            final list = _mergedModels(providerName).where((e) {
              if (freeOnly && !e.value) return false;
              if (keyword.isEmpty) return true;
              return e.key.toLowerCase().contains(keyword.toLowerCase());
            }).toList();
            return SizedBox(
              height: MediaQuery.of(ctx).size.height * 0.72,
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppTheme.borderMedium,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '选择模型${providerName.isEmpty ? '' : ' · $providerName'}',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                        ),
                        // 只看免费
                        FilterChip(
                          label: const Text('只看免费'),
                          selected: freeOnly,
                          onSelected: (v) => setSheet(() => freeOnly = v),
                          labelStyle: TextStyle(
                            fontSize: 11.5,
                            color: freeOnly
                                ? Colors.white
                                : AppTheme.textSecondary,
                          ),
                          selectedColor: AppTheme.accentOnSurface,
                          backgroundColor: AppTheme.backgroundTertiary,
                          checkmarkColor: Colors.white,
                          side: BorderSide.none,
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppTheme.backgroundTertiary,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: TextField(
                        onChanged: (v) => setSheet(() => keyword = v.trim()),
                        style: TextStyle(
                            fontSize: 13, color: AppTheme.textPrimary),
                        decoration: InputDecoration(
                          hintText: '搜索模型名',
                          hintStyle: TextStyle(
                              fontSize: 13, color: AppTheme.textTertiary),
                          border: InputBorder.none,
                          isDense: true,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ),
                  ),
                  if (_loadingModels)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text('正在拉取在线模型…',
                          style: TextStyle(
                              fontSize: 11.5,
                              color: AppTheme.textTertiary)),
                    ),
                  Expanded(
                    child: list.isEmpty
                        ? Center(
                            child: Text(
                              '没有可选模型，可直接在输入框手动填写',
                              style: TextStyle(
                                  fontSize: 12.5,
                                  color: AppTheme.textTertiary),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 20),
                            itemCount: list.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 2),
                            itemBuilder: (_, i) {
                              final e = list[i];
                              final current = target.text.trim() == e.key;
                              return InkWell(
                                borderRadius: BorderRadius.circular(10),
                                onTap: () {
                                  setState(() => target.text = e.key);
                                  Navigator.of(ctx).pop();
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12, vertical: 11),
                                  decoration: BoxDecoration(
                                    color: current
                                        ? AppTheme.backgroundTertiary
                                        : Colors.transparent,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          e.key,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: current
                                                ? FontWeight.w600
                                                : FontWeight.w400,
                                            color: AppTheme.textPrimary,
                                          ),
                                        ),
                                      ),
                                      if (e.value) _freeBadge(),
                                      if (current) ...[
                                        const SizedBox(width: 6),
                                        Icon(Icons.check,
                                            size: 15,
                                            color: AppTheme.accentOnSurface),
                                      ],
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                  SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: _button(
                              _loadingModels ? '拉取中…' : '拉取在线模型',
                              tonal: true,
                              busy: _loadingModels,
                              onTap: _loadingModels
                                  ? null
                                  : () async {
                                      await _fetchOnlineModels(
                                        baseUrl: baseUrl,
                                        apiKey: apiKey,
                                      );
                                      // 面板是独立路由，拉完要主动让它用最新列表重算
                                      setSheet(() {});
                                    },
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: _button('手动输入', onTap: () {
                              Navigator.of(ctx).pop();
                            }),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 「免费」小标签
  Widget _freeBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0x1F2E9E5B),
        borderRadius: BorderRadius.circular(6),
      ),
      child: const Text(
        '免费',
        style: TextStyle(
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
          color: Color(0xFF2E9E5B),
        ),
      ),
    );
  }

  /// 模型输入框下面那排按钮
  Widget _modelActions({
    required TextEditingController target,
    required String baseUrl,
    required String apiKey,
    required String providerName,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 2),
      child: Row(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _openModelPicker(
              target: target,
              baseUrl: baseUrl,
              apiKey: apiKey,
              providerName: providerName,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.list_alt_rounded,
                      size: 14, color: AppTheme.accentOnSurface),
                  const SizedBox(width: 4),
                  Text('选择模型',
                      style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: AppTheme.accentOnSurface)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text('可手动输入',
              style:
                  TextStyle(fontSize: 10.5, color: AppTheme.textTertiary)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundPrimary,
      appBar: AppBar(
        backgroundColor: AppTheme.backgroundPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        iconTheme: IconThemeData(color: AppTheme.textPrimary),
        title: Text(
          'AI 管理',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        children: [
          _statusCard(),
          const SizedBox(height: 18),
          _label('服务商'),
          _providerChips(),
          const SizedBox(height: 14),
          _surface(
            Column(
              children: [
                _field(
                  _base,
                  '接口地址',
                  hint: 'https://api.deepseek.com',
                  keyboard: TextInputType.url,
                ),
                const SizedBox(height: 10),
                _field(
                  _key,
                  'API Key',
                  hint: 'sk-...',
                  obscure: _obscure,
                  suffix: IconButton(
                    icon: Icon(
                      _obscure ? Icons.visibility_off : Icons.visibility,
                      size: 18,
                      color: AppTheme.textTertiary,
                    ),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                const SizedBox(height: 10),
                _field(_model, '模型', hint: 'deepseek-chat'),
                _modelActions(
                  target: _model,
                  baseUrl: _base.text,
                  apiKey: _key.text,
                  providerName: _selected ?? '',
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _button(
                  _testing ? '连接中…' : '测试连接',
                  tonal: true,
                  busy: _testing,
                  onTap: _testing ? null : _test,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(child: _button('保存', onTap: _save)),
            ],
          ),
          if (_msg != null) _msgRow(),
          const SizedBox(height: 16),
          _readerCard(),
          const SizedBox(height: 14),
          _surface(
            InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const LogDiagnosisPage()),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: AppTheme.backgroundTertiary,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(Icons.troubleshoot_rounded,
                          size: 18, color: AppTheme.accentOnSurface),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('日志诊断',
                              style: TextStyle(
                                  fontSize: 13.5,
                                  fontWeight: FontWeight.w600,
                                  color: AppTheme.textPrimary)),
                          const SizedBox(height: 2),
                          Text('读运行日志，让 AI 给出优化建议',
                              style: TextStyle(
                                  fontSize: 11.5, color: AppTheme.textTertiary)),
                        ],
                      ),
                    ),
                    Icon(Icons.chevron_right,
                        size: 18, color: AppTheme.textTertiary),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '所有服务商都按 OpenAI 兼容协议调用。地址以 /v1、/v4 结尾会自动补全，'
            '也可以直接填完整的 .../chat/completions。',
            style: TextStyle(
              fontSize: 11.5,
              height: 1.6,
              color: AppTheme.textTertiary,
            ),
          ),
        ],
      ),
    );
  }

  // ── 组件 ───────────────────────────────────────────────
  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 8),
        child: Text(t,
            style: TextStyle(fontSize: 11.5, color: AppTheme.textTertiary)),
      );

  Widget _surface(Widget child) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.backgroundCard,
          borderRadius: BorderRadius.circular(16),
        ),
        child: child,
      );

  Widget _statusCard() {
    final name = _selected ?? (_key.text.trim().isEmpty ? '未配置' : '自定义');
    final ok = _key.text.trim().isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: ok
                      ? AppTheme.accentOnSurface.withValues(alpha: 0.14)
                      : AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.auto_awesome_rounded,
                  size: 19,
                  color: ok ? AppTheme.accentOnSurface : AppTheme.textTertiary,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('当前使用',
                        style: TextStyle(
                            fontSize: 11, color: AppTheme.textTertiary)),
                    const SizedBox(height: 2),
                    Text(
                      '$name · ${_model.text.trim().isEmpty ? '未填模型' : _model.text.trim()}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: ok
                      ? const Color(0x1F2E9E5B)
                      : AppTheme.backgroundTertiary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  ok ? '已配置' : '未配置',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    color: ok ? const Color(0xFF2E9E5B) : AppTheme.textTertiary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '宠物对话固定用这份配置；阅读可以单独配一套。Key 只存本机。\n'
            '听书朗读里的「小米 MiMo / OpenAI 兼容」源可以打开「复用 AI 管理」，'
            '直接借这份地址与 Key，不用再填一遍。',
            style: TextStyle(
                fontSize: 11.5, height: 1.55, color: AppTheme.textTertiary),
          ),
        ],
      ),
    );
  }

  Widget _providerChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final p in _providers)
          GestureDetector(
            onTap: () => _pick(p),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
              decoration: BoxDecoration(
                color: _selected == p.name
                    ? AppTheme.accentOnSurface
                    : AppTheme.backgroundTertiary,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                p.name,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: _selected == p.name
                      ? FontWeight.w600
                      : FontWeight.w400,
                  color: _selected == p.name
                      ? Colors.white
                      : AppTheme.textSecondary,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _button(
    String text, {
    bool tonal = false,
    bool busy = false,
    VoidCallback? onTap,
  }) {
    return Material(
      color: tonal ? AppTheme.backgroundTertiary : AppTheme.accentOnSurface,
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: onTap,
        child: SizedBox(
          height: 44,
          child: Center(
            child: busy
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.textSecondary,
                    ),
                  )
                : Text(
                    text,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: tonal ? AppTheme.textPrimary : Colors.white,
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  Widget _msgRow() {
    final ok = _ok;
    return Padding(
      padding: const EdgeInsets.only(top: 12, left: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            size: 15,
            color: ok ? const Color(0xFF2E9E5B) : const Color(0xFFD25757),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _msg!,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: ok ? AppTheme.textSecondary : const Color(0xFFD25757),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _readerCard() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.backgroundCard,
        borderRadius: BorderRadius.circular(16),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('阅读使用独立 AI',
                        style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary)),
                    const SizedBox(height: 2),
                    Text('只影响阅读的总结 / 问答，宠物不受影响',
                        style: TextStyle(
                            fontSize: 11.5, color: AppTheme.textTertiary)),
                  ],
                ),
              ),
              AppSwitch(
                value: _readerSeparate,
                onChanged: (v) => setState(() => _readerSeparate = v),
              ),
            ],
          ),
          if (_readerSeparate) ...[
            const SizedBox(height: 10),
            _field(_rBase, '阅读接口地址',
                hint: 'https://api.deepseek.com',
                keyboard: TextInputType.url),
            const SizedBox(height: 10),
            _field(_rKey, '阅读 API Key', hint: 'sk-...', obscure: true),
            const SizedBox(height: 10),
            _field(_rModel, '阅读模型', hint: 'deepseek-chat'),
            _modelActions(
              target: _rModel,
              baseUrl: _rBase.text,
              apiKey: _rKey.text,
              providerName: _providerNameOf(_rBase.text),
            ),
          ],
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController c,
    String label, {
    String? hint,
    TextInputType? keyboard,
    bool obscure = false,
    Widget? suffix,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 5),
          child: Text(label,
              style: TextStyle(fontSize: 10.5, color: AppTheme.textTertiary)),
        ),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.backgroundTertiary,
            borderRadius: BorderRadius.circular(13),
          ),
          padding: const EdgeInsets.only(left: 12, right: 4),
          child: TextField(
            controller: c,
            obscureText: obscure,
            keyboardType: keyboard,
            onChanged: (_) => setState(() {}),
            style: TextStyle(fontSize: 13.5, color: AppTheme.textPrimary),
            decoration: InputDecoration(
              hintText: hint,
              hintStyle:
                  TextStyle(fontSize: 13, color: AppTheme.textTertiary),
              suffixIcon: suffix,
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 13),
            ),
          ),
        ),
      ],
    );
  }
}
