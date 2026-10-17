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
    final re = RegExp(
        r'''hiker://(?:page|assets)/([A-Za-z0-9_./\u4e00-\u9fff-]+)''');
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

  // ============================================================
  // 源诊断（源管理页的标签）
  // ============================================================

  /// 诊断这个源**缺什么**（不联网、纯静态判断）。
  ///
  /// 和 [usable] 的区别：[usable] 只回答"能不能试着跑"，这里回答"为什么跑不动、
  /// 要补什么" —— 用户要求（2026-10-17）在源详情里直接标出
  /// 「缺 Apollo / 缺 lazy / 需填配置」，而不是点进去才看到一句看不懂的报错。
  ///
  /// [bundledAssets]：随包资源名（`assets/hiker/files/` 下的文件名，见
  /// `HikerBuiltin.assetNames()`）；命中的 `hiker://assets/x` 不算缺。
  /// [importedFiles]：用户文件区里的相对路径（`HikerFiles.list()`）；
  /// 命中的 `hiker://files/x` 不算缺。
  /// [config]：该源已保存的配置；[needsConfig] 且为空 ⇒ 标「需填配置」。
  List<HikerSourceDiagnosis> diagnose({
    Set<String> bundledAssets = const {},
    Set<String> importedFiles = const {},
    Map<String, dynamic>? config,
  }) {
    final out = <HikerSourceDiagnosis>[];
    final text = _allRuleText;
    final names = _moduleNames;
    final files = importedFiles.map(_normPath).toSet();

    // ① 连首页规则都没有
    if (findRule.isEmpty) {
      out.add(const HikerSourceDiagnosis(
        '无首页规则',
        '这条源没有 find_rule，导入的可能是残缺数据。',
        blocking: true,
      ));
    }

    // ② Apollo 规则包（社区分发，App 不自带，原版海阔也要用户自己导入）
    final apolloRef = RegExp(r'''\bApollo\b''').hasMatch(text);
    final apolloProvided = names.contains('Apollo') ||
        _hasFileUnder(files, 'apollo');
    if (apolloRef && !apolloProvided) {
      out.add(const HikerSourceDiagnosis(
        '缺 Apollo',
        '规则依赖 Apollo 规则包（不在 App 内）。去「海阔设置 → 文件管理」'
        '导入 Apollo 的 zip / 文件后再试。',
        blocking: true,
      ));
    }

    // ③ 官方内置页 lazy（漫画/短剧的「章节→图片」全靠它）
    final lazyRef = RegExp(r'''hiker://page/lazy'''
            r'''|(?:require|evalPrivateJS)\s*\(\s*['"]lazy['"]\s*\)''')
        .hasMatch(text);
    if (lazyRef && !names.contains('lazy')) {
      out.add(const HikerSourceDiagnosis(
        '缺 lazy',
        '规则引用了内置页 hiker://page/lazy，但源里没带这个模块、'
        '随包也没有 ⇒ 目录/看图那一步解不出来。',
        blocking: true,
      ));
    }

    // ④ 其它内置页 / assets：源里没有、随包也没有
    //    ⚠️ 模块名只收"正常字符"：实测源里夹着大段说明文字
    //    （`hiker://page/ruleHome</code>），宽字符集会把整段正文当成模块名。
    const placeholders = {'xxx', 'xxx.js', 'x', 'test', 'example'};
    final others = <String>[];
    for (final r in _builtinRefs) {
      final low = r.toLowerCase();
      if (low == 'apollo' || low == 'lazy') continue; // 上面已单独报
      if (placeholders.contains(low)) continue; // 教程里的占位名
      if (_providedBySource(r, names)) continue;
      if (_providedByAsset(r, bundledAssets)) continue;
      others.add(r);
    }
    if (others.isNotEmpty) {
      others.sort();
      out.add(HikerSourceDiagnosis(
        '缺内置页',
        '规则引用了 ${_preview(others.map((r) => 'hiker://page|assets/$r').toList())}，'
        '但源里没带、随包也没有 ⇒ 这些页面打不开。',
        blocking: true,
      ));
    }

    // ⑤ 文件区缺文件（`hiker://files/…`）
    //
    // ⚠️ 只认 **libs/ 与 rules/ 下的 .js 代码文件**：
    //    实测 `cache/…js`、`data/…js` 是源**运行时自己下载/生成**的
    //    （弹幕后端、音乐后端、豆瓣 Cookie），把它们标成"缺文件"
    //    会把本来能用的源吓成不可用；而 `libs/*.js` / `rules/**` 才是
    //    用户必须跟着源一起导入的规则包（115 个源里 7 个卡在这）。
    final missingFiles = <String>[];
    for (final f in _fileRefs) {
      final p = _normPath(f).toLowerCase();
      if (!p.endsWith('.js')) continue;
      final inRuleDir = p.startsWith('libs/') ||
          p.startsWith('rules/') ||
          p.contains('/libs/') ||
          p.contains('/rules/');
      if (!inRuleDir) continue;
      if (files.contains(_normPath(f))) continue;
      missingFiles.add(f);
    }
    if (missingFiles.isNotEmpty) {
      missingFiles.sort();
      out.add(HikerSourceDiagnosis(
        '缺文件',
        '规则要读 ${_preview(missingFiles.map((f) => 'hiker://files/$f').toList())}，'
        '文件区里没有 ⇒ 去「海阔设置 → 文件管理」导入对应规则包。',
        blocking: true,
      ));
    }

    // ⑥ 源配置
    if (needsConfig && (config == null || config.isEmpty)) {
      out.add(HikerSourceDiagnosis(
        '需填配置',
        '规则要读 ${configKeys.map((k) => 'config.$k').join('、')}，'
        '点右上角「源配置」填上对应值（如域名 / 口令）。',
      ));
    }

    // 阻塞项排前面，同级按标签字典序（输出稳定，测试好写）
    out.sort((a, b) {
      if (a.blocking != b.blocking) return a.blocking ? -1 : 1;
      return a.label.compareTo(b.label);
    });
    return out;
  }

  /// `hiker://files/…` 里**字面量**引用的相对路径
  Set<String> get _fileRefs {
    final out = <String>{};
    // 只收正常路径字符：源里常把说明文字跟地址写在同一行，
    // 宽字符集会把「；本规则不会…」这类正文一起吞进来
    final re = RegExp(r'''hiker://files/([A-Za-z0-9_./\u4e00-\u9fff-]+)''');
    for (final m in re.allMatches(_allRuleText)) {
      final p = (m.group(1) ?? '').trim();
      // 动态拼接（`hiker://files/' + config.dir`）会被正则截成半截，跳过
      if (p.isEmpty || p.endsWith('/') || p.endsWith('+') || p.contains(r'$')) {
        continue;
      }
      out.add(p);
    }
    return out;
  }

  /// 列表太长时只列前几个（源里动辄几十个文件，全塞进弹窗没法看）
  static String _preview(List<String> items, [int max = 4]) =>
      items.length <= max
          ? items.join('、')
          : '${items.take(max).join('、')} 等 ${items.length} 个';

  /// 引用的模块名是不是源自己在 `pages` 里带的
  static bool _providedBySource(String ref, Set<String> names) {
    if (names.contains(ref)) return true;
    final base = ref.split('/').last;
    if (base.isNotEmpty && names.contains(base)) return true;
    if (base.endsWith('.js') &&
        names.contains(base.substring(0, base.length - 3))) {
      return true;
    }
    return false;
  }

  /// 引用的模块名是不是随包资源（`assets/hiker/files/x.js`）
  static bool _providedByAsset(String ref, Set<String> assets) {
    if (assets.isEmpty) return false;
    final base = ref.split('/').last;
    return assets.contains(ref) || (base.isNotEmpty && assets.contains(base));
  }

  /// 文件区里有没有 `apollo` 相关文件（大小写、目录层级都认）
  static bool _hasFileUnder(Set<String> files, String keyword) {
    final k = keyword.toLowerCase();
    return files.any((f) => f.toLowerCase().contains(k));
  }

  static String _normPath(String p) =>
      p.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '').trim();

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

/// 一条「源诊断」结论 —— 在源管理页显示成标签，点开看 [detail]。
///
/// 标签只回答"缺什么"（缺 Apollo / 缺 lazy / 缺文件 / 需填配置 …）；
/// [blocking] = true 表示不补这个，源现在肯定跑不动。
class HikerSourceDiagnosis {
  /// 短标签（直接印在源卡片上）
  final String label;

  /// 人话说明 + 怎么补
  final String detail;

  /// 是否会直接导致源跑不起来
  final bool blocking;

  const HikerSourceDiagnosis(this.label, this.detail, {this.blocking = false});
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
