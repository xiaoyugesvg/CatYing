// lib/webhome/web_home_source.dart
//
// 「网页」模块的**一个网页源**。
//
// 用户 2026-10-14：网页从"只能配一个地址"升级成一列可**内置 / 导入 / 切换 /
// 排序**的网页。三种形态：
//   · url   —— 远端地址（默认网页、导入的订阅链接…）
//   · asset —— 随包内置的 HTML（assets/webhome/*.html）
//   · file  —— 用户从手机导入、已复制进 App 目录的 HTML

import 'package:flutter/foundation.dart';

/// 网页源的来源形态。
enum WebHomeSourceKind {
  url('链接'),
  asset('内置'),
  file('本地');

  const WebHomeSourceKind(this.label);

  /// 列表里给用户看的小标签。
  final String label;
}

/// 一个网页源。
@immutable
class WebHomeSource {
  const WebHomeSource({
    required this.id,
    required this.name,
    required this.kind,
    required this.value,
    this.builtin = false,
  });

  /// 稳定 id（排序/选中都用它，不用下标 —— 换序后下标会变）。
  final String id;

  /// 显示名（用户看到的就是它，中文）。
  final String name;

  final WebHomeSourceKind kind;

  /// `url` / asset 路径 / 本地文件绝对路径。
  final String value;

  /// 是否随包内置（内置的删掉还能用「恢复内置」找回来）。
  final bool builtin;

  WebHomeSource copyWith({String? name, WebHomeSourceKind? kind, String? value}) =>
      WebHomeSource(
        id: id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        value: value ?? this.value,
        builtin: builtin,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'value': value,
        'builtin': builtin,
      };

  /// 容错解析：缺 name/value 的直接丢弃（宁少一条，也不要一条点了没反应的）。
  ///
  /// 兼容几种常见写法（订阅文件里别人常写成 `url`/`path`/`html`）：
  /// `{name, value|url, kind?}`。
  static WebHomeSource? fromJson(Map<String, dynamic> j) {
    final name = (j['name'] ?? j['title'] ?? '').toString().trim();
    final value = (j['value'] ?? j['url'] ?? j['path'] ?? '').toString().trim();
    if (name.isEmpty || value.isEmpty) return null;
    var kind = WebHomeSourceKind.url;
    if (j['kind'] != null) {
      for (final k in WebHomeSourceKind.values) {
        if (k.name == '${j['kind']}') kind = k;
      }
    } else if (value.startsWith('assets/')) {
      kind = WebHomeSourceKind.asset;
    } else if (!value.startsWith('http://') && !value.startsWith('https://')) {
      kind = WebHomeSourceKind.file;
    }
    final id = (j['id'] ?? '').toString().trim();
    return WebHomeSource(
      id: id.isEmpty ? 'ws_${value.hashCode.abs()}' : id,
      name: name,
      kind: kind,
      value: value,
      builtin: j['builtin'] == true,
    );
  }
}

/// 内置网页源（首次启动播种 / 「恢复内置」用）。
///
/// 🔴 默认网页 = `https://tmd.920410.xyz/`（用户 2026-10-14 指定）。
/// 另外 4 个是用户给的 HTML 应用，**名称就是中文名**（用户要求）。
///
/// ⚠️ 资源文件名故意用 ASCII（`kulao_music.html`），显示名才是中文 ——
/// 非 ASCII 的资源路径在打包/读取环节更容易踩坑，而显示名来自这个模型，
/// 两者不需要一致。
const List<WebHomeSource> kBuiltinWebHomeSources = [
  WebHomeSource(
    id: 'builtin_default',
    name: '默认网页',
    kind: WebHomeSourceKind.url,
    value: 'https://tmd.920410.xyz/',
    builtin: true,
  ),
  WebHomeSource(
    id: 'builtin_kulao_music',
    name: '裤佬音乐',
    kind: WebHomeSourceKind.asset,
    value: 'assets/webhome/kulao_music.html',
    builtin: true,
  ),
  WebHomeSource(
    id: 'builtin_waibibabu',
    name: '歪比巴卜',
    kind: WebHomeSourceKind.asset,
    value: 'assets/webhome/waibibabu.html',
    builtin: true,
  ),
  WebHomeSource(
    id: 'builtin_manwa_anime',
    name: '漫蛙动漫',
    kind: WebHomeSourceKind.asset,
    value: 'assets/webhome/manwa_anime.html',
    builtin: true,
  ),
  WebHomeSource(
    id: 'builtin_zhuigeng',
    name: '追更助手',
    kind: WebHomeSourceKind.asset,
    value: 'assets/webhome/zhuigeng.html',
    builtin: true,
  ),
];

/// 网页源列表的**变更通知**（页面/管理页监听它重建）。
///
/// 用一个自增计数而不是 `ValueNotifier<List>`：列表就地排序时内容可变，
/// 直接比 List 会漏掉"元素没变但顺序变了"的情况。
final ValueNotifier<int> webHomeSourcesTick = ValueNotifier<int>(0);

void bumpWebHomeSources() => webHomeSourcesTick.value++;
