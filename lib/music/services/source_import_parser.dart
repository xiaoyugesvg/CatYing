import 'dart:convert';

import 'package:dio/dio.dart';
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

    // 1.5) **MusicFree 插件**（必须在 LX 之前判，否则会被当普通 JS 脚本）
    //
    // MusicFree 插件与 LX 源是两种形态：
    //   LX 源：`lx.on('request')` / `module.exports = { musicUrl }`
    //   MusicFree：`module.exports = { platform, getMediaSource, ... }`
    //             且几乎都 `require('axios')`
    //
    // ⚠️ 必须显式标 `kind: 'musicfree'` —— Node 侧虽然也能自动判定，
    // 但显式标记能避免"看起来像 LX 但其实是 MusicFree"时走错路径
    //（Node 侧 `kind === 'script'` 是**强制**走 LX 的，不会自动纠正）。
    if (_looksLikeMusicFree(trimmed)) {
      final s = _parseMusicFreePlugin(trimmed, fallbackName);
      if (s.isNotEmpty) return _unique(s);
    }

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
  // 1.5) MusicFree 插件
  // ============================================================

  /// 是不是 MusicFree 插件。
  ///
  /// ── 判据（与 Node 侧 `musicfree_adapter.looksLikeMusicFree` 对齐）──
  /// MusicFree 插件的 `module.exports` 形状是：
  ///   `{ platform: '名称', author, version, getMediaSource(musicItem, quality), … }`
  ///
  /// 所以三个特征：
  ///   ① 有 `platform:`（MusicFree 的身份标识，LX 源没有这个概念）
  ///   ② 有取播放地址的方法（`getMediaSource` / `getMusicUrl` / `getMusicInfo`）
  ///   ③ **不是 LX 源**（`lx.on` / `EVENT_NAMES` 出现就归 LX）
  ///
  /// ⚠️ 第 ③ 条很关键：有些 LX 源也会 `require('axios')`，
  /// 只看 require 会把它们误判成 MusicFree（那边没有 `lx` 对象 → 报错）。
  static bool _looksLikeMusicFree(String text) {
    // LX 标志：出现就绝不按 MusicFree 处理
    final isLx = text.contains('EVENT_NAMES') ||
        RegExp(r'\blx\s*\.\s*on\b').hasMatch(text) ||
        text.contains('globalThis.lx');
    if (isLx) return false;

    final hasPlatform = RegExp(r'platform\s*:').hasMatch(text);
    final hasGetter =
        RegExp(r'getMediaSource|getMusicUrl|getMusicInfo').hasMatch(text);
    final needsAxios = RegExp(r'''require\s*\(\s*['"]axios['"]\s*\)''')
        .hasMatch(text);
    final hasModuleExports = text.contains('module.exports') ||
        RegExp(r'exports\s*\.\s*default').hasMatch(text);

    // ① + ②：标准形态
    if (hasPlatform && hasGetter) return true;
    // 有 module.exports + require('axios')：压缩后导出名可能变了，
    // 但这种组合也几乎一定是 MusicFree 插件（LX 源不需要 axios）
    if (hasModuleExports && needsAxios) return true;
    return false;
  }

  /// 解析 MusicFree 插件 → 存成 `kind: 'musicfree'`
  ///
  /// 与 LX 脚本的区别只有两点：
  ///   · `kind` 标成 `'musicfree'`（Node 侧据此走适配层 + 注入 axios/he）
  ///   · 名字从 `platform:` 取（LX 脚本一般从注释头 `@name` 取）
  static List<ThirdPartySource> _parseMusicFreePlugin(
      String text, String? fallbackName) {
    var name = _musicFreeName(text) ??
        (fallbackName?.trim().isNotEmpty == true
            ? fallbackName!.trim()
            : 'MusicFree 音源');

    // 音质：MusicFree 插件常在 platform 附近声明，这里给个稳妥默认
    final quality = _musicFreeQuality(text);

    return [
      ThirdPartySource(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: name,
        kind: 'musicfree',
        template: '',
        script: text,
        quality: quality,
      ),
    ];
  }

  static String? _musicFreeName(String text) {
    // module.exports = { platform: "👖裤佬SVIP音源", ... }
    for (final re in [
      RegExp(r'''platform\s*:\s*["']([^"']{1,60})["']'''),
      RegExp(r'''["']platform["']\s*:\s*["']([^"']{1,60})["']'''),
      RegExp(r'''name\s*:\s*["']([^"']{1,60})["']'''),
    ]) {
      final m = re.firstMatch(text);
      final v = m?.group(1)?.trim();
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }

  static String _musicFreeQuality(String text) {
    // 插件里偶有 `qualitys: ['128k','320k','flac']` / `quality: '320k'`
    final m = RegExp(r'''qualitys?\s*:\s*\[?\s*["']([^"']{2,10})["']''')
        .firstMatch(text);
    final q = m?.group(1);
    return (q != null && q.isNotEmpty) ? q : '320k';
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
      // ── 🔴 必须用**宽容解析**，不能 `as bool?`（修一个导入即失败）────
      //
      // 原来写的是 `enabled: dict['enabled'] as bool? ?? true`。
      // 用户导入的音源里 `enabled` 完全可能是**字符串或数字**
      //（`"enabled": "false"` / `"enabled": 0` —— 从别的 App 导出的
      //  配置里很常见），那时这个硬转换抛
      // `type 'String' is not a subtype of type 'bool?'`：
      //   · 整个导入失败，而 UI 只能显示这句**英文类型错误**，
      //     用户完全不知道是自己那份 JSON 的哪个字段有问题 ✗
      //
      // ⚠️ 讽刺的是 `third_party_source.dart` 里**已经**为**同一个写法**
      //    加了宽容解析 `_asBool`，注释还专门写了这段教训
      //   （"一条脏数据就把整个音源列表废掉"）—— 但这里是**另一份拷贝**，
      //    当时漏改了。
      //
      // 这里就地写一份等价的宽容解析（`_asBool` 是 `ThirdPartySource`
      // 的私有静态方法，本文件用不到）。
      enabled: _boolOf(dict['enabled']),
    );
  }

  /// 宽容解析 bool：兼容 `true/false`、`"true"/"false"`、`1/0`、
  /// `"1"/"0"`、`yes/no/on/off`；看不懂的一律当 `true`（默认启用）。
  ///
  /// 语义与 `ThirdPartySource._asBool` **保持一致**（两处都别单独改）。
  static bool _boolOf(Object? v) {
    if (v == null) return true;
    if (v is bool) return v;
    if (v is num) return v != 0;
    final s = v.toString().trim().toLowerCase();
    if (s.isEmpty) return true;
    if (s == 'true' || s == '1' || s == 'yes' || s == 'y' || s == 'on') {
      return true;
    }
    if (s == 'false' || s == '0' || s == 'no' || s == 'n' || s == 'off') {
      return false;
    }
    return true;
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
  ///
  /// ⚠️ **`lx.on(...)` 是必须认的**（这是 LX 源最常见的写法）。
  /// 早期只认 `module.exports` / `SERVER_SCRIPT_CONFIG` / `EVENT_NAMES`，
  /// 结果「直接用 `lx.on('musicUrl', …)` 注册」的脚本会被判成"无法识别"
  /// ——而 `星海音乐源` 那种解构写法（`const { on } = globalThis.lx`）
  /// 连 `lx.on` 字样都没有，只能靠后面 [hasJsBody] 的兜底。
  static bool _isLxScript(String text) =>
      text.contains('module.exports') ||
      text.contains('SERVER_SCRIPT_CONFIG') ||
      text.contains('EVENT_NAMES') ||
      text.contains('globalThis.lx') ||
      _lxMarkerRe.hasMatch(text);

  /// LX 调用标志：`lx.on(` / `lx.send(` / `lx.request(`
  ///（容忍空格：`lx . on (`）
  static final RegExp _lxMarkerRe = RegExp(r'\blx\s*\.\s*(?:on|send|request)\s*\(');

  /// 脚本法：整份当 script 存起来（保留脚本能力）
  static List<ThirdPartySource> _parseLooseScript(String text, String? fallbackName) {
    // 太短的不可能是脚本，避免把随便一段文字当脚本
    if (text.length < 40) return const [];

    // 判定"像脚本"要够严：早期版本只要文本含 `const `/`let ` 就算脚本，
    // 结果连「JS 里嵌了一份 JSON 配置」的文件也被整份当脚本导入，
    // kind 从 keyword 变 script（用户配的模板就失效了）。
    // 现在要求必须有**真正的 LX 脚本特征**才走这条兜底。
    // ⚠️ 要和 `_isLxScript` 保持一致：漏了 `lx.on(...)` 的话，
    // 上面 `_isLxScript` 判成"是 LX 脚本"，这里却因为 hasLxMarker=false
    // 而走 hasJsBody 分支 —— 两条判据不一致时"星海"那类解构脚本
    //（`const { on } = globalThis.lx` + `on(EVENT_NAMES.request, …)`）
    // 会掉到最后的 `unsupported`。
    final hasLxMarker = text.contains('module.exports') ||
        text.contains('SERVER_SCRIPT_CONFIG') ||
        text.contains('EVENT_NAMES') ||
        text.contains('globalThis.lx') ||
        _lxMarkerRe.hasMatch(text);
    final hasJsBody = (text.contains('function ') || text.contains('=>')) &&
        (text.contains('return') || text.contains('request'));
    if (!hasLxMarker && !hasJsBody) return const [];

    // ── 从脚本里找名字（**有严格优先级**）────────────────────────
    //
    // ⚠️ 不能随便抓第一个 `name:` —— 实测「星海音乐源」的脚本里有
    //     const KW_CHANNELS_PREMIUM = [{ name: 'car_conv2', url: … }, …]
    //   这是**渠道配置的字段**，结果音源在 UI 里显示成了 "car_conv2"
    //   （真实名字在注释头 `@name 星海音乐源`）✗。
    //
    // 优先级：
    //   ① 注释头 `@name xxx`        —— 作者写给人看的，最可信
    //   ② `SCRIPT_NAME = 'xxx'`     —— 脚本自己的标识变量
    //   ③ 顶层 `name:` 只有一个时才用（多个 = 多半是内部配置，放弃）
    //   ④ fallbackName（文件名/URL）—— 兜底
    var name = fallbackName ?? '未命名音源';

    // ① 注释头
    final header = _extractCommentBlock(text);
    if (header != null) {
      final hm = RegExp(r'^\s*[*\s]*@name\s+(.+)$', multiLine: true)
          .firstMatch(header);
      final hv = hm?.group(1)?.trim();
      if (hv != null && hv.isNotEmpty) name = hv;
    }

    // ② SCRIPT_NAME / SOURCE_NAME
    if (name == (fallbackName ?? '未命名音源')) {
      final sm = RegExp(
              r'''(?:SCRIPT_NAME|SOURCE_NAME|SCRIPT_TITLE)\s*=\s*["']([^"']{1,60})["']''')
          .firstMatch(text);
      final sv = sm?.group(1)?.trim();
      if (sv != null && sv.isNotEmpty) name = sv;
    }

    // ③ 顶层 name: —— **只有唯一一个**才敢用（多个就是内部配置）
    if (name == (fallbackName ?? '未命名音源')) {
      final all = RegExp(r'''["']?name["']?\s*[:=]\s*["']([^"']{1,60})["']''')
          .allMatches(text)
          .toList();
      if (all.length == 1) name = all.first.group(1)!;
    }

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

  /// 便捷：把解析结果直接并入存储，返回新增条数。
  ///
  /// ── 🔴 这里原来有一个真实的缺陷（用户实测：音源导入用不了）──────
  /// 旧实现是 `parse(text)` 一把梭 —— 但导入弹层的输入框里
  /// **用户粘贴的常常是一个网址**，于是一整行 `https://...js`
  /// 被当成"脚本内容"去解析：
  ///   · 不是 JSON                       ✗
  ///   · 不含 module.exports 等 LX 特征  ✗
  ///   · 无 `@name/@template` 注释头     ✗
  ///   · 长度够但不是脚本                ✗
  /// → 必然抛 `unsupported('无法识别的音源格式')`。
  /// **它从来没有去下载那个网址。**
  ///
  /// 同一文件里其实早就写好了 [parseFetched]（拉取后再解析），
  /// 只是**没有任何调用方** —— 现在在这里接上。
  static Future<int> importIntoStore(String text, {String? fallbackName}) async {
    final trimmed = text.trim();
    // 输入是一个网址 → 先下载再解析（否则只会报"无法识别"）
    if (_looksLikeUrl(trimmed)) {
      final body = await _fetchUrl(trimmed);
      final list = parseFetched(body, trimmed);
      final n = await ThirdPartySourceStore.instance.addAll(list);
      debugPrint('[MusicSource] 从网址导入 ${list.length} 条，新增 $n 条');
      return n;
    }
    final list = parse(trimmed, fallbackName: fallbackName);
    final n = await ThirdPartySourceStore.instance.addAll(list);
    debugPrint('[MusicSource] 导入 ${list.length} 条，新增 $n 条');
    return n;
  }

  /// 是不是一个 http/https 网址（而不是脚本文本）
  static bool _looksLikeUrl(String s) {
    if (!(s.startsWith('http://') || s.startsWith('https://'))) return false;
    // 单行、无换行、无大括号 —— 基本可以断定是网址而非脚本
    if (s.contains('\n')) return false;
    if (s.contains('{') || s.contains('}')) return false;
    return s.length < 2000;
  }

  // ============================================================
  // 按类型导入（给「洛雪音乐源」「MusicFree 源」两个独立入口用）
  // ============================================================

  /// 导入并**要求音源类型匹配**。
  ///
  /// ── 为什么需要"强制类型"而不是靠自动识别 ────────────────────────
  /// 界面上有**两个独立入口**（洛雪音乐源 / MusicFree 源）。如果用户在
  /// "洛雪音乐源"卡里粘了一个 MusicFree 插件，自动识别会**照收**
  /// （因为解析成功），但用户的意图是"加一个洛雪源" ——
  /// 结果他会困惑"我明明加在洛雪里，怎么跑 MusicFree 去了"。
  ///
  /// 所以这里：
  ///   · 类型**匹配** → 正常入库，返回 (count, null)
  ///   · 类型**不匹配** → 不入库，返回 (0, 提示语)，由 UI 提示用户换卡
  ///
  /// [expectMusicFree]：true = 期待 MusicFree 插件；false = 期待洛雪(LX)源。
  static Future<({int count, String? mismatch})> importIntoStoreTyped(
    String text, {
    required bool expectMusicFree,
    String? fallbackName,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const SourceImportException(SourceImportError.empty);
    }

    // 网址 → 先拉下来（和 importIntoStore 同一套镜像/重试逻辑）
    final String body;
    if (_looksLikeUrl(trimmed)) {
      body = await _fetchUrl(trimmed);
      fallbackName ??= _nameFromUrl(trimmed);
    } else {
      body = trimmed;
    }

    final list = fallbackName != null
        ? parseFetched(body, fallbackName)
        : parse(body);
    if (list.isEmpty) {
      throw const SourceImportException(SourceImportError.unsupported);
    }

    // 类型校验：**只要有一个不匹配就整体拒绝**（避免半对半错更难解释）
    final mismatchNames = list
        .where((s) => _kindMatches(s.kind, expectMusicFree) == false)
        .map((s) => s.name)
        .toList();
    if (mismatchNames.isNotEmpty) {
      final actual = list.first.isMusicFree ? 'MusicFree 插件' : '洛雪音乐源';
      final want = expectMusicFree ? 'MusicFree 源' : '洛雪音乐源';
      return (
        count: 0,
        mismatch: '这是「$actual」，不是「$want」。请到对应的卡片里导入。'
      );
    }

    final n = await ThirdPartySourceStore.instance.addAll(list);
    debugPrint('[MusicSource] 按类型导入(${expectMusicFree ? "musicfree" : "lx"}) '
        '${list.length} 条，新增 $n 条');
    return (count: n, mismatch: null);
  }

  /// 音源类型是否符合预期
  ///
  /// ⚠️ 洛雪一侧接受 `script` **和** `keyword`（模板法也是洛雪生态的合法源），
  /// MusicFree 一侧**只**接受 `musicfree`。
  static bool _kindMatches(String kind, bool expectMusicFree) {
    if (expectMusicFree) return kind == 'musicfree';
    return kind == 'script' || kind == 'keyword';
  }

  /// 拉取网址内容。
  ///
  /// ⚠️ **不要对 path 再做 `Uri.encodeFull`** ——
  /// `Uri.parse` 已经把中文等非 ASCII 字符编码好了
  ///（`星海音乐源.js` → `%E6%98%9F...`），再编码一次会变成 `%25E6...`
  /// 让服务器 404。直接用 `Uri.parse(url).toString()` 即可。
  static Future<String> _fetchUrl(String url) async {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      throw const SourceImportException(SourceImportError.invalidUrl);
    }
    // 直连优先；GitHub 系域名在国内被墙，失败后自动走镜像前缀轮询
    final attempts = _fetchAttempts(uri.toString());
    Object? lastErr;
    for (final target in attempts) {
      try {
        return await _fetchOnce(target);
      } catch (e) {
        lastErr = e; // 继续试下一个镜像，全部失败才抛
      }
    }
    if (lastErr is SourceImportException) throw lastErr;
    throw SourceImportException(
        SourceImportError.network, _shortError(lastErr ?? ''));
  }

  /// 尝试列表：直连 → GitHub 加速镜像（只对 GitHub 系域名生效）
  static List<String> _fetchAttempts(String url) {
    final host = Uri.parse(url).host.toLowerCase();
    final isGithubHost = host.endsWith('raw.githubusercontent.com') ||
        host == 'github.com' ||
        host.endsWith('githubusercontent.com') ||
        host.endsWith('github.io');
    if (!isGithubHost) return [url];
    const mirrors = [
      '', // 直连
      'https://ghfast.top/',
      'https://ghproxy.net/',
      'https://mirror.ghproxy.com/',
      'https://gh-proxy.com/',
      'https://ghproxy.cc/',
    ];
    return [
      for (final m in mirrors) m.isEmpty ? url : '$m$url',
    ];
  }

  static Future<String> _fetchOnce(String target) async {
    try {
      final dio = Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 12),
        receiveTimeout: const Duration(seconds: 20),
        // 音源站点五花八门，有的返回非 200 但内容是脚本；仍然按内容判断
        validateStatus: (c) => c != null && c >= 200 && c < 400,
        responseType: ResponseType.plain,
      ));
      final res = await dio.get<String>(target);
      final body = res.data ?? '';
      if (body.trim().isEmpty) {
        throw const SourceImportException(
            SourceImportError.network, '服务器返回了空内容');
      }
      return body;
    } on SourceImportException {
      rethrow;
    } catch (e) {
      throw SourceImportException(SourceImportError.network, _shortError(e));
    }
  }

  /// 网络异常 → 简短说明（技术细节进日志）
  static String _shortError(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') || s.contains('Connection')) {
      return '连不上服务器，请检查网络或网址';
    }
    if (s.contains('timeout') || s.contains('Timeout')) {
      return '请求超时，请重试';
    }
    if (s.contains('404')) return '网址不存在（404）';
    if (s.contains('403')) return '服务器拒绝访问（403）';
    return '下载失败，请检查网址';
  }
}
