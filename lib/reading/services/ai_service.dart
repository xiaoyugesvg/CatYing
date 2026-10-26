import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tvbox/reading/source/global_proxy.dart';

/// AI 对话服务（OpenAI 兼容 chat/completions）。
///
/// 让阅读器「AI 总结/问答」真实可用：用户在阅读器里第一次点 AI 动作时
/// 弹出配置（接口地址 / API Key / 模型名），之后按需调用。默认指向
/// DeepSeek 的公开兼容端点，也可改成任何 OpenAI 兼容服务
/// （通义/智谱/Moonshot/本地 vLLM 等，只要 `POST {base}/chat/completions`）。
///
/// 不内置任何第三方 Key —— Key 是用户自己的，存在本机 prefs。
class AiService extends ChangeNotifier {
  AiService._();
  static final AiService _instance = AiService._();
  factory AiService() => _instance;

  static const _cfgKey = 'ai_service_config_v1';

  String baseUrl = 'https://api.deepseek.com';
  String apiKey = '';
  String model = 'deepseek-chat';

  // ── 阅读模块的**独立**配置（2026-10-25）─────────────────────
  // 用户要求：全 App 只有「AI 管理」一处配置，宠物**固定**用它；
  // 但阅读可以单独选另一家（比如把便宜的模型留给阅读，宠物用好一点的）。
  bool readerSeparate = false;
  String readerBaseUrl = '';
  String readerApiKey = '';
  String readerModel = '';

  bool get isConfigured => apiKey.trim().isNotEmpty;

  /// 阅读 AI 是否真的在用独立配置（开关开着且填了 Key）
  bool get readerActive => readerSeparate && readerApiKey.trim().isNotEmpty;


  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cfgKey);
      if (raw != null) {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        baseUrl = (m['baseUrl'] as String?)?.trim().isNotEmpty == true
            ? m['baseUrl'] as String
            : baseUrl;
        apiKey = (m['apiKey'] as String?) ?? '';
        model = (m['model'] as String?)?.trim().isNotEmpty == true
            ? m['model'] as String
            : model;
        readerSeparate = m['readerSeparate'] == true;
        readerBaseUrl = (m['readerBaseUrl'] as String?) ?? '';
        readerApiKey = (m['readerApiKey'] as String?) ?? '';
        readerModel = (m['readerModel'] as String?) ?? '';
      }
    } catch (e) {
      debugPrint('[AiService] 加载配置失败: $e');
    }
    notifyListeners();
  }

  Future<void> saveConfig({
    required String baseUrl,
    required String apiKey,
    required String model,
    bool? readerSeparate,
    String? readerBaseUrl,
    String? readerApiKey,
    String? readerModel,
  }) async {
    this.baseUrl = baseUrl.trim().isEmpty ? 'https://api.deepseek.com' : baseUrl.trim();
    this.apiKey = apiKey.trim();
    this.model = model.trim().isEmpty ? 'deepseek-chat' : model.trim();
    if (readerSeparate != null) this.readerSeparate = readerSeparate;
    if (readerBaseUrl != null) this.readerBaseUrl = readerBaseUrl.trim();
    if (readerApiKey != null) this.readerApiKey = readerApiKey.trim();
    if (readerModel != null) this.readerModel = readerModel.trim();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cfgKey, jsonEncode({
        'baseUrl': this.baseUrl,
        'apiKey': this.apiKey,
        'model': this.model,
        'readerSeparate': this.readerSeparate,
        'readerBaseUrl': this.readerBaseUrl,
        'readerApiKey': this.readerApiKey,
        'readerModel': this.readerModel,
      }));
    } catch (e) {
      debugPrint('[AiService] 保存配置失败: $e');
    }
    notifyListeners();
  }

  /// 兼容拼接：base 不带 `/v1` 时补上（DeepSeek 等要求 /v1/chat/completions）。
  ///
  /// 另外兼容两种常见写法（各家 baseUrl 差异很大）：
  ///   · 用户直接填了完整地址（以 `/chat/completions` 结尾）⇒ 原样用；
  ///   · 智谱等以 `/v4` 结尾 ⇒ `$b/chat/completions`（不能再塞 `/v1`）。
  String _endpointOf(String b0) {
    final b = b0.replaceAll(RegExp(r'/+$'), '');
    if (b.endsWith('/chat/completions')) return b;
    if (b.endsWith('/v1') || b.endsWith('/v4')) return '$b/chat/completions';
    return '$b/v1/chat/completions';
  }

  /// 取地址里的 `user:pass@`（没有就返回空串）
  String _userInfoOf(String raw) {
    final u = Uri.tryParse(raw.trim());
    return u?.userInfo ?? '';
  }

  /// 去掉地址里的 `user:pass@`（Dio/URL 里带着它反而不干净）
  String _stripUserInfo(String raw) {
    final t = raw.trim();
    final u = Uri.tryParse(t);
    if (u == null || u.userInfo.isEmpty) return t;
    return u.replace(userInfo: '').toString();
  }

  /// 发起一次对话，返回助手回复文本。失败抛中文可读错误。
  ///
  /// [scoped] 只给**阅读模块**用：为 true 且开了「阅读使用独立 AI」时，
  /// 用阅读那套 base/key/model；其余调用方（宠物、日志诊断、AI 管理测试）
  /// 一律走全局配置。
  Future<String> chat({
    required String system,
    required String user,
    Duration timeout = const Duration(seconds: 90),
    bool scoped = false,
  }) async {
    final useReader = scoped && readerActive;
    final key = useReader ? readerApiKey.trim() : apiKey.trim();
    final mdl = useReader && readerModel.trim().isNotEmpty
        ? readerModel.trim()
        : model;
    final rawBase = useReader ? readerBaseUrl : baseUrl;
    // 自建网关常见的两种鉴权：
    //   · nginx Basic 认证 → 把账号密码写进地址 https://u:p@host/v1，
    //     或 Key 填 `basic:u:p`
    //   · 普通 OpenAI 网关 → Key 直接是 Bearer
    final baseUserInfo = _userInfoOf(rawBase);
    final endpoint = _endpointOf(_stripUserInfo(rawBase));
    final auth = baseUserInfo.isNotEmpty
        ? 'Basic ${base64Encode(utf8.encode(baseUserInfo))}'
        : key.toLowerCase().startsWith('basic:')
            ? 'Basic ${base64Encode(utf8.encode(key.substring(6).trim()))}'
            : 'Bearer ${key.toLowerCase().startsWith('bearer:') ? key.substring(7).trim() : key}';
    if (key.isEmpty && baseUserInfo.isEmpty) {
      throw useReader
          ? '阅读的独立 AI 还没填 Key（设置 → AI 管理 → 阅读使用独立 AI）'
          : '尚未配置 AI 接口（需要 API Key）';
    }
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: timeout,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': auth,
      },
    ));
    // ✅ **AI 总结 / 问答也走「网络代理」**（本轮接上 ✓）—— 本服务是**每次调用临时建 Dio** ✓
    //   （见上面 `final dio = Dio(...)` ✓），所以就在**建好之后**挂 ✓（与 `comic_api` 的 webDio 同款 ✓）。
    //   ℹ️ 安全依据 ✓：本处**没有自定义适配器** ✗✓（只有超时 + headers ✓，都在 Dio 选项层 ✓）
    //     → 不存在"挂代理把 UA/鉴权头丢掉"的风险 ✓✓
    //   ⚠️ 鉴权头 `Authorization` 属于 **Dio 选项层** ✓，与 socket 层适配器互不干扰 ✓（不会丢 ✓）。
    //   · 代理**关闭** ✓ → 返回 false ✓ **一字不改** ✓（与从前完全一致 ✓✓）
    applyGlobalProxy(dio);
    try {
      final resp = await dio.post<Map<String, dynamic>>(
        endpoint,
        data: {
          'model': mdl,
          'messages': [
            {'role': 'system', 'content': system},
            {'role': 'user', 'content': user},
          ],
          'temperature': 0.6,
          'stream': false,
        },
      );
      final data = resp.data;
      if (data == null) throw '接口无响应';
      final choices = data['choices'];
      if (choices is List && choices.isNotEmpty) {
        final msg = choices.first is Map
            ? (choices.first as Map)['message']
            : null;
        if (msg is Map) {
          final content = msg['content'];
          if (content is String && content.trim().isNotEmpty) {
            return content.trim();
          }
        }
      }
      // 兼容 /v1/responses 风格
      final output = data['output_text'];
      if (output is String && output.trim().isNotEmpty) return output.trim();
      throw '接口返回中没有可用内容';
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final body = e.response?.data;
      String detail = '';
      if (body is Map) {
        final err = body['error'];
        if (err is Map) {
          detail = '：${err['message'] ?? err['type'] ?? ''}';
        } else if (err is String) {
          detail = '：$err';
        }
      } else if (body is String) {
        detail = '：${body.length > 200 ? body.substring(0, 200) : body}';
      }
      if (status == 401) throw 'API Key 无效（401）$detail';
      if (status == 402) throw '额度不足（402）$detail';
      if (status == 429) throw '请求太频繁（429）$detail';
      if (status != null && status >= 500) throw 'AI 服务端错误（$status）$detail';
      throw '请求失败：${e.message ?? e}$detail';
    } catch (e) {
      throw '请求异常：$e';
    } finally {
      // 局部新建的 Dio 内部持有 HttpClient，不显式关闭会泄漏连接池
      dio.close(force: true);
    }
  }
}
