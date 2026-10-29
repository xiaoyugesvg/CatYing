// lib/services/xbpq/xbpq_url.dart
//
// XBPQ 地址组装 —— 对齐 huoyi `provider_xbpq.go` 的 `xbpqRenderURL`
// / `xbpqJoinLink` / `xbpqIDFromLink` / `xbpqLinkFromID`，以及
// `provider_xbpq_template.go` 的 `xbpqCleanEmptySegments`、
// `provider_duanju.go` 的 `duanjuAbsolute`、
// `provider_duanju_maccms.go` 的 `maccmsSourceIDFromURL`。
//
// 三件事：① 填占位符并把相对路径转绝对；② 域名重写（镜像站）；
// ③ 详情链接 ↔ 稳定 ID 的双向转换（外加 `url;post;body` 规格的拆/拼）。

/// 规则地址 + 方法 + 请求体。`url;post;body` 形态拆出来的结果。
class XbpqRequestSpec {
  const XbpqRequestSpec({
    required this.address,
    this.method = '',
    this.body = '',
  });

  final String address;

  /// 空串表示 GET；目前只会是 `POST`。
  final String method;
  final String body;

  bool get isPost => method.isNotEmpty;
}

class XbpqUrl {
  XbpqUrl._();

  /// 解析 `url` / `url;post;body` / `url;get` 形态。
  static XbpqRequestSpec splitSpec(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return const XbpqRequestSpec(address: '');

    final parts = text.split(';');
    final address = parts[0].trim();
    if (parts.length > 1 && parts[1].trim().toLowerCase() == 'post') {
      return XbpqRequestSpec(
        address: address,
        method: 'POST',
        body: parts.skip(2).join(';'),
      );
    }
    return XbpqRequestSpec(address: address);
  }

  /// 反向拼回 `url;post;body`（搜索会先渲染地址再重新组规格）。
  static String composeSpec(String address, String method, String body) {
    if (method.isEmpty) return address;
    return '$address;$method;$body';
  }

  // ============================================================
  // 请求模板渲染
  // ============================================================

  /// 渲染请求模板：填 `{key}` 占位符 → 补全相对路径 → 域名对齐 base。
  ///
  /// `;;` 之后是规则作者写的注释，直接截掉。
  /// 域名重写的理由：XBPQ 规则惯例「分类url 域名 = 主页url 域名」，站点换
  /// 镜像域名后规则里写死的绝对地址会失效，所以以站源当前地址为准重写 host。
  /// 只重写请求模板，不影响已抽出的内容链接。
  static String render(String template, String base, Map<String, String> values) {
    var out = template.trim();
    final comment = out.indexOf(';;');
    if (comment >= 0) out = out.substring(0, comment);

    for (final entry in values.entries) {
      out = out.replaceAll('{${entry.key}}', entry.value);
    }
    out = out.replaceAll(RegExp(r'[\t\r\n]'), '').trim();
    if (out.isEmpty) return '';

    if (!out.startsWith('http') && !out.startsWith('//')) {
      if (!out.startsWith('/')) out = '/$out';
      out = base + out;
    }
    if (out.startsWith('//')) out = 'https:$out';

    final Uri parsed;
    try {
      parsed = Uri.parse(out);
    } catch (_) {
      return '';
    }
    if (parsed.host.isEmpty) return '';

    final baseParsed = Uri.tryParse(base);
    if (baseParsed != null &&
        baseParsed.host.isNotEmpty &&
        parsed.host != baseParsed.host) {
      final authority = baseParsed.hasPort
          ? '${baseParsed.host}:${baseParsed.port}'
          : baseParsed.host;
      return _rebuild(parsed, baseParsed.scheme, authority);
    }
    return out;
  }

  /// 用新的 scheme/authority 重建地址（保留 path/query/fragment）。
  static String _rebuild(Uri parsed, String scheme, String authority) {
    final b = StringBuffer('$scheme://$authority');
    final path = parsed.path;
    if (path.isNotEmpty) {
      b.write(path.startsWith('/') ? path : '/$path');
    }
    if (parsed.hasQuery) b.write('?${parsed.query}');
    if (parsed.hasFragment) b.write('#${parsed.fragment}');
    return b.toString();
  }

  /// 把规则里抽出来的链接转成绝对地址。
  ///
  /// `+` 拼接形态（多线链接）只保留被双引号包裹的字面量段 —— 其余段是
  /// 截取指令，在 `XbpqCut` 里已经用过了。
  static String joinLink(String pageUrl, String raw) {
    var link = raw.trim();
    if (link.isEmpty || link.startsWith(r'$')) return '';

    if (link.toLowerCase().startsWith('href=')) {
      link = link.substring('href='.length);
    }
    if (link.contains('+')) {
      final b = StringBuffer();
      for (final segment in link.split('+')) {
        if (segment.length >= 2 &&
            segment.startsWith('"') &&
            segment.endsWith('"')) {
          b.write(segment.substring(1, segment.length - 1));
        }
      }
      link = b.toString();
    }
    if (link.isEmpty) return '';
    return absolute(pageUrl, link);
  }

  /// 相对地址转绝对（对齐 Go `duanjuAbsolute`）。
  static String absolute(String base, String reference) {
    final ref = reference.trim();
    if (ref.isEmpty) return '';
    if (ref.startsWith('//')) return 'https:$ref';

    final Uri parsed;
    try {
      parsed = Uri.parse(ref);
    } catch (_) {
      return '';
    }
    if (parsed.isAbsolute) return parsed.toString();

    final origin = Uri.tryParse('${base.replaceAll(RegExp(r'/+$'), '')}/');
    if (origin == null) return '';
    try {
      return origin.resolveUri(parsed).toString();
    } catch (_) {
      return '';
    }
  }

  // ============================================================
  // 详情链接 ↔ ID
  // ============================================================

  /// 从详情链接提取稳定 ID。
  ///
  /// 规则写了 `详情url` 模板时提纯数字 ID（可用模板无损还原）；
  /// 否则把整条链接编码成 `u` 前缀 ID，详情阶段再解回来。
  static String idFromLink(String link, bool numeric) {
    if (numeric) {
      final id = _maccmsId(link);
      if (id.isNotEmpty) return id;
    }
    return 'u${Uri.encodeQueryComponent(link)}';
  }

  /// 还原 `u` 前缀 ID 对应的详情页地址；不是该形态返回空串。
  static String linkFromId(String id) {
    if (!id.startsWith('u')) return '';
    final String decoded;
    try {
      decoded = Uri.decodeQueryComponent(id.substring(1));
    } catch (_) {
      return '';
    }
    return decoded.startsWith('http') ? decoded : '';
  }

  static final RegExp _numericId = RegExp(r'^[1-9][0-9]{0,17}$');

  /// `/voddetail|detail|show|vod|drama|movie|tv/{数字}` 形态。
  static final RegExp _detailPath = RegExp(
    r'/(?:voddetail|detail|show|vod|drama|movie|tv)/([0-9]+)(?:[-./]|$)',
    caseSensitive: false,
  );

  /// `/vod123` 这类粘连形态（含 `xs`/`vs` 短路径）。
  static final RegExp _detailGlued = RegExp(
    r'/(?:voddetail|detail|show|vod|drama|movie|tv|xs|vs)([1-9][0-9]{0,17})(?:[-./]|$)',
    caseSensitive: false,
  );

  /// 对齐 Go `maccmsSourceIDFromURL`：先按两条路径正则，再倒着扫路径段。
  static String _maccmsId(String link) {
    final Uri parsed;
    try {
      parsed = Uri.parse(link);
    } catch (_) {
      return '';
    }
    final path = parsed.path.endsWith('.html')
        ? parsed.path.substring(0, parsed.path.length - '.html'.length)
        : parsed.path;
    final probe = '$path/';

    final byPath = _detailPath.firstMatch(probe);
    if (byPath != null) return byPath.group(1)!;

    final byGlued = _detailGlued.firstMatch(probe);
    if (byGlued != null) return byGlued.group(1)!;

    final segments = path
        .replaceAll(RegExp(r'^/+|/+$'), '')
        .split('/')
        .where((e) => e.isNotEmpty)
        .toList();
    for (var i = segments.length - 1; i >= 0; i--) {
      var candidate = segments[i];
      if (candidate.endsWith('.html')) {
        candidate = candidate.substring(0, candidate.length - '.html'.length);
      }
      if (_numericId.hasMatch(candidate)) return candidate;
      final dash = candidate.indexOf('-');
      if (dash >= 0) {
        final tail = candidate.substring(dash + 1);
        if (_numericId.hasMatch(tail)) return tail;
      }
    }
    return '';
  }

  // ============================================================
  // 空筛选段清洗
  // ============================================================

  /// `/area//id` → 整段删除。
  static final RegExp _emptyPathSegment =
      RegExp(r'/[a-zA-Z][a-zA-Z0-9_]*//');

  /// `/year/.html` → `.html`。
  static final RegExp _emptyTailSegment =
      RegExp(r'/[a-zA-Z][a-zA-Z0-9_]*/(\.[a-zA-Z]{2,5}(?:\?|$))');

  /// 清掉模板空值留下的路径段与空 query 参数。
  ///
  /// MacCMS 路径式 URL 对空筛选段返回 404；jar 的行为是自动省略空段。
  static String cleanEmptySegments(String address) {
    var out = address;
    while (_emptyPathSegment.hasMatch(out)) {
      out = out.replaceAll(_emptyPathSegment, '/');
    }
    while (_emptyTailSegment.hasMatch(out)) {
      // 注意：Dart 的 replaceAll 不支持 `$1` 反向引用（Go 的
      // ReplaceAllString 支持），必须用 replaceAllMapped。
      out = out.replaceAllMapped(
        _emptyTailSegment,
        (m) => m.group(1) ?? '',
      );
    }

    final queryIndex = out.indexOf('?');
    if (queryIndex < 0) return out;

    final head = out.substring(0, queryIndex);
    final query = out.substring(queryIndex + 1);
    final kept = <String>[];
    var dropped = false;
    for (final pair in query.split('&')) {
      final eq = pair.indexOf('=');
      if (eq >= 0 &&
          pair.substring(eq + 1).isEmpty &&
          !pair.substring(0, eq).contains('{')) {
        dropped = true;
        continue;
      }
      if (pair.isNotEmpty) kept.add(pair);
    }
    if (!dropped) return out;
    if (kept.isEmpty) return head;
    return '$head?${kept.join('&')}';
  }
}
