import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/third_party_source.dart';

/// 音源导入解析 —— 移植自 Beans-Music 的 `ThirdPartySourceImportParser.swift`。
///
/// ── 为什么要这么宽容 ──────────────────────────────────────────
/// 用户从各处收集来的音源文件格式五花八门，**严格解析等于用不了**。
/// 原版按顺序尝试 5 种格式，谁先成功用谁：
///
///   1. **JSON** —— 数组 / `{"sources":[...]}` / `{"items":[...]}` / 单个对象
///   2. **完整 LX 脚本** —— 含 `module.exports` 或 `SERVER_SCRIPT_CONFIG`
///      的整份脚本。**整份存起来当 script**，而不是只抠出里面的 API 配置
///      （抠配置会丢掉脚本的真正能力）
///   3. **JS 里嵌的 JSON** —— `const x = {...}` / `const x = [...]`
///   4. **注释头风格** —— 文件开头注释块里的 `@name xxx` / `@template ...`
///   5. **宽松脚本** —— 上面都不中，只要看着像脚本就整份当 script
///
/// 全部失败才报"不支持的格式"。

/// 导入失败原因（对应 Beans 的 `ThirdPartySourceImportError`）
enum SourceImportError {
  empty('内容为空'),
  invalidUrl('地址必须是 http/https'),
  network('网络请求失败'),
  unsupported('无法识别的音源格式');

  const SourceImportError(this.message);
  final String message;
}

class SourceImportException implements Exception {
  final SourceImportError error;
  final String? detail;
  const SourceImportException(this.error, [this.detail]);

  String get message =>
      detail == null ? error.message : '${error.message}：$detail';

  @override
  String toString() => message;
}

class SourceImportParser {
  SourceImportParser._();

  /// 解析文本为音源列表。[fallbackName] 用于文件/URL 导入时兜底命名。
  static List<ThirdPartySource> parse(String text, {String? fallbackName}) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) throw const SourceImportException(SourceImportError.empty);

    // 1) JSON
    final jsonSources = _parseJson(trimmed, fallbackName);
    if (jsonSources != null && jsonSources.isNotEmpty) return _unique(jsonSources);

    // 2) 完整 LX 脚本（优先于"抠 JSON"，否则会丢掉脚本能力）
    if (_isLxScript(trimmed)) {
      final s = _parseLooseScript(trimmed, fallbackName);
      if (s.isNotEmpty) return _unique(s);
    }

    // 3) JS 里嵌的 JSON
    final scriptSources = _parseScript(trimmed, fallbackName);
    if (scriptSources.isNotEmpty) return _unique(scriptSources);

    // 4) 注释头风格
    final headerSources = _parseHeaderStyle(trimmed, fallbackName);
    if (headerSources.isNotEmpty) return _unique(headerSources);

    // 5) 宽松脚本
    final loose = _parseLooseScript(trimmed, fallbackName);
    if (loose.isNotEmpty) return _unique(loose);

    throw const SourceImportException(SourceImportError.unsupported);
  }

  /// 从 URL 拉取并解析（异步，由调用方负责网络）
  static List<ThirdPartySource> parseFetched(String body, String url) {
    final fallback = _nameFromUrl(url);
    return parse(body, fallbackName: fallback);
  }

  static String _nameFromUrl(String url) {
    final seg = Uri.tryParse(url)?.pathSegments ?? const [];
    if (seg.isEmpty) return '未命名音源';
    var last = seg.last;
    if (last.contains('.')) last = last.substring(0, last.lastIndexOf('.'));
    return last.isEmpty ? '未命名音源' : last;
  }

  // ============================================================
  // 1) JSON
  // ============================================================

  static List<ThirdPartySource>? _parseJson(String text, String? fallbackName) {
    dynamic obj;
    try {
      obj = jsonDecode(text);
    } catch (_) {
      return null;
    }

    if (obj is List) {
      final out = <ThirdPartySource>[];
      for (final e in obj) {
        final s = _fromDict(e, fallbackName);
        if (s != null) out.add(s);
      }
      return out.isEmpty ? null : out;
    }

    if (obj is Map) {
      final dict = obj.cast<String, dynamic>();
      // 常见包装：{"sources": [...]} / {"items": [...]}
      for (final key in ['sources', 'items', 'data', 'list']) {
        final nested = dict[key];
        if (nested is List) {
          final out = <ThirdPartySource>[];
          for (final e in nested) {
            final s = _fromDict(e, fallbackName);
            if (s != null) out.add(s);
          }
          if (out.isNotEmpty) return out;
        }
      }
      final single = _fromDict(dict, fallbackName);
      if (single != null) return [single];
    }
    return null;
  }

  /// 从一个字典建音源。字段名做了同义兼容（用户导入的源命名不统一）。
  static ThirdPartySource? _fromDict(dynamic raw, String? fallbackName) {
    if (raw is! Map) return null;
    final dict = raw.cast<String, dynamic>();

    final name = _string(dict, ['name', 'title', 'sourceName']) ??
        fallbackName ??
        '未命名音源';
    final script = _string(dict, ['script', 'scriptText', 'code']);
    final kind = _string(dict, ['kind', 'type']) ??
        (script == null ? 'keyword' : 'script');
    final urlPath = _string(dict, ['urlPath', 'path']) ?? 'url';
    final template = _templateString(dict);
    final quality = _string(dict, ['quality', 'br']) ?? '320k';

    // 既没有模板也没有脚本 → 不是有效源
    if (template.isEmpty && (script == null || script.isEmpty)) return null;

    final headers = <String, String>{};
    final rawHeaders = dict['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) {
        if (v != null && v.toString().isNotEmpty) headers[k.toString()] = v.toString();
      });
    }
    // 有些源把 header 平铺在顶层（user-agent 等）
    for (final key in ['user-agent', 'User-Agent', 'referer', 'Referer', 'cookie', 'Cookie']) {
      final v = _string(dict, [key]);
      if (v != null && v.isNotEmpty) headers[key] = v;
    }
    // 多音质列表
    final qualities = _qualityStrings(dict);
    if (qualities.isNotEmpty) headers['qualities'] = qualities.join(',');
    if (!headers.containsKey('source')) {
      final plat = _string(dict, ['source', 'platform']);
      if (plat != null && plat.isNotEmpty) headers['source'] = plat;
    }

    return ThirdPartySource(
      id: _string(dict, ['id']) ?? _newId(),
      name: name,
      kind: kind,
      template: template,
      urlPath: urlPath,
      headers: headers,
      quality: quality,
      script: script,
      enabled: dict['enabled'] as bool? ?? true,
    );
  }

  static String _templateString(Map<String, dynamic> dict) {
    final t = _string(dict, ['template']);
    if (t != null && t.isNotEmpty) return t;
    return _string(dict, ['apiUrl', 'baseURL', 'baseUrl', 'url', 'endpoint']) ?? '';
  }

  static List<String> _qualityStrings(Map<String, dynamic> dict) {
    for (final key in ['qualities', 'qualityList', 'brs']) {
      final v = dict[key];
      if (v is List) {
        return v.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
      }
      if (v is String && v.contains(',')) {
        return v.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      }
    }
    return const [];
  }

  // ============================================================
  // 2/5) 脚本
  // ============================================================

  /// 是不是一份完整 LX 脚本
  static bool _isLxScript(String text) =>
      text.contains('module.exports') ||
      text.contains('SERVER_SCRIPT_CONFIG') ||
      text.contains('EVENT_NAMES');

  /// 脚本法：整份当 script 存起来（保留脚本能力）
  static List<ThirdPartySource> _parseLooseScript(String text, String? fallbackName) {
    // 太短的不可能是脚本，避免把随便一段文字当脚本
    if (text.length < 40) return const [];

    // 判定"像脚本"要够严：早期版本只要文本含 `const `/`let ` 就算脚本，
    // 结果连「JS 里嵌了一份 JSON 配置」的文件也被整份当脚本导入，
    // kind 从 keyword 变 script（用户配的模板就失效了）。
    // 现在要求必须有**真正的 LX 脚本特征**才走这条兜底。
    final hasLxMarker = text.contains('module.exports') ||
        text.contains('SERVER_SCRIPT_CONFIG') ||
        text.contains('EVENT_NAMES') ||
        text.contains('globalThis.lx');
    final hasJsBody = (text.contains('function ') || text.contains('=>')) &&
        (text.contains('return') || text.contains('request'));
    if (!hasLxMarker && !hasJsBody) return const [];

    // 从脚本里找名字
    var name = fallbackName ?? '未命名音源';
    final m = RegExp(r'''["']?name["']?\s*[:=]\s*["']([^"']{1,60})["']''')
        .firstMatch(text);
    if (m != null) name = m.group(1)!;

    return [
      ThirdPartySource(
        id: _newId(),
        name: name,
        kind: 'script',
        template: '',
        script: text,
      ),
    ];
  }

  // ============================================================
  // 3) JS 里嵌的 JSON
  // ============================================================

  static List<ThirdPartySource> _parseScript(String text, String? fallbackName) {
    // 用后向引用把 `const x = { ... }` 的**配对括号**吃准。
    // 早期版本用 `(\{[\s\S]*?\})` 非贪婪，遇到 `[{...},{"..."}]` 这种
    // 数组会只吃到第一个对象的 `}` 就停 —— 结果把 JSON 数组当"嵌入配置"
    // 抠出半截，而且 kind 也被误判。改成同层配对匹配后两边都对。
    final patterns = [
      // const/var/let xxx = { ... }   （内部可含一层嵌套对象）
      RegExp(r'(?:const|var|let)\s+\w+\s*=\s*(\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\})\s*;?'),
      // module.exports = { ... }
      RegExp(r'module\.exports\s*=\s*(\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\})\s*;?'),
      // const/var/let xxx = [ ... ]  （对象数组）
      RegExp(r'(?:const|var|let)\s+\w+\s*=\s*(\[[\s\S]*?\])\s*;'),
    ];
    for (final p in patterns) {
      for (final m in p.allMatches(text)) {
        final jsonText = m.group(1);
        if (jsonText == null) continue;
        final parsed = _parseJson(jsonText, fallbackName);
        if (parsed != null && parsed.isNotEmpty) return parsed;
      }
    }
    return const [];
  }

  // ============================================================
  // 4) 注释头风格  @name xx / @template ...
  // ============================================================

  static List<ThirdPartySource> _parseHeaderStyle(String text, String? fallbackName) {
    final block = _extractCommentBlock(text);
    if (block == null) return const [];

    final values = <String, String>{};
    for (final line in block.split('\n')) {
      final cleaned = line.trim().replaceAll(RegExp(r'^[*\s]+'), '').trim();
      if (!cleaned.startsWith('@')) continue;
      final content = cleaned.substring(1);
      final m = RegExp(r'^(\S+)[\s=]+(.*)$').firstMatch(content);
      if (m == null) continue;
      values[m.group(1)!.toLowerCase()] = m.group(2)!.trim();
    }
    if (values.isEmpty) return const [];

    final template = values['template'] ?? '';
    if (template.isEmpty) return const [];

    final headers = <String, String>{};
    final headersRaw = values['headers'];
    if (headersRaw != null && headersRaw.isNotEmpty) {
      try {
        final obj = jsonDecode(headersRaw);
        if (obj is Map) {
          obj.forEach((k, v) => headers[k.toString()] = v.toString());
        }
      } catch (_) {
        // 退化成 k=v,k=v 形式
        for (final pair in headersRaw.split(',')) {
          final parts = pair.split('=');
          if (parts.length == 2) headers[parts[0].trim()] = parts[1].trim();
        }
      }
    }

    return [
      ThirdPartySource(
        id: _newId(),
        name: (values['name'] ?? '').isNotEmpty
            ? values['name']!
            : (fallbackName ?? '未命名音源'),
        kind: (values['kind'] ?? 'keyword'),
        template: template,
        urlPath: (values['urlpath'] ?? 'url'),
        headers: headers,
        quality: values['quality'] ?? values['br'] ?? '320k',
        enabled: values['enabled']?.toLowerCase() != 'false',
      ),
    ];
  }

  /// 取文件开头连续的注释块（// 或 /* */）
  static String? _extractCommentBlock(String text) {
    final lines = text.split('\n');
    final buf = StringBuffer();
    var started = false;
    for (final line in lines.take(80)) {
      final t = line.trim();
      final isComment = t.startsWith('//') ||
          t.startsWith('*') ||
          t.startsWith('/*') ||
          t.startsWith('*/') ||
          t.startsWith('#');
      if (isComment) {
        started = true;
        buf.writeln(t);
      } else if (started && t.isNotEmpty) {
        break; // 注释块结束
      }
    }
    final s = buf.toString();
    return s.contains('@') ? s : null;
  }

  // ============================================================
  // 工具
  // ============================================================

  static String? _string(Map<String, dynamic> dict, List<String> keys) {
    for (final k in keys) {
      final v = dict[k];
      if (v == null) continue;
      final s = v.toString().trim();
      if (s.isNotEmpty) return s;
    }
    return null;
  }

  /// 生成唯一 id。
  ///
  /// ⚠️ 不能只用 `DateTime.now().microsecondsSinceEpoch`：
  /// 解析一个多条目的 JSON 时循环极快，同一个微秒内会生成**相同 id**，
  /// 随后 `_unique` 按 id 去重就会把后面的源当"重复"丢掉
  /// （表现：导入 2 条只成功 1 条，且不报错）。
  /// 所以加一个进程内自增序号。
  static int _seq = 0;
  static String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_seq++}';

  /// 去重：同 id 或同名只留一条
  static List<ThirdPartySource> _unique(List<ThirdPartySource> list) {
    final seenId = <String>{};
    final seenName = <String>{};
    final out = <ThirdPartySource>[];
    for (final s in list) {
      if (seenId.contains(s.id)) continue;
      if (seenName.contains(s.name)) continue;
      seenId.add(s.id);
      seenName.add(s.name);
      out.add(s);
    }
    return out;
  }

  /// 便捷：把解析结果直接并入存储，返回新增条数
  static Future<int> importIntoStore(String text, {String? fallbackName}) async {
    final list = parse(text, fallbackName: fallbackName);
    final n = await ThirdPartySourceStore.instance.addAll(list);
    debugPrint('[MusicSource] 导入 ${list.length} 条，新增 $n 条');
    return n;
  }
}
