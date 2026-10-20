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

  /// 网页跳第三方站点时是否拦截（默认**禁止**，弹窗让用户确认）。
  static const String _kBlockThirdParty = 'adblock_block_third_party_v1';

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
  bool _blockThirdParty = true;
  bool _loaded = false;

  final List<AdBlockRule> _rules = [];

  /// **回收站**：被删掉的规则（点选生成的也好、手加的也好）不直接丢，
  /// 在这里留一份，设置页「最近删除」里能一键恢复（用户 2026-10-16）。
  final List<AdBlockRule> _trash = [];

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

  /// 网页里跳转**第三方站点**时是否先弹窗确认（默认开 = 默认禁止）
  bool get blockThirdParty => _blockThirdParty;

  List<AdBlockRule> get rules => List.unmodifiable(_rules);

  /// 最近删除（可恢复）
  List<AdBlockRule> get trashRules => List.unmodifiable(_trash);

  /// 回收站最多留多少条（够反悔就行，别把文件撑大）
  static const int kTrashLimit = 50;

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

  /// 清掉点选时打的**橙色预览框**（用户确认 / 取消后调用）
  ///
  /// 点选那一下故意**保留**预览框（让用户先看清"这些都会被藏掉"），
  /// 所以必须由这边显式清 —— 否则框会一直挂在页面上（用户 2026-10-16 要求）。
  Future<void> clearPickPreview(WebViewController controller) async {
    try {
      await controller.runJavaScript(
          'try{window.__tbPickClear&&window.__tbPickClear();}catch(e){}');
    } catch (_) {}
  }

  /// 把橙框重画到 [selector] 命中的元素上（确认框里改选择器时实时预览）
  Future<void> previewSelector(WebViewController controller, String selector) async {
    try {
      await controller.runJavaScript(
          'try{window.__tbPickApi&&window.__tbPickApi.preview(${jsonEncode(selector)});}catch(e){}');
    } catch (_) {}
  }

  /// [selector] 在页面上会命中几个元素；-1 = 选择器非法/页面里没有点选脚本
  Future<int> countSelector(WebViewController controller, String selector) async {
    try {
      final r = await controller.runJavaScriptReturningResult(
          '(window.__tbPickApi?window.__tbPickApi.count(${jsonEncode(selector)}):-1)');
      return int.tryParse(_jsString(r)) ?? -1;
    } catch (_) {
      return -1;
    }
  }

  /// **微调**选择器（用户 2026-10-16：「功能更细化加强」）：
  ///   · `wide`   放大范围（标签 + 第一个 class，命中同类更多）
  ///   · `narrow` 精确到这一个（标签 + nth-of-type 路径）
  ///   · `parent` 上一层（点到了图片/小链接时的标准出路）
  /// 返回新选择器与新的命中数（同时页面上的橙框已经重画好）。
  Future<({String selector, int count})?> adjustPick(
    WebViewController controller,
    String mode,
  ) async {
    try {
      final r = await controller.runJavaScriptReturningResult(
          'JSON.stringify((window.__tbPickApi&&'
          'window.__tbPickApi.adjust(${jsonEncode(mode)}))||null)');
      final raw = _jsString(r);
      if (raw.isEmpty || raw == 'null') return null;
      final j = jsonDecode(raw);
      if (j is! Map) return null;
      final sel = (j['selector'] ?? '').toString();
      if (sel.isEmpty) return null;
      return (selector: sel, count: (j['count'] as num?)?.toInt() ?? -1);
    } catch (e) {
      AppLog.instance.log('[AdBlock] 微调选择器失败: $e');
      return null;
    }
  }

  /// `runJavaScriptReturningResult` 的返回值可能是**带引号的字符串**（iOS）
  /// 或裸值（Android），统一剥一层引号
  static String _jsString(dynamic r) {
    var s = '${r}'.trim();
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      s = s.substring(1, s.length - 1);
    }
    return s.replaceAll(r'\"', '"').replaceAll(r'\n', '');
  }

  /// 保存规则后**立刻生效并校验**：返回是否真的把 CSS 注进去了。
  ///
  /// 用户 2026-10-16：「点击去掉广告后应该自动刷新，感觉这个功能没成功」——
  /// 注入是异步的、且部分站点（CSP / 动态挂载）可能当场不生效，
  /// 所以这里做一次**实证校验**：确认 `<style id="__tbAdBlockStyle">` 存在、
  /// 且里面确实带上了这条选择器。没生效由调用方决定要不要 reload 兜底。
  Future<bool> applyAndVerify(
    WebViewController controller,
    String pageUrl,
    String selector,
  ) async {
    await injectInto(controller, pageUrl);
    try {
      // 选择器要**转义后**再拼进 JS（`jsonEncode` 出来的字符串本身就是合法 JS 字面量）
      final s = jsonEncode(selector);
      final r = await controller.runJavaScriptReturningResult(
          '(function(){try{'
          'var st=document.getElementById("__tbAdBlockStyle");'
          'if(!st)return "nostyle";'
          'if(String(st.textContent||"").indexOf($s)<0)return "nosel";'
          'return "ok";'
          '}catch(e){return "err";}})()');
      return '${r}'.replaceAll('"', '').trim() == 'ok';
    } catch (e) {
      AppLog.instance.log('[AdBlock] 校验注入结果失败: $e');
      return false;
    }
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

  Future<void> removeRule(AdBlockRule r, {bool toTrash = true}) async {
    final idx =
        _rules.indexWhere((x) => x.host == r.host && x.selector == r.selector);
    if (idx < 0) return;
    final gone = _rules.removeAt(idx);
    // ── 回收站（用户 2026-10-16：「删除指定的选中广告能不能恢复」）──
    // 删了直接丢就永远找不回来（广告管理页那个 ✕ 很容易手滑）。这里改成
    // **软删除**：进回收站，设置页「最近删除」里可一键恢复。
    if (toTrash) {
      _trash.removeWhere(
          (x) => x.host == gone.host && x.selector == gone.selector);
      _trash.insert(0, gone);
      if (_trash.length > kTrashLimit) {
        _trash.removeRange(kTrashLimit, _trash.length);
      }
    }
    await _persist();
    notifyListeners();
  }

  /// 从回收站恢复一条（恢复后立刻参与注入）
  Future<void> restoreRule(AdBlockRule r) async {
    _trash
        .removeWhere((x) => x.host == r.host && x.selector == r.selector);
    if (!_rules.any((x) => x.host == r.host && x.selector == r.selector)) {
      _rules.insert(0, r);
    }
    await _persist();
    notifyListeners();
  }

  /// 恢复**全部**最近删除
  Future<int> restoreAllTrash() async {
    final n = _trash.length;
    for (final r in _trash.reversed) {
      if (!_rules.any((x) => x.host == r.host && x.selector == r.selector)) {
        _rules.insert(0, r);
      }
    }
    _trash.clear();
    await _persist();
    notifyListeners();
    return n;
  }

  /// 清空回收站（彻底删除）
  Future<void> clearTrash() async {
    _trash.clear();
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
    // 清空也走回收站 —— "全删了"同样需要一个后悔药
    for (final r in _rules.reversed) {
      _trash.removeWhere((x) => x.host == r.host && x.selector == r.selector);
      _trash.insert(0, r);
    }
    _rules.clear();
    if (_trash.length > kTrashLimit) {
      _trash.removeRange(kTrashLimit, _trash.length);
    }
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
      _blockThirdParty = prefs.getBool(_kBlockThirdParty) ?? true;
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
      final parsed = await _readRules();
      _rules
        ..clear()
        ..addAll(parsed.rules);
      _trash
        ..clear()
        ..addAll(parsed.trash);
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

  Future<void> setBlockThirdParty(bool v) async {
    _blockThirdParty = v;
    await _saveFlags();
    notifyListeners();
  }

  Future<void> _saveFlags() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabled, _enabled);
      await prefs.setBool(_kBubble, _bubble);
      await prefs.setBool(_kBuiltin, _builtin);
      await prefs.setBool(_kBlockThirdParty, _blockThirdParty);
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

  /// 读规则（顺带读回收站）。文件里 `rules` / `trash` 是两个数组
  Future<({List<AdBlockRule> rules, List<AdBlockRule> trash})> _readRules()
      async {
    final f = await _file();
    if (f == null) {
      return (rules: const <AdBlockRule>[], trash: const <AdBlockRule>[]);
    }
    for (final path in [f.path, '${f.path}.bak']) {
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final raw = await file.readAsString();
        if (raw.trim().isEmpty) continue;
        final j = jsonDecode(raw);
        // 老格式：顶层直接是数组（还没有回收站）
        if (j is! Map) {
          if (j is List) {
            return (rules: _rulesOf(j), trash: const <AdBlockRule>[]);
          }
          continue;
        }
        final rl = j['rules'];
        final tl = j['trash'];
        return (
          rules: rl is List ? _rulesOf(rl) : const <AdBlockRule>[],
          trash: tl is List ? _rulesOf(tl) : const <AdBlockRule>[],
        );
      } catch (_) {
        // 主文件坏了就试 .bak
      }
    }
    return (rules: const <AdBlockRule>[], trash: const <AdBlockRule>[]);
  }

  static List<AdBlockRule> _rulesOf(List<dynamic> list) => [
        for (final e in list)
          if (e is Map) AdBlockRule.fromJson(Map<String, dynamic>.from(e)),
      ];

  Future<void> _persist() async {
    final f = await _file();
    if (f == null) return;
    final tmp = File('${f.path}.tmp');
    try {
      await tmp.writeAsString(
        jsonEncode({
          'version': 1,
          'rules': _rules.map((r) => r.toJson()).toList(),
          // 回收站（最近删除，可恢复）
          'trash': _trash.map((r) => r.toJson()).toList(),
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
  ///
  /// ── 用户 2026-10-16 的要求 ────────────────────────────────────
  /// ① 「点击后要将选中的内容加个亮框」：原来 `onClick` 里 `stop()` 把悬停高亮
  ///    一并清掉 ⇒ 点完没痕迹。现在点完给**所有命中该选择器的元素**加**橙框**
  ///    （= "这些都会被藏掉"），留到确认/取消才清（[AdBlockService.clearPickPreview]）。
  /// ② 「功能更细化加强」：暴露 `window.__tbPickApi`，让确认框里能：
  ///    · `preview(sel)` 改选择器时**实时重画橙框**（所见即所得）
  ///    · `count(sel)`   实时显示"会命中几个"
  ///    · `adjust('wide'|'narrow'|'parent')` 一键**放大 / 精确 / 上一层**
  ///      —— 点不准（点到图片、点到小链接）时的唯一出路，基于**最后点的那个元素**
  ///      重新生成，比让用户手改 CSS 靠谱。
  static const String kPickStartJs = r'''
(function(){
  try{
    if (window.__tbPickOn) return 'on';
    window.__tbPickOn = 1;
    var hi = document.getElementById('__tbPickHi');
    if (!hi) {
      hi = document.createElement('style');
      hi.id = '__tbPickHi';
      hi.textContent =
        '.__tbPickHl{outline:2px solid #0FDC78 !important;outline-offset:-2px !important;background:rgba(15,220,120,.18) !important;}' +
        '.__tbPickHit{outline:3px solid #FFB300 !important;outline-offset:-3px !important;background:rgba(255,179,0,.16) !important;}';
      (document.head || document.documentElement).appendChild(hi);
    }
    var last = null;      // 悬停高亮的元素
    var lastEl = null;    // **最后点中**的元素（微调要以它为基准）
    var hits = [];
    var send = function(o){ try{ window.TbAdBlock.postMessage(JSON.stringify(o)); }catch(e){} };
    var hl = function(el){
      if (last === el) return;
      try{ if (last && last.classList) last.classList.remove('__tbPickHl'); }catch(e){}
      last = el;
      try{ if (el && el.classList) el.classList.add('__tbPickHl'); }catch(e){}
    };
    var clearHits = function(){
      for (var i = 0; i < hits.length; i++) {
        try{ if (hits[i] && hits[i].classList) hits[i].classList.remove('__tbPickHit'); }catch(e){}
      }
      hits = [];
    };
    window.__tbPickClear = clearHits;
    var showHits = function(sel){
      clearHits();
      try{
        var nodes = document.querySelectorAll(sel);
        for (var i = 0; i < nodes.length && i < 60; i++) {
          if (nodes[i] && nodes[i].classList) {
            nodes[i].classList.add('__tbPickHit');
            hits.push(nodes[i]);
          }
        }
      }catch(e){}
    };
    var countOf = function(sel){
      try{ return document.querySelectorAll(sel).length; }catch(e){ return -1; }
    };
    var okName = function(s){ return /^[A-Za-z][A-Za-z0-9_-]*$/.test(s); };
    // 去掉「同类各异」的部分：长数字后缀（ad-1234）与明显的随机串
    var stable = function(t){
      if (!t) return '';
      if (/^[a-z]+[-_]?\d{3,}$/i.test(t)) return t.replace(/[-_]?\d{3,}$/, '');
      if (/^[A-Za-z0-9_-]{12,}$/.test(t) && /\d/.test(t)) return '';
      return t;
    };
    // 标签 + 第 n 个同类（只命中"这一个"，用于"精确"）
    var nthOf = function(el){
      var t = el.tagName ? el.tagName.toLowerCase() : 'div';
      var p = el.parentNode;
      if (p) {
        var idx = 1, sib = p.firstElementChild;
        while (sib) {
          if (sib === el) break;
          if (sib.tagName === el.tagName) idx++;
          sib = sib.nextElementSibling;
        }
        t += ':nth-of-type(' + idx + ')';
      }
      return t;
    };
    // 逐级往上的路径（最多 3 层 nth-of-type）：保证"只命中这一处"
    var genPath = function(el){
      var parts = [], cur = el, depth = 0;
      while (cur && cur.nodeType === 1 && depth < 3) {
        parts.unshift(nthOf(cur));
        cur = cur.parentNode;
        depth++;
      }
      return parts.join(' > ');
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
      return genPath(el);
    };
    // ── 微调 API（确认框里的「放大 / 精确 / 上一层」与实时预览都走它）──
    window.__tbPickApi = {
      preview: function(sel){ showHits(sel); return 0; },
      count: function(sel){ return countOf(sel); },
      // mode: wide 更宽松（标签+第一个 class） / narrow 只此一个 / parent 上一层
      adjust: function(mode){
        var el = lastEl;
        if (!el) return null;
        var target = (mode === 'parent' && el.parentElement) ? el.parentElement : el;
        var sel = '';
        if (mode === 'wide') {
          var tag = target.tagName ? target.tagName.toLowerCase() : 'div';
          var raw = (target.className && target.className.toString) ? target.className.toString().trim() : '';
          var first = raw ? stable(raw.split(/\s+/)[0]) : '';
          sel = (first && okName(first)) ? (tag + '.' + first) : tag;
        } else if (mode === 'narrow') {
          sel = genPath(target);
        } else if (mode === 'parent') {
          sel = gen(target);
        } else {
          sel = gen(target);
        }
        if (!sel) return null;
        lastEl = target;      // 连续点"上一层"能一路往上走
        showHits(sel);
        return { selector: sel, count: countOf(sel), tag: (target.tagName || '') };
      }
    };
    // keepPreview=true 时保留"将命中"的橙框（点选完成，等用户确认）
    var stop = function(keepPreview){
      try{
        window.__tbPickOn = 0;
        document.removeEventListener('mouseover', onMove, true);
        document.removeEventListener('touchstart', onTouch, true);
        document.removeEventListener('click', onClick, true);
        if (last && last.classList) last.classList.remove('__tbPickHl');
        if (!keepPreview) clearHits();
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
      if (!el || el.nodeType !== 1) { stop(false); return; }
      lastEl = el;
      var sel = gen(el), n = countOf(sel);
      // ① 先给命中的元素打上橙框（用户看得到"要藏哪些"）
      showHits(sel);
      send({type:'pick', selector:sel, count:n, tag:el.tagName, id:el.id || ''});
      // ② 停监听但**保留橙框** —— 由 Dart 在确认/取消后调 __tbPickClear
      stop(true);
    };
    window.__tbPickStop = function(){ stop(false); };
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
