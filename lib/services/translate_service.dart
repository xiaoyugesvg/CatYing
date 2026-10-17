import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../reading/source/global_proxy.dart';
import 'app_log.dart';

/// 翻译设置（独立存 SharedPreferences，避免动 SettingsService 那一大坨）。
///
/// 两种引擎同时保留、可切换：
///   · `openai` —— OpenAI 兼容接口（DeepSeek / 智谱 / 自建…），质量最好
///   · `baidu`  —— 百度翻译开放平台，便宜稳定
class TranslateSettings {
  TranslateSettings._();

  static const _kEngine = 'translate_engine';
  static const _kOpenAiBase = 'translate_openai_base';
  static const _kOpenAiKey = 'translate_openai_key';
  static const _kOpenAiModel = 'translate_openai_model';
  static const _kBaiduAppId = 'translate_baidu_appid';
  static const _kBaiduSecret = 'translate_baidu_secret';
  static const _kFrom = 'translate_from';
  static const _kTo = 'translate_to';

  static Future<SharedPreferences> get _p => SharedPreferences.getInstance();

  static Future<String> engine() async =>
      (await _p).getString(_kEngine) ?? 'openai';
  static Future<String> openAiBase() async =>
      (await _p).getString(_kOpenAiBase) ?? 'https://api.openai.com/v1';
  static Future<String> openAiKey() async =>
      (await _p).getString(_kOpenAiKey) ?? '';
  static Future<String> openAiModel() async =>
      (await _p).getString(_kOpenAiModel) ?? 'gpt-4o-mini';
  static Future<String> baiduAppId() async =>
      (await _p).getString(_kBaiduAppId) ?? '';
  static Future<String> baiduSecret() async =>
      (await _p).getString(_kBaiduSecret) ?? '';
  static Future<String> from() async =>
      (await _p).getString(_kFrom) ?? 'auto';
  static Future<String> to() async => (await _p).getString(_kTo) ?? 'zh';

  static Future<void> save({
    String? engine,
    String? openAiBase,
    String? openAiKey,
    String? openAiModel,
    String? baiduAppId,
    String? baiduSecret,
    String? from,
    String? to,
  }) async {
    final p = await _p;
    if (engine != null) await p.setString(_kEngine, engine);
    if (openAiBase != null) await p.setString(_kOpenAiBase, openAiBase.trim());
    if (openAiKey != null) await p.setString(_kOpenAiKey, openAiKey.trim());
    if (openAiModel != null) {
      await p.setString(_kOpenAiModel, openAiModel.trim());
    }
    if (baiduAppId != null) {
      await p.setString(_kBaiduAppId, baiduAppId.trim());
    }
    if (baiduSecret != null) {
      await p.setString(_kBaiduSecret, baiduSecret.trim());
    }
    if (from != null) await p.setString(_kFrom, from);
    if (to != null) await p.setString(_kTo, to);
    TranslateService.instance.clearCache();
  }

  /// 配置是否完整（用于 UI 提示 / 提前拦截）
  static Future<String> missingReason() async {
    final e = await engine();
    if (e == 'baidu') {
      if ((await baiduAppId()).isEmpty || (await baiduSecret()).isEmpty) {
        return '百度翻译的 APPID / 密钥没填（设置 → 翻译设置）';
      }
      return '';
    }
    if ((await openAiKey()).isEmpty) {
      return 'AI 翻译的 API Key 没填（设置 → 翻译设置）';
    }
    return '';
  }
}

/// 把 OCR 出来的若干行文本批量翻译。保持**行数与顺序**不变。
class TranslateService {
  TranslateService._();
  static final TranslateService instance = TranslateService._();

  /// 百度翻译接口地址（单元测试可替换成本地 mock 服务）
  static String baiduEndpoint =
      'https://fanyi-api.baidu.com/api/trans/vip/translate';

  /// LRU 缓存：同一页重开不用重新翻（key = 引擎|源|目标|原文）
  final Map<String, List<String>> _cache = {};

  void clearCache() => _cache.clear();

  /// 翻译 [lines]，返回等长结果（失败抛异常，由调用方提示）。
  Future<List<String>> translateLines(
    List<String> lines, {
    String? from,
    String? to,
  }) async {
    final clean = lines.map((e) => e.trim()).toList();
    if (clean.isEmpty) return const [];
    final src = from ?? await TranslateSettings.from();
    final dst = to ?? await TranslateSettings.to();
    final engine = await TranslateSettings.engine();
    final key = '$engine|$src|$dst|${clean.join('\u0001')}';
    final hit = _cache[key];
    if (hit != null) return hit;

    final result = engine == 'baidu'
        ? await _baidu(clean, src, dst)
        : await _openAi(clean, src, dst);

    if (_cache.length > 64) _cache.remove(_cache.keys.first);
    _cache[key] = result;
    return result;
  }

  // ── OpenAI 兼容 ────────────────────────────────────────────────

  Future<List<String>> _openAi(
      List<String> lines, String from, String to) async {
    final base = await TranslateSettings.openAiBase();
    final apiKey = await TranslateSettings.openAiKey();
    final model = await TranslateSettings.openAiModel();
    if (apiKey.isEmpty) throw Exception('AI 翻译的 API Key 没填');

    final url = base.endsWith('/')
        ? '${base}chat/completions'
        : '$base/chat/completions';
    final system = '你是漫画/字幕翻译器。输入是 JSON 字符串数组，每项是一条独立的台词。'
        '请逐条翻译成${_langName(to)}，保持数量、顺序和数组结构；'
        '不要合并、不要拆分、不要加解释，只输出 JSON 数组。'
        '原文语言：${from == 'auto' ? '自动判断' : _langName(from)}。';
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
    ));
    applyGlobalProxy(dio);
    try {
      final resp = await dio.post<dynamic>(
        url,
        data: {
          'model': model,
          'temperature': 0.2,
          'messages': [
            {'role': 'system', 'content': system},
            {'role': 'user', 'content': jsonEncode(lines)},
          ],
        },
        options: Options(headers: {
          'Authorization': 'Bearer $apiKey',
          'Content-Type': 'application/json',
        }),
      );
      String content = '';
      final data = resp.data;
      if (data is Map) {
        final choices = data['choices'];
        if (choices is List && choices.isNotEmpty) {
          final first = choices.first;
          if (first is Map) {
            final msg = first['message'];
            if (msg is Map) content = (msg['content'] ?? '').toString();
          }
        }
      }
      final parsed = _parseJsonArray(content);
      if (parsed.length == lines.length) return parsed;
      // 模型偶尔多/少一条：能对上就按行拆，对不上就原样返回（不阻断阅读）
      if (parsed.isNotEmpty) {
        return List<String>.generate(
          lines.length,
          (i) => i < parsed.length ? parsed[i] : lines[i],
        );
      }
    } catch (e) {
      AppLog.instance.log('[Translate] AI 翻译失败: $e');
      rethrow;
    } finally {
      dio.close(force: true);
    }
    return lines;
  }

  static List<String> _parseJsonArray(String raw) {
    var s = raw.trim();
    // 去掉 ```json … ``` 围栏
    if (s.startsWith('```')) {
      final i = s.indexOf('\n');
      if (i > 0) s = s.substring(i + 1);
      if (s.endsWith('```')) s = s.substring(0, s.length - 3);
      s = s.trim();
    }
    try {
      final d = jsonDecode(s);
      if (d is List) {
        return d.map((e) => e.toString()).toList();
      }
    } catch (_) {
      // 再试一次：截取第一个 [ 到最后一个 ]
      final a = s.indexOf('[');
      final b = s.lastIndexOf(']');
      if (a >= 0 && b > a) {
        try {
          final d = jsonDecode(s.substring(a, b + 1));
          if (d is List) return d.map((e) => e.toString()).toList();
        } catch (_) {}
      }
    }
    return const [];
  }

  // ── 百度翻译 ──────────────────────────────────────────────────

  Future<List<String>> _baidu(
      List<String> lines, String from, String to) async {
    final appId = await TranslateSettings.baiduAppId();
    final secret = await TranslateSettings.baiduSecret();
    if (appId.isEmpty || secret.isEmpty) {
      throw Exception('百度翻译的 APPID / 密钥没填');
    }
    final q = lines.join('\n');
    final salt = DateTime.now().millisecondsSinceEpoch.toString();
    final sign = md5.convert(utf8.encode('$appId$q$salt$secret')).toString();

    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
    ));
    applyGlobalProxy(dio);
    try {
      final resp = await dio.post<dynamic>(
        baiduEndpoint,
        data: {
          'q': q,
          'from': from == 'auto' ? 'auto' : from,
          'to': to,
          'appid': appId,
          'salt': salt,
          'sign': sign,
        },
        options: Options(contentType: Headers.formUrlEncodedContentType),
      );
      final m = resp.data is Map ? resp.data as Map : const {};
      final err = (m['error_code'] ?? '').toString();
      if (err.isNotEmpty && err != '52000') {
        throw Exception('百度翻译错误 $err: ${m['error_msg'] ?? ''}');
      }
      final list = (m['trans_result'] as List?) ?? const [];
      final dsts = <String>[];
      for (final e in list) {
        if (e is Map) dsts.add((e['dst'] ?? '').toString());
      }
      if (dsts.length == lines.length) return dsts;
      // 百度常把多行合并成一条：按换行还原
      final joined = dsts.join('\n').split('\n');
      if (joined.length == lines.length) return joined;
      return List<String>.generate(
        lines.length,
        (i) => i < dsts.length ? dsts[i] : lines[i],
      );
    } catch (e) {
      AppLog.instance.log('[Translate] 百度翻译失败: $e');
      rethrow;
    } finally {
      dio.close(force: true);
    }
  }

  static String _langName(String code) {
    switch (code) {
      case 'zh':
      case 'zh-CN':
        return '简体中文';
      case 'zh-TW':
        return '繁体中文';
      case 'ja':
        return '日语';
      case 'ko':
        return '韩语';
      case 'en':
        return '英语';
      default:
        return code;
    }
  }
}
