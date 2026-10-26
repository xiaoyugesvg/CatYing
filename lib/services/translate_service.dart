import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tvbox/reading/source/global_proxy.dart';
import 'package:tvbox/services/app_log.dart';

/// 翻译设置（独立存 SharedPreferences，避免动 SettingsService 那一大坨）。
///
/// 三种引擎，可切换：
///   · `google` —— **免 Key**，走 Google 的公开翻译端点（默认）
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
      (await _p).getString(_kEngine) ?? 'google';
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

  /// 配置是否完整（用于 UI 提示 / 提前拦截）。免 Key 引擎恒为空。
  static Future<String> missingReason() async {
    final e = await engine();
    if (e == 'google') return '';
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

/// 翻译服务：既支持**整批**翻译（漫画 OCR 一页多行），
/// 也支持**单条**翻译（TG 标题、阅读段落、外挂字幕）。
///
/// 批量保持**行数与顺序**不变；单条缓存最近 300 条。
class TranslateService {
  TranslateService._();
  static final TranslateService instance = TranslateService._();

  /// 百度翻译接口地址（单元测试可替换成本地 mock 服务）
  static String baiduEndpoint =
      'https://fanyi-api.baidu.com/api/trans/vip/translate';

  /// Google 免 Key 端点（单元测试可替换成本地 mock 服务）
  ///
  /// 两条都在 iOS「Scripting」那个翻译脚本里用过，实测无需鉴权：
  ///   1. `clients5.google.com/translate_a/t?client=dict-chrome-ex`  ← 主路，最稳
  ///   2. `translate.googleapis.com/translate_a/single?client=gtx`   ← 兜底（常 429）
  static String googleDictEndpoint =
      'https://clients5.google.com/translate_a/t';
  static String googleGtxEndpoint =
      'https://translate.googleapis.com/translate_a/single';

  /// LRU 缓存：同一页重开不用重新翻（key = 引擎|源|目标|原文）
  final Map<String, List<String>> _cache = {};

  /// 单条译文缓存（TG 标题 / 字幕行反复出现）
  final Map<String, String> _oneCache = {};
  static const int _maxOneCache = 300;

  void clearCache() {
    _cache.clear();
    _oneCache.clear();
  }

  // ── 语言判定 ────────────────────────────────────────────────

  /// 汉字（基本区 + 扩展 A + 兼容区）
  static bool _isHan(int r) =>
      (r >= 0x4E00 && r <= 0x9FFF) ||
      (r >= 0x3400 && r <= 0x4DBF) ||
      (r >= 0xF900 && r <= 0xFAFF);

  /// 中日韩以外的"字母"（用来判断是不是外语）
  static bool _isOtherLetter(int r) =>
      // 西里尔 / 希腊 / 泰 / 阿拉伯 / 希伯来 / 天城文
      (r >= 0x0400 && r <= 0x04FF) ||
      (r >= 0x0370 && r <= 0x03FF) ||
      (r >= 0x0E00 && r <= 0x0E7F) ||
      (r >= 0x0600 && r <= 0x06FF) ||
      (r >= 0x0590 && r <= 0x05FF) ||
      (r >= 0x0900 && r <= 0x097F);

  /// 中文占比够高就认为不用翻（只判 CJK 字符比例）
  static bool looksChinese(String s) {
    if (s.isEmpty) return false;
    var cjk = 0;
    var letters = 0;
    for (final r in s.runes) {
      if (r < 0x80) {
        if ((r >= 65 && r <= 90) || (r >= 97 && r <= 122)) letters++;
        continue;
      }
      if (_isHan(r)) cjk++;
    }
    final total = cjk + letters;
    if (total == 0) return false;
    return cjk / total >= 0.3;
  }

  /// 是否需要翻译
  ///
  /// ⚠️ 2026-10-25 修：原实现只认"拉丁字母"，**假名 / 谚文 / 西里尔全都判成
  /// 不用翻** —— 日语字幕、日语频道标题会被当成中文直接跳过（用户点「翻译」
  /// 提示"这条本来就是中文"，测试按钮也一直返回原文）。
  /// 现在只要出现**假名 / 谚文 / 其它非汉字字母**就翻译；纯汉字 + 数字 + 符号
  /// 才算"已经是中文"。
  static bool needsTranslation(String s) {
    final t = s.trim();
    if (t.isEmpty) return false;
    var han = 0;
    var latin = 0;
    for (final r in t.runes) {
      if (r < 0x80) {
        if ((r >= 65 && r <= 90) || (r >= 97 && r <= 122)) latin++;
        continue;
      }
      if (_isHan(r)) {
        han++;
        continue;
      }
      // 平假名 / 片假名 / 半角片假名 → 日语
      if ((r >= 0x3040 && r <= 0x30FF) || (r >= 0x31F0 && r <= 0x31FF)) {
        return true;
      }
      // 谚文 → 韩语
      if ((r >= 0xAC00 && r <= 0xD7AF) ||
          (r >= 0x1100 && r <= 0x11FF) ||
          (r >= 0x3130 && r <= 0x318F)) {
        return true;
      }
      if (_isOtherLetter(r)) return true;
    }
    if (latin == 0) return false; // 只有汉字 / 数字 / 符号
    final total = han + latin;
    return han / total < 0.3; // 与 [looksChinese] 同一阈值
  }

  // ── 单条 ──────────────────────────────────────────────────

  /// 单条翻译成中文；失败抛异常（调用方自己 toast）。
  ///
  /// 已经是中文 / 没有拉丁字母 → 原样返回。
  Future<String> toZh(String text) async {
    final t = text.trim();
    if (t.isEmpty) return '';
    if (!needsTranslation(t)) return t;

    final hit = _oneCache[t];
    if (hit != null) return hit;

    final engine = await TranslateSettings.engine();
    String out;
    if (engine == 'google') {
      out = await _googleOne(t, 'auto', await TranslateSettings.to());
    } else {
      final list = engine == 'baidu'
          ? await _baidu([t], 'auto', await TranslateSettings.to())
          : await _openAi([t], 'auto', await TranslateSettings.to());
      out = list.isEmpty ? '' : list.first;
    }
    final result = out.trim();
    if (result.isEmpty) throw '翻译服务无返回';
    if (_oneCache.length >= _maxOneCache) _oneCache.clear();
    _oneCache[t] = result;
    return result;
  }

  // ── 批量 ──────────────────────────────────────────────────

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

    final result = switch (engine) {
      'google' => await _google(clean, src, dst),
      'baidu' => await _baidu(clean, src, dst),
      _ => await _openAi(clean, src, dst),
    };

    if (_cache.length > 64) _cache.remove(_cache.keys.first);
    _cache[key] = result;
    return result;
  }

  // ── Google 免 Key ──────────────────────────────────────────

  /// 复用一个 Dio。
  ///
  /// ⚠️ 原来是**每次请求新建一个再 close** —— 一集字幕几百条、一页漫画几十段，
  /// 就是几百次 HttpClient 建连/销毁，iOS 上既慢又容易撞 fd 上限。
  Dio? _googleClient;

  Dio get _googleDio => _googleClient ??= Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 15),
        headers: {
          'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                  'AppleWebKit/605.1.15 (KHTML, like Gecko) '
                  'Version/17.0 Mobile/15E148 Safari/604.1',
        },
      ));

  /// 单次请求最多送多少字符（端点超长会**静默截断**，不报错）
  static const int _googleMaxChars = 1500;

  /// 批量：逐条翻（端点只吃单条），并发 3，单条失败保留原文
  Future<List<String>> _google(
      List<String> lines, String from, String to) async {
    final out = List<String>.from(lines);
    final queue = <int>[];
    for (var i = 0; i < lines.length; i++) {
      if (needsTranslation(lines[i])) queue.add(i);
    }
    if (queue.isEmpty) return out;

    var ok = 0;
    var failed = 0;
    Future<void> worker() async {
      while (queue.isNotEmpty) {
        final i = queue.removeLast();
        try {
          out[i] = await _googleOne(lines[i], from, to);
          ok++;
        } catch (e) {
          failed++;
          AppLog.instance.log('[Translate] Google 单条失败: $e');
        }
      }
    }

    await Future.wait(List.generate(3, (_) => worker()));
    if (ok == 0 && failed > 0) {
      throw Exception('翻译服务不可用（Google 免 Key 端点无返回）');
    }
    return out;
  }

  /// 单条：超长先切块（否则尾部被端点静默截断），再走 dict → gtx
  Future<String> _googleOne(String text, String from, String to) async {
    final t = text.trim();
    if (t.length <= _googleMaxChars) return _googleOnce(t, from, to);
    final buf = StringBuffer();
    for (final part in _splitForGoogle(t)) {
      buf.write(await _googleOnce(part, from, to));
    }
    return buf.toString();
  }

  /// 按句读/空白把长文本切成 ≤1500 字符的块（不把单词劈两半）
  static List<String> _splitForGoogle(String s) {
    final out = <String>[];
    var rest = s;
    const marks = ' \n\t.,!?;:。！？，；：、';
    while (rest.length > _googleMaxChars) {
      var cut = _googleMaxChars;
      for (var i = _googleMaxChars; i > _googleMaxChars * 0.6; i--) {
        if (marks.contains(rest[i - 1])) {
          cut = i;
          break;
        }
      }
      out.add(rest.substring(0, cut).trim());
      rest = rest.substring(cut).trim();
    }
    if (rest.isNotEmpty) out.add(rest);
    return out;
  }

  Future<String> _googleOnce(String text, String from, String to) async {
    final q = Uri.encodeComponent(text);
    final tl = to == 'zh' ? 'zh-CN' : to;
    String? out;
    try {
      // 端点 1：dict-chrome-ex（实测最稳，返回 [["译文","en"], ...]）
      final r = await _googleDio.get<String>(
        '$googleDictEndpoint?client=dict-chrome-ex&sl=$from&tl=$tl&q=$q',
        options: Options(responseType: ResponseType.plain),
      );
      out = _parseDict(r.data);
    } catch (e) {
      debugPrint('[Translate] dict 失败: $e');
    }

    // 端点 2：gtx（返回 [[[译文, 原文, ...], ...], ...]）
    // 实测该端点经常对本机 IP 返回 429，所以放兜底位。
    if (out == null || out.isEmpty) {
      try {
        final r = await _googleDio.get<String>(
          '$googleGtxEndpoint?client=gtx&sl=$from&tl=$tl&dt=t&q=$q',
          options: Options(responseType: ResponseType.plain),
        );
        out = _parseGtx(r.data);
      } catch (e) {
        debugPrint('[Translate] gtx 失败: $e');
      }
    }

    if (out == null || out.trim().isEmpty) throw '翻译服务无返回';
    return out.trim();
  }

  String _parseGtx(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final data = jsonDecode(raw);
    if (data is! List || data.isEmpty) return '';
    final segs = data[0];
    if (segs is! List) return '';
    final buf = StringBuffer();
    for (final s in segs) {
      if (s is List && s.isNotEmpty && s[0] is String) {
        buf.write(s[0] as String);
      }
    }
    return buf.toString();
  }

  String _parseDict(String? raw) {
    if (raw == null || raw.isEmpty) return '';
    final data = jsonDecode(raw);

    // 实际返回（2026-10-25 实测）：
    //   [["奥本海默 4K","en"]]            单句
    //   [["句1","en"],["句2","en"]]       多句
    // 另兼容 ["译文"] / [{"trans":"译文"}] / {"sentences":[...]}
    if (data is List) {
      final buf = StringBuffer();
      for (final e in data) {
        if (e is String) {
          buf.write(e);
        } else if (e is Map && e['trans'] is String) {
          buf.write(e['trans'] as String);
        } else if (e is List && e.isNotEmpty && e.first is String) {
          buf.write(e.first as String);
        }
      }
      return buf.toString();
    }
    if (data is Map && data['sentences'] is List) {
      final buf = StringBuffer();
      for (final s in data['sentences'] as List) {
        if (s is Map && s['trans'] is String) buf.write(s['trans'] as String);
      }
      return buf.toString();
    }
    return '';
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
