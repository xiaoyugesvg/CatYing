import 'dart:convert';

/// 「海阔」小程序源（hiker / hipy 格式的一条）。
///
/// ── 为什么保留 [raw] ────────────────────────────────────────────────
/// 海阔导出的 JSON 字段很多（`find_rule` / `searchFind` / `pages` / `preRule` /
/// `col_type` …），而我们把**整条原样转发**给 Node 侧的 hiker 引擎
/// （`POST /hiker/run`）去求值。所以这里不做"抽字段再拼回去"的重建，
/// 而是**持有原始 Map**，其余字段只做只读便利访问 —— 避免漏字段导致规则失效。
class HikerSource {
  HikerSource(Map<String, dynamic> raw) : raw = Map<String, dynamic>.from(raw);

  /// 原始条目（转发给 Node 引擎时直接用）
  final Map<String, dynamic> raw;

  String _s(String k) => (raw[k] ?? '').toString().trim();

  /// 稳定 id（导入去重用）。海阔条目没有 id，用 `标题+作者` 做自然键。
  String get id => '${_s('title')}\u0001${_s('author')}';

  String get title => _s('title');
  String get author => _s('author');
  int get version => (raw['version'] as num?)?.toInt() ?? 0;
  String get group => _s('group');
  String get url => _s('url');
  String get colType => _s('col_type');
  String get findRule => _s('find_rule');
  String get searchFind => _s('searchFind');
  String get searchUrl => _s('search_url');
  String get detailColType => _s('detail_col_type');
  String get detailFindRule => _s('detail_find_rule');
  String get ua => _s('ua');
  String get preRule => _s('preRule');
  String get className => _s('class_name');
  String get classUrl => _s('class_url');
  String get type => _s('type');

  /// 源自带的**内联页面模块**（`$.require('xxx')` 用），海阔导出里是 `pages` 字符串
  List<Map<String, dynamic>> get pages {
    final p = raw['pages'];
    if (p is List) {
      return p.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    }
    if (p is String && p.trim().isNotEmpty) {
      try {
        final d = jsonDecode(p);
        if (d is List) {
          return d.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        }
      } catch (_) {/* 坏数据当没有 */}
    }
    return const [];
  }

  /// 是否**真的**依赖海阔内置页面模块（无源码 ⇒ 跑不了）。
  ///
  /// ⚠️ 关键纠正（实测用户那份 115 个源）：引用 `hiker://page|assets/*` 的 70 个源里，
  ///   **64 个（91%）的目标模块就在源自己的 `pages` 里** —— 那只是 hiker 的写法，
  ///   不是"内置模块"。所以这里不再"看到 hiker:// 就判死"，而是**逐个查**：
  ///   引用的模块名在 `pages` 里找得到就不算内置（引擎侧同样会归一化前缀/basename/.js）。
  bool get needsBuiltinModule {
    final refs = _builtinRefs;
    if (refs.isEmpty) return false;
    final names = _moduleNames;
    for (final r in refs) {
      if (names.contains(r)) continue;
      final base = r.split('/').last;
      if (names.contains(base)) continue;
      if (base.endsWith('.js') && names.contains(base.substring(0, base.length - 3))) {
        continue;
      }
      return true; // 有一个引用确实找不到 ⇒ 依赖内置模块
    }
    return false;
  }

  /// `pages` 里所有可作为模块名的写法（name / path / basename / 去 .js）
  Set<String> get _moduleNames {
    final names = <String>{};
    for (final p in pages) {
      for (final raw in [p['name'], p['path']]) {
        if (raw == null) continue;
        final s = raw.toString().trim();
        if (s.isEmpty) continue;
        names.add(s);
        final base = s.split('/').last;
        if (base.isNotEmpty) {
          names.add(base);
          if (base.endsWith('.js')) {
            names.add(base.substring(0, base.length - 3));
          }
        }
      }
    }
    return names;
  }

  /// 规则里引用的 `hiker://page|assets/xxx` 目标（已去掉 `#`/`?` 尾巴）
  Set<String> get _builtinRefs {
    final out = <String>{};
    final re = RegExp(r'''hiker://(?:page|assets)/([^\s'"#?;,)]+)''');
    for (final m in re.allMatches(_allRuleText)) {
      final k = (m.group(1) ?? '').split(RegExp(r'[#?]')).first.trim();
      if (k.isNotEmpty) out.add(k);
    }
    return out;
  }

  /// 是否用到**当前确实给不了**的宿主能力。
  ///
  /// 随着能力补齐，这里已经从"一大片"缩到几乎为空：
  ///   ✅ `fetchCodeByWebView`（App 侧真 WebView）、`$('').lazyRule(fn)`、
  ///      `$(url).rule(fn,...)`、`config.xxx`、URL 的 `.js:` 动态域名规则、
  ///      **`pdfa` / `pdfh` / `pd`**（CatVod 血统的老三样 DOM API）、
  ///      `hiker://page|assets/X` 当资源抓（`hikerResource`）。
  ///   ❌ 仍未提供：事件/定时器（`addListener`/`setInterval` 做**安全占位**，不报错
  ///      但不会触发）、宿主文件系统（`hiker://files/...`）、Java 桥（`java.*`）。
  ///      这些都不必**提前判死**（很多源只用它们做清理/可选增强），让规则跑起来更好。
  bool get needsHostApi => false;

  /// 规则是否读取 `config.xxx`（需要在「源配置」里填值）
  bool get needsConfig => _configKeys.isNotEmpty;

  /// 规则里用到的 `config.xxx` 键（给源配置编辑器做提示）
  List<String> get configKeys => _configKeys;

  String get _allRuleText => [
        url,
        findRule,
        searchFind,
        searchUrl,
        detailFindRule,
        preRule,
        for (final p in pages) (p['rule'] ?? '').toString(),
      ].join('\n');

  List<String> get _configKeys {
    final out = <String>{};
    final re = RegExp(r'config\.([A-Za-z_]\w*)');
    for (final m in re.allMatches(_allRuleText)) {
      final k = m.group(1);
      if (k != null && k.isNotEmpty) out.add(k);
    }
    return out.toList()..sort();
  }

  /// 能否用（Phase 1 判定）：有首页规则、不依赖内置模块、不依赖宿主能力
  bool get usable => findRule.isNotEmpty && !needsBuiltinModule && !needsHostApi;

  /// 不可用原因（界面直接展示）
  String get unusableReason {
    if (findRule.isEmpty) return '没有 find_rule';
    if (needsBuiltinModule) return '依赖海阔内置模块（hiker://page/*），Phase 1 暂不支持';
    if (needsHostApi) return '依赖海阔宿主能力（pdfa 播放地址解析），暂不支持';
    return '';
  }

  /// 分组名（海里导出里 group 可能是 `#` / `①推荐` 这种）
  String get groupLabel {
    final g = group;
    if (g.isEmpty || g == '#') return '未分组';
    return g;
  }

  /// 转发给 Node 引擎的结构（保证 `pages` 是数组）
  Map<String, dynamic> toEngineJson() {
    final m = Map<String, dynamic>.from(raw);
    m['pages'] = pages;
    return m;
  }

  // ============================================================
  // 导入
  // ============================================================

  /// 解析海阔导出的 JSON。
  ///
  /// 兼容三种形态：
  ///   · 顶层**数组**（海阔「导出全部」就是这个，用户那份 115 个源就是）
  ///   · `{"data":[...]}` 包裹
  ///   · 单个对象（只导出一个源）
  static List<HikerSource> parseList(String text) {
    final t = text.trim();
    if (t.isEmpty) return const [];
    final dynamic decoded = jsonDecode(t);
    List<dynamic> list;
    if (decoded is List) {
      list = decoded;
    } else if (decoded is Map && decoded['data'] is List) {
      list = decoded['data'] as List;
    } else if (decoded is Map) {
      list = [decoded];
    } else {
      list = const [];
    }
    final out = <HikerSource>[];
    final seen = <String>{};
    for (final e in list) {
      if (e is! Map) continue;
      final m = Map<String, dynamic>.from(e);
      final title = (m['title'] ?? m['name'] ?? '').toString().trim();
      if (title.isEmpty) continue;
      final s = HikerSource(m);
      if (seen.add(s.id)) out.add(s);
    }
    return out;
  }
}

/// 规则产出的一条列表项（节点引擎已归一化）
class HikerItem {
  final String title;
  final String url;
  final String pic;
  final String desc;
  final String colType;

  const HikerItem({
    required this.title,
    required this.url,
    this.pic = '',
    this.desc = '',
    this.colType = '',
  });

  factory HikerItem.fromJson(Map<String, dynamic> j) => HikerItem(
        title: (j['title'] ?? '').toString(),
        url: (j['url'] ?? '').toString(),
        pic: (j['pic'] ?? '').toString(),
        desc: (j['desc'] ?? '').toString(),
        colType: (j['colType'] ?? j['col_type'] ?? '').toString(),
      );
}
