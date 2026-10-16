import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../reading/source/global_proxy.dart';
import 'app_log.dart';

/// 网页**去广告**（元素隐藏）—— 规则、持久化、注入脚本、选元素。
///
/// ── 参考实现与我们的能做/不能做 ────────────────────────────────
/// 参考 <https://github.com/limbopro/Adblock4limbo>：它的规则本身就是
/// **CSS 选择器**（「1.8 万+通用去广告选择器」+ 按域名加载站点专属选择器），
/// 由一段 JS 注入到网页里隐藏元素；需要 MITM/分流的才是网络层那半。
/// 我们用的是 `webview_flutter`（**没有** shouldInterceptRequest 之类的能力），
/// 所以只做注入这一半 —— 与参考实现的**选择器部分**语义一致。
///
/// ── 与 [AdFilterService] 的分工（别混）────────────────────────
///   · `AdFilterService`：**播放地址层** —— host 黑名单 + 正则拦截/重写，
///     数据来自订阅配置里的 `ads` / `rules`；
///   · 本服务：**页面层** —— 把广告元素的 CSS 选择器注入网页隐藏掉，
///     规则来自「设置 → 广告管理」或网页里的悬浮按钮手选。
///
/// ── 规则语法（兼容 uBlock / AdGuard 的「元素隐藏」写法）────────
///   `##.ad-box`            所有网站隐藏 `.ad-box`
///   `example.com##.ad-box` 只在 example.com（含子域）隐藏
///   `.ad-box`              等价 `##.ad-box`（手输时省事）
/// uBlock 的**网络过滤**语法（`||domain^`、`/ads/*`）注入实现不了，导入时会被跳过。
class AdBlockService extends ChangeNotifier {
  AdBlockService._();
  static final AdBlockService instance = AdBlockService._();

  /// JS → Dart 的消息通道名（页面建 controller 后要立刻挂上，见 [attach]）
  static const String channelName = 'TbAdBlock';

  static const String _kEnabled = 'adblock_enabled_v1';
  static const String _kBubble = 'adblock_bubble_v1';
  static const String _kBuiltin = 'adblock_builtin_v1';
  static const String _kBuiltinOff = 'adblock_builtin_off_v1';
  static const String _kFilterOn = 'adblock_filter_on_v1';
  static const String _kFilterSrc = 'adblock_filter_src_v1';
  static const String _kFilterAt = 'adblock_filter_at_v1';
  static const String _kFilterOrigin = 'adblock_filter_origin_v1'; // custom | builtin

  /// **内置**的 CSS 过滤器（**默认就用它，不用联网**）：
  /// 从 Adblock4limbo 的 `.user.css` 里抽出「元素隐藏」那一块
  /// （18008 条通用广告选择器 + `display:none!important`，约 321 KB），
  /// 丢掉它的工具箱 UI 样式（那些跟去广告无关）。MIT 许可，
  /// 版权与许可见 `assets/adblock/LICENSE-Adblock4limbo.txt`。
  static const String kBuiltinFilterAsset = 'assets/adblock/limbopro_ads.css';

  /// 内置过滤器的来源（联网"更新"用的地址）
  static const String kLimboHome = 'https://github.com/limbopro/Adblock4limbo';

  /// 毒奶去广告（Adblock4limbo）**真正管用的那一半**：纯 CSS 过滤器。
  ///
  /// 它仓库里的 `Adblock4limbo.conf` 是 Quantumult X 的 rewrite 规则
  /// （`正则 url reject` / `url script-response-body`）—— **网络层**，
  /// webview 拿不到请求层，我们一条都用不了；
  /// 但那份 JS 只是"往页面里注入 5 个外链脚本"的加载器，真正的去广告内容在这个
  /// CSS 里（约 1.8 万条选择器 + `display:none!important`）。**整份 CSS 能直接注入**，
  /// 这就是本模块支持的「CSS 过滤器」。
  static const String kLimboCssUrl =
      'https://limbopro.com/CSS/Adblock4limbo.user.css';

  bool _enabled = true;
  bool _bubble = true;
  bool _builtin = true;
  bool _loaded = false;

  final List<AdBlockRule> _rules = [];

  /// 被用户**单条关掉**的内置通用选择器（prefs 里存 StringList）
  final Set<String> _builtinOff = {};

  /// 导入的 **CSS 过滤器**（整份注入，例如毒奶的 Adblock4limbo.user.css）
  String _filterCss = '';
  String _filterSrc = '';
  bool _filterOn = true;
  int _filterAt = 0;

  /// 当前过滤器哪来的：`'custom'` = 用户导入的；其它 = **内置 asset**
  String _filterOrigin = '';

  /// 网页里刚选中的元素（悬浮按钮据此弹确认框）；发布-订阅式，谁在当前页谁处理
  final ValueNotifier<AdBlockPick?> lastPick = ValueNotifier(null);

  bool get enabled => _enabled;

  /// 网页里是否显示"选元素去广告"的悬浮球
  bool get showBubble => _bubble;

  /// 是否叠加内置通用选择器
  bool get builtinEnabled => _builtin;

  List<AdBlockRule> get rules => List.unmodifiable(_rules);

  /// 内置**通用**选择器 —— 只放"名字里明确就是广告"的，宁少勿滥。
  ///
  /// 故意**不用** `[class*="ad"]` 这种：它会命中 adaptive / load / header /
  /// read 等一大片正常元素（参考仓库里那 1.8 万条是逐站挑出来的，不是这种通配）。
  /// 站点专属的广告靠悬浮按钮手选（见 [AdBlockPick]），这也是参考实现的另一半做法。
  static const List<String> kBuiltinSelectors = [
    '.adsbygoogle',
    'ins.adsbygoogle',
    'iframe[src*="doubleclick"]',
    'iframe[src*="googlesyndication"]',
    'iframe[src*="googleadservices"]',
    '[id^="ad_"]',
    '[class^="ad_"]',
    '[class*="advert"]',
    '[id*="advert"]',
    '[class*="ad-banner"]',
    '[class*="banner-ad"]',
    '[class*="popup-ad"]',
    '[class*="pop-under"]',
    '[class*="float-ad"]',
    '[class*="ad-overlay"]',
    '[class*="ad-mask"]',
  ];

  // ============================================================
  // 页面接入
  // ============================================================

  /// 给 WebView 挂上消息通道。**必须在 loadRequest 之前**调用。
  static void attach(WebViewController controller) {
    try {
      controller.addJavaScriptChannel(
        channelName,
        onMessageReceived: (m) => AdBlockService.instance.onChannelMessage(m.message),
      );
    } catch (e) {
      AppLog.instance.log('[AdBlock] 挂载 JS 通道失败: $e');
    }
  }

  /// 把当前规则注入页面（`onPageStarted` 抢注入 + `onPageFinished` 补一次）。
  Future<void> injectInto(WebViewController controller, String pageUrl) async {
    await ensureLoaded();
    if (!_enabled) return;
    final selectors = selectorsFor(pageUrl);
    final extra = filterEnabled ? _filterCss : '';
    if (selectors.isEmpty && extra.isEmpty) return;
    try {
      await controller.runJavaScript(
          buildInjectJs(selectors, extraCss: extra));
    } catch (e) {
      AppLog.instance.log('[AdBlock] 注入失败: $e');
    }
  }

  /// 进入"点选元素"模式（悬浮按钮触发）
  Future<void> startPick(WebViewController controller) async {
    try {
      await controller.runJavaScript(kPickStartJs);
    } catch (e) {
      AppLog.instance.log('[AdBlock] 进入选元素模式失败: $e');
    }
  }

  Future<void> stopPick(WebViewController controller) async {
    try {
      await controller.runJavaScript('try{window.__tbPickStop&&window.__tbPickStop();}catch(e){}');
    } catch (_) {}
  }

  void onChannelMessage(String raw) {
    try {
      final j = jsonDecode(raw);
      if (j is! Map) return;
      final type = (j['type'] ?? '').toString();
      if (type == 'pick') {
        final sel = (j['selector'] ?? '').toString().trim();
        if (sel.isEmpty) return;
        lastPick.value = AdBlockPick(
          selector: sel,
          count: int.tryParse('${j['count']}') ?? 1,
          tag: (j['tag'] ?? '').toString(),
        );
      } else if (type == 'error') {
        AppLog.instance.log('[AdBlock] 页面脚本报错: ${j['msg']}');
      }
    } catch (e) {
      AppLog.instance.log('[AdBlock] 消息解析失败: $e');
    }
  }

  void consumePick() => lastPick.value = null;

  // ============================================================
  // 规则
  // ============================================================

  /// 某个网址适用的选择器（内置通用 + 命中该域名的用户规则）
  List<String> selectorsFor(String pageUrl) {
    final host = hostOf(pageUrl);
    final out = <String>[];
    if (_builtin) {
      for (final s in kBuiltinSelectors) {
        if (!_builtinOff.contains(s)) out.add(s);
      }
    }
    for (final r in _rules) {
      if (!r.enabled) continue;
      if (r.host.isEmpty || hostMatches(host, r.host)) {
        if (!out.contains(r.selector)) out.add(r.selector);
      }
    }
    return out;
  }

  /// 单条内置选择器是否生效（总开关关掉时全都不生效）
  bool builtinItemEnabled(String selector) =>
      _builtin && !_builtinOff.contains(selector);

  Future<void> setBuiltinItemEnabled(String selector, bool v) async {
    if (v) {
      _builtinOff.remove(selector);
    } else {
      _builtinOff.add(selector);
    }
    await _saveFlags();
    notifyListeners();
  }

  // ============================================================
  // CSS 过滤器（整份 CSS 直接注入）
  // ============================================================

  bool get hasFilter => _filterCss.isNotEmpty;

  /// 现在这份过滤器是**用户自己导入的**吗（否则就是内置版）
  bool get filterIsCustom => _filterOrigin == 'custom';

  /// 来源说明（内置 / 自定义网址）
  String get filterOriginLabel => filterIsCustom ? '自定义' : '内置';

  /// 过滤器当前生效吗（开关开着 **且** 真有内容）
  bool get filterEnabled => _filterOn && _filterCss.isNotEmpty;

  bool get filterSwitch => _filterOn;

  String get filterSource => _filterSrc;

  int get filterBytes => _filterCss.length;

  int get filterUpdatedAt => _filterAt;

  /// 从网址导入（覆盖旧的）。用带**全局代理**的 Dio 下载 —— 与全项目 27 处请求
  /// 一致，否则开了代理的用户这里必然失败。
  ///
  /// 返回 (成功?, 提示语)。
  Future<(bool, String)> importFilterFromUrl(String url) async {
    final u = url.trim();
    if (u.isEmpty) return (false, '网址是空的');
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 60),
      headers: const {'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)'},
    ));
    applyGlobalProxy(dio);
    try {
      final resp = await dio.get<List<int>>(u);
      final bytes = resp.data ?? const <int>[];
      if (bytes.isEmpty) return (false, '下载到 0 字节');
      final css = utf8.decode(bytes, allowMalformed: true);
      // 只认 CSS：HTML 错误页/JSON 之类直接拒掉，免得注入一堆垃圾
      if (!css.contains('{') || !css.contains('}')) {
        return (false, '内容不像 CSS（是不是下到了错误页？）');
      }
      _filterCss = css;
      _filterSrc = u;
      _filterOrigin = 'custom';
      _filterOn = true;
      _filterAt = DateTime.now().millisecondsSinceEpoch;
      await _persistFilter();
      await _saveFlags();
      notifyListeners();
      return (true, '已导入 ${(css.length / 1024).round()} KB（已替换内置版）');
    } catch (e) {
      return (false, '下载失败：$e');
    } finally {
      dio.close(force: true);
    }
  }

  /// 回到**内置版**过滤器（删掉用户导入的那份）
  Future<void> revertToBuiltinFilter() async {
    _filterOrigin = 'builtin';
    _filterSrc = '';
    _filterAt = 0;
    try {
      final f = await _filterFile();
      if (await f.exists()) await f.delete();
    } catch (_) {}
    _filterCss = await _readBuiltinFilter();
    await _saveFlags();
    notifyListeners();
  }

  Future<void> setFilterEnabled(bool v) async {
    _filterOn = v;
    await _saveFlags();
    notifyListeners();
  }

  Future<void> addRule({required String host, required String selector}) async {
    final s = selector.trim();
    if (s.isEmpty) return;
    final h = normalizeHost(host);
    if (_rules.any((r) => r.host == h && r.selector == s)) return;
    _rules.insert(0, AdBlockRule(host: h, selector: s));
    await _persist();
    notifyListeners();
  }

  Future<void> removeRule(AdBlockRule r) async {
    _rules.removeWhere((x) => x.host == r.host && x.selector == r.selector);
    await _persist();
    notifyListeners();
  }

  Future<void> updateRule(AdBlockRule old, {String? host, String? selector}) async {
    final i = _rules.indexWhere((x) => x.host == old.host && x.selector == old.selector);
    if (i < 0) return;
    _rules[i] = AdBlockRule(
      host: host == null ? old.host : normalizeHost(host),
      selector: (selector ?? old.selector).trim(),
      enabled: old.enabled,
    );
    await _persist();
    notifyListeners();
  }

  Future<void> setRuleEnabled(AdBlockRule r, bool v) async {
    final i = _rules.indexWhere((x) => x.host == r.host && x.selector == r.selector);
    if (i < 0) return;
    _rules[i] = r.copyWith(enabled: v);
    await _persist();
    notifyListeners();
  }

  Future<void> clearRules() async {
    _rules.clear();
    await _persist();
    notifyListeners();
  }

  /// 导入文本（一行一条，兼容 uBlock / AdGuard 的**元素隐藏**语法）。
  ///
  /// 返回 (成功条数, 跳过条数)；被跳过的是网络过滤语法（`||domain^` / `/path/*`）
  /// 与注释 —— 我们只能注入 CSS，拦不了请求。
  Future<(int, int)> importText(String text) async {
    var ok = 0;
    var skip = 0;
    for (var line in text.split('\n')) {
      line = line.trim();
      // ⚠️ `#` 开头的注释要放过 `##选择器` —— 后者是最常用的写法（原来一刀切
      //    把 `##.ad-box` 当注释跳过了，导入等于没导）
      if (line.isEmpty ||
          line.startsWith('!') ||
          (line.startsWith('#') && !line.startsWith('##'))) {
        skip++;
        continue;
      }
      // `域名##选择器` / `##选择器` / 纯选择器
      String host = '';
      var sel = line;
      final i = line.indexOf('##');
      if (i >= 0) {
        host = line.substring(0, i).trim();
        sel = line.substring(i + 2).trim();
      }
      // 网络过滤语法：拦不了，跳过
      if (sel.isEmpty ||
          sel.startsWith('||') ||
          sel.startsWith('/') ||
          // `^$` 是 ABP 的"域结束"标记 —— 属于网络过滤，用 raw 串避免 `$` 被当插值
          sel.contains(r'^$') ||
          line.startsWith('||')) {
        skip++;
        continue;
      }
      if (_rules.any((r) => r.host == normalizeHost(host) && r.selector == sel)) {
        skip++;
        continue;
      }
      _rules.add(AdBlockRule(host: normalizeHost(host), selector: sel));
      ok++;
    }
    if (ok > 0) {
      await _persist();
      notifyListeners();
    }
    return (ok, skip);
  }

  // ============================================================
  // 持久化：规则落 Documents/ad_block_rules.json（tmp→rename，留 .bak），
  // 开关落 SharedPreferences（与项目其它设置一致）
  // ============================================================

  Future<void> ensureLoaded() async {
    if (_loaded) return;
    await load();
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_kEnabled) ?? true;
      _bubble = prefs.getBool(_kBubble) ?? true;
      _builtin = prefs.getBool(_kBuiltin) ?? true;
      _builtinOff
        ..clear()
        ..addAll(prefs.getStringList(_kBuiltinOff) ?? const []);
      // CSS 过滤器：内容可能几百 KB（别塞 prefs）——
      // 自定义的读文件；没导入过的用**内置 asset**（默认就生效，不用联网）
      _filterOn = prefs.getBool(_kFilterOn) ?? true;
      _filterSrc = prefs.getString(_kFilterSrc) ?? '';
      _filterAt = prefs.getInt(_kFilterAt) ?? 0;
      _filterOrigin = prefs.getString(_kFilterOrigin) ?? '';
      _filterCss = _filterOrigin == 'custom'
          ? await _readFilterFile()
          : await _readBuiltinFilter();
      if (_filterOrigin == 'custom' && _filterCss.isEmpty) {
        // 自定义文件丢了（换机/清理）→ 回退内置，别让过滤器凭空消失
        _filterOrigin = 'builtin';
        _filterCss = await _readBuiltinFilter();
      }
      final list = await _readRules();
      _rules
        ..clear()
        ..addAll(list);
    } catch (e) {
      AppLog.instance.log('[AdBlock] 加载失败: $e');
      return;
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> setEnabled(bool v) async {
    _enabled = v;
    await _saveFlags();
    notifyListeners();
  }

  Future<void> setShowBubble(bool v) async {
    _bubble = v;
    await _saveFlags();
    notifyListeners();
  }

  Future<void> setBuiltinEnabled(bool v) async {
    _builtin = v;
    await _saveFlags();
    notifyListeners();
  }

  Future<void> _saveFlags() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabled, _enabled);
      await prefs.setBool(_kBubble, _bubble);
      await prefs.setBool(_kBuiltin, _builtin);
      await prefs.setStringList(_kBuiltinOff, _builtinOff.toList());
      await prefs.setBool(_kFilterOn, _filterOn);
      await prefs.setString(_kFilterSrc, _filterSrc);
      await prefs.setInt(_kFilterAt, _filterAt);
      await prefs.setString(_kFilterOrigin, _filterOrigin);
    } catch (e) {
      AppLog.instance.log('[AdBlock] 保存开关失败: $e');
    }
  }

  Future<File?> _file() async {
    try {
      final d = await getApplicationDocumentsDirectory();
      return File('${d.path}/ad_block_rules.json');
    } catch (e) {
      AppLog.instance.log('[AdBlock] 取目录失败: $e');
      return null;
    }
  }

  /// CSS 过滤器落盘位置：`<Documents>/ad_block_filter.css`
  Future<File> _filterFile() async {
    final d = await getApplicationDocumentsDirectory();
    return File('${d.path}/ad_block_filter.css');
  }

  Future<String> _readFilterFile() async {
    try {
      final f = await _filterFile();
      if (!await f.exists()) return '';
      return await f.readAsString();
    } catch (e) {
      AppLog.instance.log('[AdBlock] 读 CSS 过滤器失败: $e');
      return '';
    }
  }

  /// 读**内置**过滤器（随包 asset，不联网）
  Future<String> _readBuiltinFilter() async {
    try {
      final s = await rootBundle.loadString(kBuiltinFilterAsset);
      return s.trim();
    } catch (e) {
      AppLog.instance.log('[AdBlock] 读内置 CSS 过滤器失败: $e');
      return '';
    }
  }

  Future<void> _persistFilter() async {
    try {
      final f = await _filterFile();
      if (_filterCss.isEmpty) {
        if (await f.exists()) await f.delete();
        return;
      }
      await f.writeAsString(_filterCss, flush: true);
    } catch (e) {
      AppLog.instance.log('[AdBlock] 写 CSS 过滤器失败: $e');
    }
  }

  Future<List<AdBlockRule>> _readRules() async {
    final f = await _file();
    if (f == null) return const [];
    for (final path in [f.path, '${f.path}.bak']) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final raw = await file.readAsString();
        if (raw.trim().isEmpty) continue;
        final j = jsonDecode(raw);
        final list = j is Map ? j['rules'] : j;
        if (list is! List) continue;
        return [
          for (final e in list)
            if (e is Map) AdBlockRule.fromJson(Map<String, dynamic>.from(e)),
        ];
      } catch (_) {
        // 主文件坏了就试 .bak
      }
    }
    return const [];
  }

  Future<void> _persist() async {
    final f = await _file();
    if (f == null) return;
    final tmp = File('${f.path}.tmp');
    try {
      await tmp.writeAsString(
        jsonEncode({
          'version': 1,
          'rules': _rules.map((r) => r.toJson()).toList(),
        }),
        flush: true,
      );
      if (await f.exists()) {
        try {
          await f.copy('${f.path}.bak');
        } catch (_) {}
      }
      await tmp.rename(f.path);
    } catch (e) {
      AppLog.instance.log('[AdBlock] 写规则失败: $e');
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  // ============================================================
  // 域名工具（与 AdFilterService 同一口径，避免两处行为不一致）
  // ============================================================

  static String hostOf(String url) {
    try {
      return Uri.tryParse(url.trim())?.host.toLowerCase() ?? '';
    } catch (_) {
      return '';
    }
  }

  /// 归一化：去 `||`、去协议、去路径，小写
  static String normalizeHost(String raw) {
    var d = raw.trim().toLowerCase();
    if (d.startsWith('||')) d = d.substring(2);
    d = d.replaceFirst(RegExp(r'^[a-z]+://'), '');
    for (final sep in const ['/', '^', '?', '#', ' ', '*']) {
      final i = d.indexOf(sep);
      if (i >= 0) d = d.substring(0, i);
    }
    return d;
  }

  /// `host` 是否落在 [scope]（同域或子域）
  static bool hostMatches(String host, String scope) {
    if (scope.isEmpty) return true;
    if (host.isEmpty) return false;
    return host == scope || host.endsWith('.$scope');
  }

  // ============================================================
  // 注入脚本
  // ============================================================

  /// 生成"把选择器写成 display:none 并持续维持"的脚本。
  ///
  /// 要点：
  ///   · 幂等（`__tbAdBlockObs` 只装一次 MutationObserver）；
  ///   · 动态插入的广告（弹窗/浮层）也要盖住 ⇒ MutationObserver；
  ///   · 有些站点会删掉/覆盖注入的 `<style>` ⇒ 前 10 秒每 500ms 兜底刷一遍；
  ///   · 只有一条 style 标签，重复注入是**替换内容**而不是越堆越多。
  static String buildInjectJs(List<String> selectors, {String extraCss = ''}) {
    final json = jsonEncode(selectors);
    // 整份 CSS 过滤器（例如毒奶那 1.8 万条选择器）按 JSON 字符串安全嵌入：
    // 里面全是 `}` 与换行，直接拼进 JS 会炸语法
    final extra = jsonEncode(extraCss.trim());
    return '''
(function(){
  try {
    var SEL = $json;
    var EXTRA = $extra;
    var css = SEL.map(function(s){ return s + '{display:none !important;}'; }).join('\\n');
    if (EXTRA) css = css + '\\n' + EXTRA;
    if (!css) return 'ok';
    var apply = function(){
      var st = document.getElementById('__tbAdBlockStyle');
      if (!st) {
        st = document.createElement('style');
        st.id = '__tbAdBlockStyle';
        (document.head || document.documentElement).appendChild(st);
      }
      if (st.textContent !== css) st.textContent = css;
    };
    apply();
    if (!window.__tbAdBlockObs) {
      window.__tbAdBlockObs = 1;
      try {
        new MutationObserver(apply).observe(document.documentElement, {childList:true, subtree:true});
      } catch (e) {}
      var n = 0;
      var t = setInterval(function(){ apply(); if (++n > 20) clearInterval(t); }, 500);
    }
    return 'ok';
  } catch (e) { return 'err:' + e; }
})();
''';
  }

  /// 点选元素模式：高亮跟随 → 点一下算出选择器并回传（见 [AdBlockPick]）
  static const String kPickStartJs = r'''
(function(){
  try{
    if (window.__tbPickOn) return 'on';
    window.__tbPickOn = 1;
    var hi = document.getElementById('__tbPickHi');
    if (!hi) {
      hi = document.createElement('style');
      hi.id = '__tbPickHi';
      hi.textContent = '.__tbPickHl{outline:2px solid #0FDC78 !important;outline-offset:-2px !important;background:rgba(15,220,120,.18) !important;}';
      (document.head || document.documentElement).appendChild(hi);
    }
    var last = null;
    var send = function(o){ try{ window.TbAdBlock.postMessage(JSON.stringify(o)); }catch(e){} };
    var hl = function(el){
      if (last === el) return;
      try{ if (last && last.classList) last.classList.remove('__tbPickHl'); }catch(e){}
      last = el;
      try{ if (el && el.classList) el.classList.add('__tbPickHl'); }catch(e){}
    };
    var okName = function(s){ return /^[A-Za-z][A-Za-z0-9_-]*$/.test(s); };
    // 去掉「同类各异」的部分：长数字后缀（ad-1234）与明显的随机串
    var stable = function(t){
      if (!t) return '';
      if (/^[a-z]+[-_]?\d{3,}$/i.test(t)) return t.replace(/[-_]?\d{3,}$/, '');
      if (/^[A-Za-z0-9_-]{12,}$/.test(t) && /\d/.test(t)) return '';
      return t;
    };
    // 生成"能命中同类型元素"的选择器：优先 tag + class（同类一般共享 class）
    var gen = function(el){
      var tag = el.tagName ? el.tagName.toLowerCase() : 'div';
      var raw = (el.className && el.className.toString) ? el.className.toString().trim() : '';
      var cls = raw ? raw.split(/\s+/) : [];
      var kept = [];
      for (var i = 0; i < cls.length && kept.length < 3; i++) {
        var s = stable(cls[i]);
        if (s && okName(s) && kept.indexOf(s) < 0) kept.push(s);
      }
      if (kept.length) return tag + kept.map(function(c){ return '.' + c; }).join('');
      var id = el.id || '';
      if (id && okName(id) && id.length <= 40) {
        var sid = /^[a-z]+[-_]?\d{3,}$/i.test(id) ? id.replace(/[-_]?\d{3,}$/, '') : id;
        if (/^[A-Za-z]/.test(sid)) return '#' + sid;
      }
      var parts = [], cur = el, depth = 0;
      while (cur && cur.nodeType === 1 && depth < 3) {
        var t = cur.tagName.toLowerCase();
        var p = cur.parentNode;
        if (p) {
          var idx = 1, sib = p.firstElementChild;
          while (sib) { if (sib === cur) break; if (sib.tagName === cur.tagName) idx++; sib = sib.nextElementSibling; }
          t += ':nth-of-type(' + idx + ')';
        }
        parts.unshift(t);
        cur = cur.parentNode;
        depth++;
      }
      return parts.join(' > ');
    };
    var stop = function(){
      try{
        window.__tbPickOn = 0;
        document.removeEventListener('mouseover', onMove, true);
        document.removeEventListener('touchstart', onTouch, true);
        document.removeEventListener('click', onClick, true);
        if (last && last.classList) last.classList.remove('__tbPickHl');
      }catch(e){}
    };
    var onMove = function(e){ var el = e.target; if (el && el.nodeType === 1) hl(el); };
    var onTouch = function(e){
      var t = e.touches && e.touches[0];
      if (!t) return;
      var el = document.elementFromPoint(t.clientX, t.clientY);
      if (el) hl(el);
    };
    var onClick = function(e){
      e.preventDefault();
      e.stopPropagation();
      var el = e.target;
      if (!el || el.nodeType !== 1) { stop(); return; }
      var sel = gen(el), n = 1;
      try{ n = document.querySelectorAll(sel).length; }catch(err){}
      send({type:'pick', selector:sel, count:n, tag:el.tagName, id:el.id || ''});
      stop();
    };
    window.__tbPickStop = stop;
    document.addEventListener('mouseover', onMove, true);
    document.addEventListener('touchstart', onTouch, true);
    document.addEventListener('click', onClick, true);
    return 'ok';
  }catch(e){ return 'err'; }
})();
''';
}

/// 一条去广告规则：`host` 为空 = 所有网站
@immutable
class AdBlockRule {
  final String host;
  final String selector;
  final bool enabled;

  const AdBlockRule({
    required this.host,
    required this.selector,
    this.enabled = true,
  });

  AdBlockRule copyWith({String? host, String? selector, bool? enabled}) =>
      AdBlockRule(
        host: host ?? this.host,
        selector: selector ?? this.selector,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() => {
        'host': host,
        'selector': selector,
        'enabled': enabled,
      };

  factory AdBlockRule.fromJson(Map<String, dynamic> j) => AdBlockRule(
        host: (j['host'] ?? '').toString(),
        selector: (j['selector'] ?? '').toString(),
        enabled: j['enabled'] != false,
      );

  /// 展示成一条可再次导入的文本（`域名##选择器`）
  String get asText => host.isEmpty ? '##$selector' : '$host##$selector';
}

/// 网页里手选到的一个元素
@immutable
class AdBlockPick {
  final String selector;

  /// 这个选择器在页面上**命中多少个**元素（同类广告一次去掉）
  final int count;
  final String tag;

  const AdBlockPick({
    required this.selector,
    required this.count,
    this.tag = '',
  });
}
