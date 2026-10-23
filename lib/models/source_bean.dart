/// 视频源站点配置 - 对应 Swift SourceBean
class SourceBean {
  /// 源唯一键
  final String key;
  /// 源显示名
  final String name;
  /// 源接口地址
  final String api;
  /// 搜索开关：0 关闭，1 开启
  final int searchable;
  /// 是否允许出现在首页分类：0 不可选，1 可选
  final int filterable;
  /// 快速搜索开关：0 关闭，1 开启
  final int quickSearch;
  /// 源声明的播放器类型
  final int playerType;
  /// 源协议类型：0 XML，1 JSON，3 JAR，4 Remote
  final int type;
  /// 扩展参数（remote 源常用）
  final String? ext;
  /// JAR 包 URL（Spider 源常用）
  final String? jar;
  /// 索引标记：1 表示索引服务（如豆瓣），点击视频应跳转搜索
  final int indexs;

  const SourceBean({
    this.key = '',
    this.name = '',
    this.api = '',
    this.searchable = 1,
    this.filterable = 1,
    this.quickSearch = 0,
    this.playerType = 0,
    this.type = 1,
    this.ext,
    this.jar,
    this.indexs = 0,
  });

  bool get isSearchable => searchable == 1;
  bool get isFilterable => filterable == 1;
  bool get isQuickSearchEnabled => quickSearch == 1;

  bool get isSupportedInSwift => type == 0 || type == 1 || type == 3 || type == 4;

  bool get isSpiderSource => type == 3;

  /// 脚本源（type=3）实际要加载/执行的脚本地址。
  ///
  /// TVBox 聚合配置里脚本源有两种写法：
  ///   · `api` 直接就是脚本 URL（如 `…/腾讯视频.py`）→ 用 api；
  ///   · `api` 是 drpy2 运行时、`ext` 才是站点脚本（如 `api=drpy2.min.js` +
  ///     `ext=官综.js`）→ 用 ext。
  String get scriptUrl {
    final e = (ext ?? '').trim();
    if (type == 3 && e.isNotEmpty) {
      final p = e.toLowerCase().split('?').first;
      if (e.startsWith('http://') ||
          e.startsWith('https://') ||
          p.endsWith('.js') ||
          p.endsWith('.py')) {
        return e;
      }
    }
    return api.trim();
  }

  /// 脚本地址是不是 Python（.py）→ 由 CPython 引擎执行
  bool get isPythonScriptSource {
    if (type != 3) return false;
    return scriptUrl.toLowerCase().split('?').first.endsWith('.py');
  }

  /// 脚本地址是不是 JS（.js）→ 由 Node/drpy2 引擎执行
  bool get isJsScriptSource {
    if (type != 3 || isPythonScriptSource) return false;
    final p = scriptUrl.toLowerCase().split('?').first;
    return p.endsWith('.js') || p.endsWith('.js.md5');
  }

  bool get isIndexSite => indexs == 1 || key == 'douban';

  bool get isConfigCenter => key == 'baseset';

  /// 源类型分类（供源切换 UI 分组展示）。
  ///
  /// 只依据本模型已有字段（[type] / [api] / [jar]）判定，判定不出的一律归
  /// [SourceKind.unknown]；项目里没有依据的概念（如"猫源""TVBox"）不会臆造。
  SourceKind get sourceKind {
    // type==4 → T4 远程接口（字段注释「4 Remote」；source_service 对 type==4
    // 走 filter/extend 分支请求）。
    if (type == 4) return SourceKind.t4;
    if (type == 3) {
      // type==3 → Spider（isSpiderSource，typeDescription='Spider'）。
      // 再按 jar/api/ext 后缀区分 Python / JS / Jar（api_config._isSpiderSourceUrl
      // 认 .js / .js.md5 / .jar / .jar.md5）。
      if ((jar ?? '').isNotEmpty) return SourceKind.jar;
      final probe = scriptUrl.toLowerCase();
      final path = Uri.tryParse(probe)?.path ?? probe;
      if (path.endsWith('.py')) return SourceKind.python;
      if (path.endsWith('.jar') || path.endsWith('.jar.md5')) {
        return SourceKind.jar;
      }
      // TVBox 约定：api 形如 csp_xxx 的自定义 spider 由 jar 提供。
      if (api.toLowerCase().startsWith('csp_')) return SourceKind.jar;
      return SourceKind.js;
    }
    // type==0（XML）/ 1（JSON）→ 苹果 CMS（macCMS）点播接口。
    if (type == 0 || type == 1) return SourceKind.cms;
    return SourceKind.unknown;
  }

  /// 类型描述
  String get typeDescription {
    switch (type) {
      case 0:
        return 'XML';
      case 1:
        return 'JSON';
      case 3:
        return 'Spider';
      case 4:
        return 'Remote';
      default:
        return '未知';
    }
  }

  /// api 字段是否为有效 HTTP URL
  /// api 是否可直接请求。
  ///
  /// 除 http(s) 外还放行 `file://`：那是「本地源」—— 用户导入一份
  /// MacCMS 格式的 JSON（含 class/list），离线也能浏览/搜索。
  bool get isHttpApi =>
      api.startsWith('http://') ||
      api.startsWith('https://') ||
      api.startsWith('file://');

  /// 本地 JSON 源（离线）
  bool get isLocalSource => api.startsWith('file://');

  factory SourceBean.fromJson(Map<String, dynamic> json) {
    return SourceBean(
      key: json['key'] as String? ?? '',
      name: json['name'] as String? ?? '',
      api: json['api'] as String? ?? '',
      searchable: _parseInt(json['searchable']),
      filterable: _parseInt(json['filterable']),
      quickSearch: _parseInt(json['quickSearch']),
      playerType: _parseInt(json['playerType']),
      type: _parseInt(json['type']),
      ext: _parseExt(json['ext']),
      jar: json['jar'] as String?,
      indexs: _parseInt(json['indexs']),
    );
  }

  static int _parseInt(dynamic value) {
    if (value == null) return 1;
    if (value is int) return value;
    if (value is String) return int.tryParse(value) ?? 1;
    return 1;
  }

  static String? _parseExt(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is Map) return value.toString();
    return value.toString();
  }
}

/// 源的「类型分类」——仅用于在源切换 UI 里按类型分组展示。
///
/// 归类只依据 [SourceBean] 已有字段（见 [SourceBean.sourceKind]），
/// 不影响源的加载、选中与解析行为。
enum SourceKind {
  /// 苹果 CMS（macCMS）点播接口：type 0（XML）/ 1（JSON）
  cms,

  /// 远程接口源：type 4
  t4,

  /// T3 Spider 源：type 3，脚本为 .js
  js,

  /// T3 Spider 源：type 3，脚本为 .py（CPython 引擎执行）
  python,

  /// T3 Spider 源：type 3，由 .jar 提供
  jar,

  /// 无法判定
  unknown;

  /// 分组标题用的中文名
  String get label {
    switch (this) {
      case SourceKind.cms:
        return 'CMS';
      case SourceKind.t4:
        return 'T4';
      case SourceKind.js:
        return 'JS';
      case SourceKind.python:
        return 'Python';
      case SourceKind.jar:
        return 'Jar';
      case SourceKind.unknown:
        return '未分类';
    }
  }
}
