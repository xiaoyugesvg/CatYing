import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 一个已导入的自定义字体。
class ReaderFont {
  const ReaderFont({
    required this.id,
    required this.name,
    required this.path,
    required this.family,
  });

  final String id;

  /// 界面上显示的名字（一般取文件名）
  final String name;

  /// 字体文件落盘路径
  final String path;

  /// 注册到 Flutter 引擎的 family（全局唯一，`ReaderFont_xx`）
  final String family;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'path': path,
    'family': family,
  };

  static ReaderFont? fromJson(Map<String, dynamic> j) {
    final id = (j['id'] as String?) ?? '';
    final path = (j['path'] as String?) ?? '';
    final family = (j['family'] as String?) ?? '';
    if (id.isEmpty || path.isEmpty || family.isEmpty) return null;
    return ReaderFont(
      id: id,
      name: (j['name'] as String?) ?? '自定义字体',
      path: path,
      family: family,
    );
  }
}

/// 「字体库」里的一个可下载字体。
class CatalogFont {
  const CatalogFont({
    required this.id,
    required this.name,
    required this.desc,
    required this.ext,
    required this.sizeMb,
    required this.urls,
    required this.family,
  });

  final String id;
  final String name;
  final String desc;

  /// 扩展名（otf / ttf）—— 决定落盘文件名
  final String ext;

  /// 大致体积（MB），UI 上给用户看
  final double sizeMb;

  /// 下载地址，按顺序试（第一个是 jsDelivr，后面是 GitHub 反代/原址）
  final List<String> urls;

  /// 注册到引擎的 family（必须全局唯一）
  final String family;
}

/// 自定义字体：导入（文件 / 字节）、落盘、注册到引擎、列表持久化。
///
/// 为什么用 `FontLoader`：Flutter 只能渲染**已注册到引擎**的 family；运行期
/// 导入的字体必须先 `FontLoader.load()` 一次，`TextStyle(fontFamily: …)` 才生效。
/// 注册是进程级的 —— 同一 family 只需注册一次（这里用 [_registered] 去重）。
class ReaderFontService {
  ReaderFontService._();

  static final ReaderFontService instance = ReaderFontService._();

  static const _kFonts = 'reading.fonts';

  /// iOS 系统自带字体（**不用下载**，直接按 family 名引用）。
  ///
  /// 用户 2026-10-25：「字体列表里的『系统』分组（华文隶书、黑体、苹方…）」——
  /// Flutter 拿不到系统字体的**枚举**，但拿得到**名字**：只要 family 名对，
  /// iOS 的 CoreText 就能解析出来。所以这里写死一批 iOS 中文常用字体，
  /// 选不中也只是回落默认字体，不会崩。
  static const List<ReaderFont> systemFonts = [
    ReaderFont(id: 'system:PingFang SC', name: '苹方', path: '', family: 'PingFang SC'),
    ReaderFont(id: 'system:Heiti SC', name: '黑体', path: '', family: 'Heiti SC'),
    ReaderFont(id: 'system:Songti SC', name: '宋体', path: '', family: 'Songti SC'),
    ReaderFont(id: 'system:Kaiti SC', name: '楷体', path: '', family: 'Kaiti SC'),
    ReaderFont(id: 'system:Fangsong SC', name: '仿宋', path: '', family: 'Fangsong SC'),
    ReaderFont(id: 'system:Yuanti SC', name: '圆体', path: '', family: 'Yuanti SC'),
    ReaderFont(id: 'system:Liti SC', name: '隶书', path: '', family: 'Liti SC'),
    ReaderFont(id: 'system:Xingkai SC', name: '行楷', path: '', family: 'Xingkai SC'),
    ReaderFont(id: 'system:Weibei SC', name: '魏碑', path: '', family: 'Weibei SC'),
    ReaderFont(id: 'system:Wawati SC', name: '娃娃体', path: '', family: 'Wawati SC'),
    ReaderFont(id: 'system:Hannotate SC', name: '手札体', path: '', family: 'Hannotate SC'),
    ReaderFont(id: 'system:Hanzipen SC', name: '翩翩体', path: '', family: 'Hanzipen SC'),
  ];

  /// 可下载字体（「字体库」里点一下就装）
  static const List<CatalogFont> catalog = [
    CatalogFont(
      id: 'builtin:serif',
      name: '思源宋体',
      desc: '微信读书样式默认 · 常规',
      ext: 'otf',
      sizeMb: 11.1,
      urls: [
        'https://cdn.jsdelivr.net/gh/notofonts/noto-cjk@main/Serif/SubsetOTF/SC/NotoSerifSC-Regular.otf',
        'https://gh-proxy.com/https://raw.githubusercontent.com/notofonts/noto-cjk/main/Serif/SubsetOTF/SC/NotoSerifSC-Regular.otf',
        'https://raw.githubusercontent.com/notofonts/noto-cjk/main/Serif/SubsetOTF/SC/NotoSerifSC-Regular.otf',
      ],
      family: 'NotoSerifSC',
    ),
    CatalogFont(
      id: 'builtin:kai',
      name: '霞鹜文楷',
      desc: '泼墨山水样式默认 · 常规',
      ext: 'ttf',
      sizeMb: 13.3,
      urls: [
        'https://cdn.jsdelivr.net/gh/lxgw/LxgwWenKai-Lite@v1.520/fonts/TTF/LXGWWenKaiLite-Regular.ttf',
        'https://gh-proxy.com/https://github.com/lxgw/LxgwWenKai-Lite/releases/download/v1.520/LXGWWenKaiLite-Regular.ttf',
        'https://github.com/lxgw/LxgwWenKai-Lite/releases/download/v1.520/LXGWWenKaiLite-Regular.ttf',
      ],
      family: 'LXGWWenKai',
    ),
    CatalogFont(
      id: 'cat:serif-bold',
      name: '思源宋体 粗体',
      desc: '标题/强调用',
      ext: 'otf',
      sizeMb: 11.2,
      family: 'CatFontSerifBold',
      urls: [
        'https://cdn.jsdelivr.net/gh/notofonts/noto-cjk@main/Serif/SubsetOTF/SC/NotoSerifSC-Bold.otf',
        'https://gh-proxy.com/https://raw.githubusercontent.com/notofonts/noto-cjk/main/Serif/SubsetOTF/SC/NotoSerifSC-Bold.otf',
      ],
    ),
    CatalogFont(
      id: 'cat:serif-light',
      name: '思源宋体 细体',
      desc: '轻阅读用，笔画细',
      ext: 'otf',
      sizeMb: 11.0,
      family: 'CatFontSerifLight',
      urls: [
        'https://cdn.jsdelivr.net/gh/notofonts/noto-cjk@main/Serif/SubsetOTF/SC/NotoSerifSC-Light.otf',
        'https://gh-proxy.com/https://raw.githubusercontent.com/notofonts/noto-cjk/main/Serif/SubsetOTF/SC/NotoSerifSC-Light.otf',
      ],
    ),
    CatalogFont(
      id: 'cat:sans',
      name: '思源黑体',
      desc: '现代无衬线 · 常规',
      ext: 'otf',
      sizeMb: 10.5,
      family: 'CatFontSans',
      urls: [
        'https://cdn.jsdelivr.net/gh/notofonts/noto-cjk@main/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf',
        'https://gh-proxy.com/https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/SubsetOTF/SC/NotoSansSC-Regular.otf',
      ],
    ),
    CatalogFont(
      id: 'cat:sans-bold',
      name: '思源黑体 粗体',
      desc: '现代无衬线 · 加粗',
      ext: 'otf',
      sizeMb: 10.6,
      family: 'CatFontSansBold',
      urls: [
        'https://cdn.jsdelivr.net/gh/notofonts/noto-cjk@main/Sans/SubsetOTF/SC/NotoSansSC-Bold.otf',
        'https://gh-proxy.com/https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/SubsetOTF/SC/NotoSansSC-Bold.otf',
      ],
    ),
    CatalogFont(
      id: 'cat:sans-light',
      name: '思源黑体 细体',
      desc: '现代无衬线 · 轻',
      ext: 'otf',
      sizeMb: 10.4,
      family: 'CatFontSansLight',
      urls: [
        'https://cdn.jsdelivr.net/gh/notofonts/noto-cjk@main/Sans/SubsetOTF/SC/NotoSansSC-Light.otf',
        'https://gh-proxy.com/https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/SubsetOTF/SC/NotoSansSC-Light.otf',
      ],
    ),
    // ── 霞鹜系列（lxgw，OFL）─────────────────────────────
    //   release 资产只有 GitHub 有，jsDelivr 不代理 release ⇒ 用 gh-proxy 兜底。
    CatalogFont(
      id: 'cat:neo-xihei',
      name: '霞鹜新晰黑',
      desc: '霞鹜系列 · 小体积黑体',
      ext: 'ttf',
      sizeMb: 7.1,
      family: 'CatFontNeoXiHei',
      urls: [
        'https://gh-proxy.com/https://github.com/lxgw/LxgwNeoXiHei/releases/download/v1.308/LXGWNeoXiHei.ttf',
        'https://github.com/lxgw/LxgwNeoXiHei/releases/download/v1.308/LXGWNeoXiHei.ttf',
      ],
    ),
    CatalogFont(
      id: 'cat:neo-zhisong',
      name: '霞鹜新致宋',
      desc: '霞鹜系列 · 宋体',
      ext: 'ttf',
      sizeMb: 10.0,
      family: 'CatFontNeoZhiSong',
      urls: [
        'https://gh-proxy.com/https://github.com/lxgw/LxgwNeoZhiSong/releases/download/v1.070/LXGWNeoZhiSong.ttf',
        'https://github.com/lxgw/LxgwNeoZhiSong/releases/download/v1.070/LXGWNeoZhiSong.ttf',
      ],
    ),
    CatalogFont(
      id: 'cat:wenkai-full',
      name: '霞鹜文楷（完整字库）',
      desc: '霞鹜系列 · 字更全，体积大',
      ext: 'ttf',
      sizeMb: 24.7,
      family: 'CatFontWenKaiFull',
      urls: [
        'https://gh-proxy.com/https://github.com/lxgw/LxgwWenKai/releases/download/v1.530/LXGWWenKai-Regular.ttf',
        'https://github.com/lxgw/LxgwWenKai/releases/download/v1.530/LXGWWenKai-Regular.ttf',
      ],
    ),
    CatalogFont(
      id: 'cat:wenkai-mono',
      name: '霞鹜文楷 Mono',
      desc: '霞鹜系列 · 等宽，中英混排整齐',
      ext: 'ttf',
      sizeMb: 24.8,
      family: 'CatFontWenKaiMono',
      urls: [
        'https://gh-proxy.com/https://github.com/lxgw/LxgwWenKai/releases/download/v1.530/LXGWWenKaiMono-Regular.ttf',
        'https://github.com/lxgw/LxgwWenKai/releases/download/v1.530/LXGWWenKaiMono-Regular.ttf',
      ],
    ),
  ];

  static CatalogFont? catalogById(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final c in catalog) {
      if (c.id == id) return c;
    }
    return null;
  }

  final List<ReaderFont> fonts = [];
  final Set<String> _registered = {};
  final Set<String> _downloading = {};
  bool _loaded = false;
  String? _fontDir;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final d = Directory('${dir.path}/reader_fonts');
      if (!d.existsSync()) d.createSync(recursive: true);
      _fontDir = d.path;
      // 之前下载过的字体（内置 + 字体库）：启动即注册，套样式时不用等
      for (final c in catalog) {
        final p = fontPath(c.id);
        if (p == null || !File(p).existsSync()) continue;
        await _ensureRegistered(
          ReaderFont(id: c.id, name: c.name, path: p, family: c.family),
        );
      }
    } catch (_) {}
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_kFonts);
      if (raw == null || raw.isEmpty) return;
      final list = jsonDecode(raw) as List;
      for (final e in list) {
        if (e is! Map) continue;
        final f = ReaderFont.fromJson(Map<String, dynamic>.from(e));
        if (f == null) continue;
        // 文件被系统清掉了就跳过（不删记录，避免"重装后自动消失"）
        if (!File(f.path).existsSync()) continue;
        fonts.add(f);
      }
    } catch (_) {}
  }

  /// 取某个字体 id 对应的 family（会确保已注册）；不存在/加载失败返回 null
  Future<String?> familyOf(String? id) async {
    if (id == null || id.isEmpty) return null;
    // 系统字体：只要名字，iOS 的 CoreText 自己解析
    if (id.startsWith('system:')) return id.substring(7);
    // 内置 / 字体库：已装就直接用，没装就下载
    final cat = catalogById(id);
    if (cat != null) {
      if (_registered.contains(cat.family)) return cat.family;
      return install(id);
    }
    await load();
    for (final e in fonts) {
      if (e.id != id) continue;
      if (!File(e.path).existsSync()) return null;
      await _ensureRegistered(e);
      return _registered.contains(e.family) ? e.family : null;
    }
    return null;
  }

  /// 只查**已注册**的字体（同步）：套用样式时先用它，省一次重排
  String? familyOfSync(String? id) {
    if (id == null || id.isEmpty) return null;
    if (id.startsWith('system:')) return id.substring(7);
    final cat = catalogById(id);
    if (cat != null) {
      return _registered.contains(cat.family) ? cat.family : null;
    }
    for (final f in fonts) {
      if (f.id != id) continue;
      return _registered.contains(f.family) ? f.family : null;
    }
    return null;
  }

  /// 字体文件落盘路径（系统字体没有文件 ⇒ null）
  String? fontPath(String id) {
    final dir = _fontDir;
    if (dir == null) return null;
    final cat = catalogById(id);
    if (cat == null) return null;
    final safe = cat.id.replaceAll(':', '_');
    return '$dir/$safe.${cat.ext}';
  }

  /// 是否已装（系统字体恒为 true，可下载字体看文件在不在）
  bool isInstalled(String id) {
    if (id.startsWith('system:')) return true;
    final p = fontPath(id);
    return p != null && File(p).existsSync();
  }

  /// 安装字体库里的某个字体（下载 → 注册 → 落盘记录）。
  /// 已装则直接注册并返回 family；失败返回 null。
  Future<String?> install(String id) async {
    await load();
    final cat = catalogById(id);
    if (cat == null) return null;
    if (_registered.contains(cat.family)) return cat.family;
    final path = fontPath(id);
    if (path == null) return null;
    final file = File(path);
    if (!file.existsSync()) {
      // 同一个字体同时只下一次（阅读器可能重复触发）
      if (_downloading.contains(id)) return null;
      _downloading.add(id);
      try {
        for (final u in cat.urls) {
          try {
            final bytes = await _fetchBytes(u);
            if (bytes.isEmpty || bytes.length < 100000) continue;
            if (!file.parent.existsSync()) {
              file.parent.createSync(recursive: true);
            }
            await file.writeAsBytes(bytes, flush: true);
            break;
          } catch (_) {
            // 换下一个源
          }
        }
      } finally {
        _downloading.remove(id);
      }
      if (!file.existsSync()) return null;
    }
    final f = ReaderFont(id: id, name: cat.name, path: path, family: cat.family);
    await _ensureRegistered(f);
    if (!_registered.contains(cat.family)) return null;
    // 记进「已装列表」，重进阅读器也还在
    if (!fonts.any((e) => e.id == id)) {
      fonts.add(f);
      await _persist();
    }
    return cat.family;
  }

  /// 拉字体字节（跟随 302；给字体站用的极简 HTTP，不走业务层的代理/重试）
  Future<List<int>> _fetchBytes(String url) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0');
      final res = await req.close().timeout(const Duration(seconds: 120));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw 'HTTP ${res.statusCode}';
      }
      final bytes = await res.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      return bytes;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _ensureRegistered(ReaderFont f) async {
    if (_registered.contains(f.family)) return;
    try {
      final bytes = await File(f.path).readAsBytes();
      final loader = FontLoader(f.family)
        ..addFont(Future.value(ByteData.sublistView(Uint8List.fromList(bytes))));
      await loader.load();
      _registered.add(f.family);
    } catch (_) {}
  }

  /// 导入字体字节（ttf / otf / ttc）。成功返回 [ReaderFont]，失败返回 null。
  Future<ReaderFont?> importBytes(
    List<int> bytes, {
    String? name,
    String? ext,
  }) async {
    if (bytes.isEmpty) return null;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final d = Directory('${dir.path}/reader_fonts');
      if (!d.existsSync()) d.createSync(recursive: true);
      final id = 'font:${DateTime.now().millisecondsSinceEpoch}';
      final safeExt = (ext == null || ext.trim().isEmpty)
          ? 'ttf'
          : ext.trim().toLowerCase();
      final path = '${d.path}/$id.$safeExt';
      await File(path).writeAsBytes(bytes, flush: true);
      final family = 'ReaderFont_${id.replaceAll(':', '_')}';
      final f = ReaderFont(
        id: id,
        name: (name == null || name.trim().isEmpty) ? '自定义字体' : name.trim(),
        path: path,
        family: family,
      );
      await _ensureRegistered(f);
      if (!_registered.contains(f.family)) {
        // 引擎放不进去（不是有效字体）⇒ 删掉文件，不污染列表
        try {
          File(path).deleteSync();
        } catch (_) {}
        return null;
      }
      fonts.add(f);
      await _persist();
      return f;
    } catch (_) {
      return null;
    }
  }

  /// 从文件路径导入
  Future<ReaderFont?> importFile(String path, {String? name}) async {
    try {
      final bytes = await File(path).readAsBytes();
      final ext = path.contains('.') ? path.split('.').last : 'ttf';
      return await importBytes(bytes, name: name, ext: ext);
    } catch (_) {
      return null;
    }
  }

  Future<void> remove(ReaderFont f) async {
    fonts.removeWhere((e) => e.id == f.id);
    _registered.remove(f.family);
    try {
      final file = File(f.path);
      if (file.existsSync()) file.deleteSync();
    } catch (_) {}
    await _persist();
  }

  Future<void> _persist() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _kFonts,
        jsonEncode([for (final f in fonts) f.toJson()]),
      );
    } catch (_) {}
  }
}
