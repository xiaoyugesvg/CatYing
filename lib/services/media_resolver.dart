import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import 'package:tvbox/reading/source/global_proxy.dart';
import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/media_sniff_service.dart';
import 'package:tvbox/services/media_sniffer.dart';
import 'package:tvbox/services/parse_lines.dart';
import 'package:tvbox/services/play_pipeline.dart';

/// 后台把「网页播放地址 / 解析接口链接」解析成**媒体直链**。
///
/// ── 三条硬约束（用户 2026-10-29 明确要求）──────────────────────
///   1. **全程在后台跑**：不起 WebView、不弹页面、不打断播放器；
///   2. **没有开关**：只要播放地址是网页形态，就直接解析，用户无感；
///   3. **给足时间**：网页/解析接口经常要 2~6 秒才吐地址，而且第一轮
///      常常空手（CDN 预热、接口排队），所以这里做**多轮重试 + 总预算**，
///      而不是一次失败就判死。
///
/// ── 解析顺序 ──────────────────────────────────────────────────
///   ① 直接抓页面 HTML，正则找 m3u8/mp4（最快，不依赖解析线路）；
///   ② 页面里嵌的 iframe / `?url=` 再跟一跳（很多"播放页"其实是个壳）；
///   ③ 解析线路（订阅 `parses` 或自定义）逐条试 —— 选中那条排最前；
///   ④ 以上都没拿到 ⇒ 在总预算内再重来一轮（最多 3 轮）；
///   ⑤ **仍未拿到 ⇒ 隐形 WebView 嗅探兜底**（2026-10-31 Phase 2）。
///
/// ── 选路（2026-10-31）─────────────────────────────────────────
/// ①②③ 不是对每种地址都该按这个顺序跑。`PlayPipeline.routeFor` 会先判：
///   · `platform`（爱奇艺/优酷/腾讯/芒果/B站/PPTV）：页面是 SPA，抓 HTML
///     一定空手 —— **跳过 ①②**，直接上解析线路，省下 8s×3 轮；
///   · `parseUrl`（`jx.xx/?url=...`）：它本身就是一条线路，先请求它；
///   · `plainPage`：按原顺序。
///
/// ── 平台页要先套线路再嗅探（2026-10-31）──────────────────────
/// 用户：「这些域名的播放链接要加解析线路才能嗅探呢」。对 ——
/// `v.qq.com/x/cover/xxx.html` 这类页面**直接嗅探一定 0 候选**（SPA +
/// 会员校验 + DRM），能出地址的形态是 `jx.xx/?url=https://v.qq.com/...`。
/// 所以平台页的嗅探对象是「套过线路的地址」，不是平台页本身，
/// 见 [sniffTargetFor]。
///
/// 结果按页面地址缓存（同一集重进不再解析）。
class MediaResolver {
  MediaResolver._();
  static final MediaResolver instance = MediaResolver._();

  /// 默认总预算：HTTP 阶段跑完 + 嗅探兜底还能顺 4 层 iframe。
  ///
  /// 为什么从 22s 提到 30s、又提到 **35s**（2026-10-31 日志实测）：
  ///
  /// 22s 那次（`app_2026-10-31(8).log`）的现场是：
  /// ```
  /// 22:02:59.049  第 4 层: api-api.789jiexi.net/jiexi.php
  /// 22:03:00.535  第 4 层环境: {"hook":true,"jq":"function","cj":"object",
  ///                            "stray":"object","cfg":"object","frames":0}
  /// 22:03:00.535  未嗅到媒体地址（候选 0 条，跟过 3 个 iframe，4 层）
  /// ```
  /// 第 4 层**只活了 1.48 秒**就被总预算砍断 —— 而这一层恰恰是唯一出地址的
  /// 那一层：它要 `$.post("api.php")` 拿密文、再 `decrypt()` 解密、再建
  /// Artplayer 实例。环境自检里 `stray` / `cfg` / `jq` 全在，说明 hook 正常、
  /// 页面也在跑，**只是没给够时间**。
  ///
  /// 前 3 层实测共约 12s（每层 2.5~3.3s，露出 iframe 就提前跟），
  /// 第 4 层还要 3~5s 解密建播放器 ⇒ 12+5 = 17s，20s 只剩 3s 余量太薄，
  /// 给到 25s 才有抗抖动空间。
  ///
  /// 35s 只是**上限**：命中就立刻返回（szctv 那种 3.2s 就出地址），
  /// 只有全链路都空手时才等满，期间有 [_resolveHint] 一路显示进度。
  ///
  /// 38 = [_sniffReserve] 28 + HTTP 兜底 10（≥ [_minHttpBudget] 8）。
  static const Duration defaultBudget = Duration(seconds: 38);

  /// 单次 HTTP 超时上限
  static const Duration _requestTimeout = Duration(seconds: 8);

  /// 给「嗅探兜底」预留的预算上限（HTTP 阶段最多用到 `budget - 这个值`）
  ///
  /// 25s = 前 3 层实测 12s + 第 4 层解密建播放器 5s + 抗抖动余量。
  /// 12s（最早）只够走 2~3 层，20s 在 4 层链上只剩 3s 余量 ——
  /// 日志里两次都是「第 4 层刚加载就被砍」。
  ///
  /// 28s（2026-10-31）：`bd.jx.cn` 那条链的第 4 层是裸 IP 上的 WASM 播放器
  /// （394KB 混淆脚本 + Artplayer），10s 时间片差一口气。层数上限也从 4 提到 6
  /// （见 `MediaSniffService._maxHops`），6 × 3s 中转 + 最后一层 10s 刚好 28s。
  static const Duration _sniffReserve = Duration(seconds: 28);

  /// HTTP 阶段至少给这么多，否则一条线路都试不完就去嗅探，得不偿失
  static const Duration _minHttpBudget = Duration(seconds: 8);

  /// 剩余预算低于这个值就不做嗅探了（起 WebView 本身也要时间）
  static const Duration _minSniffBudget = Duration(seconds: 4);

  /// **平台页**的总预算上限（比 [defaultBudget] 宽）。
  ///
  /// 平台页天生比普通播放页慢一整步：要先套解析线路、再嗅探线路页，
  /// 而线路页本身还可能是 2~4 层 iframe。30s 会卡在「线路刚套好、
  /// 嗅探刚到第 3 层」的位置 —— 和之前 12s 砍断第 4 层是同一个毛病。
  ///
  /// 50s 只是上限：命中的情况一般 5~15s 就出（线路页通常 1~2 层）。
  /// 40 = 唯一那条线路 28s + HTTP 兜底 12s。
  static const Duration _platformBudget = Duration(seconds: 40);

  /// 平台页**只用当前这一条**解析线路嗅探，不再自动连着试好几条。
  ///
  /// ── 为什么改成 1（2026-10-31 用户）────────────────────────────
  /// 用户原话：「那么多线路你一个个弄吗，切换线路就是切换前缀，解析站不行
  /// 那就是我自己切换线路，直接嗅探这个加了前缀的页面里面的视频不就完了么」。
  ///
  /// 他是对的。自动连着试 3 条线路的真实代价：
  ///   · 用户坐在那里等 40~50 秒，还不知道在等什么；
  ///   · 试的第 2、3 条**不是用户选的**，等于 App 替他做决定；
  ///   · 而"换线路"本来就是用户自己的操作（播放页就有线路切换），
  ///     一次只试一条、失败立刻返回，用户换一下比等 50 秒快得多。
  ///
  /// 顺序仍然是 [ParseLineStore.attemptOrder]：用户选中的那条排最前。
  static const int _platformSniffLines = 1;

  /// 页面 → 媒体地址 缓存（按集缓存，重进不再解析）
  final Map<String, String> _cache = {};
  static const int _cacheLimit = 60;

  /// 正在解析的页面（同一地址并发请求合并，避免重复打接口）
  final Map<String, Future<String?>> _inflight = {};

  String? cached(String pageUrl) => _cache[pageUrl];

  void clearCache() => _cache.clear();

  /// 决定「这条地址该嗅探什么」——**平台页要先套一条解析线路**。
  ///
  /// ── 为什么要这样（用户 2026-10-31）──────────────────────────
  /// 用户原话：「爱奇艺、腾讯、优酷、芒果、哔哩哔哩、PPTV 这些域名链接的
  /// 解析弄了么？这些域名的播放链接要加解析线路才能嗅探呢」。
  ///
  /// 完全正确。直接嗅探 `v.qq.com/x/cover/xxx.html` **一定 0 候选**：
  ///   · 页面是 SPA，播放器要等登录 / 会员校验之后才由 JS 创建；
  ///   · 正片流走 DRM（Widevine / FairPlay），抓到也解不了；
  ///   · 平台还会按 Referer + Cookie 校验播放来源。
  ///
  /// 能出地址的形态是 `jx.xx/?url=https://v.qq.com/...` —— 探针页一直在测的
  /// 就是这种地址。所以平台页的顺序必须是 **套线路 → 嗅探线路页**，
  /// 而不是「嗅探平台页 → 再套线路」。
  ///
  /// 非平台页（普通播放页 / 已套过接口的 `jx.xx/?url=`）原样返回。
  Future<SniffTarget> sniffTargetFor(
    String pageUrl, {
    Map<String, String> headers = const {},
  }) async {
    final all = await sniffTargetsFor(pageUrl, headers: headers);
    return all.first;
  }

  /// 同上，但平台页会把地址**套上解析线路前缀**再返回。
  ///
  /// 只取当前这一条（[_platformSniffLines] = 1）：线路由用户自己切，
  /// 解析站不行就换一条，不该由 App 连着试好几条让他干等。
  Future<List<SniffTarget>> sniffTargetsFor(
    String pageUrl, {
    Map<String, String> headers = const {},
  }) async {
    if (PlayPipeline.routeFor(pageUrl) != PlayRoute.platform) {
      return [SniffTarget(url: pageUrl, label: '原页面', headers: headers)];
    }
    final lines = await availableParseLines();
    if (lines.isEmpty) {
      // 一条线路都没有：只能硬着头皮嗅探平台页（基本空手，但至少不是静默失败）
      AppLog.instance.w('[Resolve] 平台页但没有任何解析线路可用: $pageUrl');
      return [
        SniffTarget(
          url: pageUrl,
          label: '原页面（无线路可用）',
          headers: headers,
        ),
      ];
    }
    final picked = lines.take(_platformSniffLines).toList();
    AppLog.instance.log(
      '[Resolve] 平台页先套线路再嗅探：${picked.map((e) => e.name).join(' / ')}',
    );
    return [
      for (final line in picked)
        SniffTarget(
          url: line.apply(pageUrl),
          label: '线路「${line.name}」',
          headers: {...headers, ...line.headers},
          viaParseLine: true,
        ),
    ];
  }

  /// 可用解析线路：用户选中的排最前（[ParseLineStore.attemptOrder]）。
  ///
  /// 读不到线路就返回空列表 —— 调用方按「没有线路可用」处理，不抛异常。
  Future<List<ParseLine>> availableParseLines() async {
    final store = ParseLineStore.instance;
    try {
      if (!store.loaded) await store.load();
      if (store.isEmpty) await store.ensureSyncedFromConfig();
    } catch (e) {
      AppLog.instance.w('[Resolve] 读解析线路失败: $e');
    }
    return store.attemptOrder;
  }

  /// 解析入口。返回 null = 没解析出来（调用方按"这条线路播不了"处理）。
  ///
  /// [onProgress] 可选：把"正在试第几条线路"回给调用方，用于界面上的
  /// 一行小字提示（不弹窗、不遮画面）。
  ///
  /// [allowSniff] 是否允许用隐形 WebView 嗅探。
  /// 「解析测试」页传 false，让"解析"和"嗅探"两种测试保持独立可比。
  ///
  /// [sniffFirst] **嗅探优先**：先用真浏览器把页面跑起来抓，抓不到再退回
  /// HTTP 抓页面 + 解析线路。影视模块 / 海阔 / RSS 都该传 true。
  ///
  /// 平台页（爱奇艺 / 腾讯 / 优酷 / 芒果 / B站 / PPTV）会自动先套一条解析
  /// 线路再嗅探 —— 直接嗅探平台页是 0 候选，见 [sniffTargetFor]。
  ///
  /// 为什么顺序很关键（用户 2026-10-31：「影视模块现在的解析线路和嗅探
  /// 完全不是现在测试的这种」）：原来是「HTTP 先吃 10s，嗅探只吃剩下的
  /// 12s」，而实测 `jx.muiu.site` 那条链要 4 层、12~19s —— 第 4 层刚开始
  /// 就被总预算砍断。探针页之所以能成功，就因为它把嗅探放在第一位。
  /// 两条路必须是同一条，否则「测试页能播、正片播不了」永远对不上。
  Future<String?> resolve(
    String pageUrl, {
    Map<String, String> headers = const {},
    Duration budget = defaultBudget,
    bool allowSniff = true,
    bool sniffFirst = false,
    void Function(String message)? onProgress,
  }) {
    final url = pageUrl.trim();
    if (url.isEmpty) return Future.value(null);
    // 本来就是媒体直链：不需要解析
    if (MediaSniffer.isMediaUrl(url)) return Future.value(url);
    if (!url.startsWith('http')) return Future.value(null);

    final hit = _cache[url];
    if (hit != null) {
      AppLog.instance.log('[Resolve] 命中缓存: $url → $hit');
      return Future.value(hit);
    }
    final running = _inflight[url];
    if (running != null) return running;

    final task = _doResolve(
      url,
      headers: headers,
      budget: budget,
      allowSniff: allowSniff,
      sniffFirst: sniffFirst,
      onProgress: onProgress,
    );
    _inflight[url] = task;
    return task.whenComplete(() => _inflight.remove(url));
  }

  Future<String?> _doResolve(
    String pageUrl, {
    required Map<String, String> headers,
    required Duration budget,
    required bool allowSniff,
    required bool sniffFirst,
    void Function(String message)? onProgress,
  }) async {
    final startedAt = DateTime.now();
    // 嗅探优先跑过之后，后面的 HTTP 流程不该再重复嗅探一次
    var sniffAllowed = allowSniff;

    // 选路要**提前**算：嗅探对象取决于它（平台页得先套线路）
    final route = PlayPipeline.routeFor(pageUrl);

    // 平台页给更宽的预算（先套线路再嗅探，天生多一步）
    var totalBudget = budget;
    if (route == PlayRoute.platform && totalBudget < _platformBudget) {
      totalBudget = _platformBudget;
      AppLog.instance.log(
        '[Resolve] 平台页，预算提到 ${totalBudget.inSeconds}s（要先套线路再嗅探）',
      );
    }

    // ── 嗅探优先：和探针页「点击播放」完全同一条路径 ──────────────
    if (sniffFirst && allowSniff) {
      final sniffBudget =
          totalBudget < _sniffReserve ? totalBudget : _sniffReserve;
      // ⚠️ 关键：平台页不能直接嗅探平台页本身（SPA + 会员校验 + DRM，
      // 一定 0 候选），要先把地址套上解析线路，嗅探「线路页」。
      final targets = await sniffTargetsFor(pageUrl, headers: headers);
      for (final target in targets) {
        var budgetForTarget = sniffBudget;
        final left = totalBudget - DateTime.now().difference(startedAt);
        if (left < _minSniffBudget) {
          AppLog.instance.log('[Resolve] 预算不足，剩下的线路不再嗅探');
          break;
        }
        if (budgetForTarget > left) budgetForTarget = left;

        onProgress?.call(
          target.viaParseLine ? '正在用${target.label}解析…' : '正在页面里嗅探播放地址…',
        );
        AppLog.instance.log(
          '[Resolve] 嗅探优先 · ${target.label} · 预算 ${budgetForTarget.inSeconds}s'
          '（和探针页同一条路）→ ${target.url}',
        );
        try {
          final sniffed = await MediaSniffService.instance.sniff(
            target.url,
            headers: target.headers,
            budget: budgetForTarget,
            onProgress: onProgress,
          );
          if (sniffed != null && sniffed.isNotEmpty) {
            AppLog.instance.log('[Resolve] 嗅探优先命中（${target.label}）: $sniffed');
            _cache[pageUrl] = sniffed;
            if (_cache.length > _cacheLimit) _cache.remove(_cache.keys.first);
            return sniffed;
          }
          AppLog.instance.log('[Resolve] ${target.label} 没抓到，换下一条');
        } catch (e) {
          AppLog.instance.w('[Resolve] 嗅探优先异常（${target.label}）: $e');
        }
      }
      AppLog.instance.log('[Resolve] 嗅探优先全部空手，退回 HTTP 解析');
      // 已经试过了，别再兜底一遍（否则等于白等两轮）
      sniffAllowed = false;
    }

    // ── 预算切分：HTTP 先跑，剩下的留给嗅探兜底 ──────────────────
    final reserve = sniffAllowed ? _sniffReserve : Duration.zero;
    var httpBudget = totalBudget - reserve;
    if (httpBudget < _minHttpBudget) httpBudget = _minHttpBudget;
    final deadline = startedAt.add(httpBudget);

    AppLog.instance.log(
      '[Resolve] 选路=${PlayPipeline.routeLabel(route)}，'
      'HTTP 预算 ${httpBudget.inSeconds}s，嗅探兜底=${sniffAllowed ? "开" : "关"}',
    );

    final dio = Dio(
      BaseOptions(
        connectTimeout: _requestTimeout,
        receiveTimeout: _requestTimeout,
        followRedirects: true,
        responseType: ResponseType.plain,
        validateStatus: (s) => s != null && s < 500,
      ),
    );
    applyGlobalProxy(dio);

    String? found;
    try {
      // 平台页（SPA）抓 HTML 一定空手 → 跳过「抓页面」，直接上线路
      final pageFirst = route != PlayRoute.platform;
      if (!pageFirst) {
        onProgress?.call('平台页面，直接用解析线路…');
      }

      // ── 最多 3 轮：第一轮常常空手，重试往往就有了 ──────────────
      for (var round = 1; round <= 3 && found == null; round++) {
        if (DateTime.now().isAfter(deadline)) break;
        if (round > 1) {
          // 轮间退避：给接口/CDN 一点时间
          await Future<void>.delayed(Duration(milliseconds: 400 * round));
          if (DateTime.now().isAfter(deadline)) break;
        }
        onProgress?.call(
          round == 1 ? '正在解析播放地址…' : '正在重试解析（第 $round 轮）…',
        );

        // ① 直接抓页面
        if (pageFirst) {
          found = await _fromPage(dio, pageUrl, headers, deadline);
          if (found != null) break;
        }

        // ② 解析线路
        final lines = ParseLineStore.instance.attemptOrder.take(6).toList();
        for (var i = 0; i < lines.length; i++) {
          if (DateTime.now().isAfter(deadline)) break;
          final line = lines[i];
          onProgress?.call('正在用「${line.name}」解析…');
          found = await _fromParseLine(dio, line, pageUrl, headers, deadline);
          if (found != null) {
            AppLog.instance.log(
              '[Resolve] 解析成功（${line.name}，第 $round 轮）: $found',
            );
            break;
          }
        }
      }
    } catch (e) {
      AppLog.instance.w('[Resolve] 解析异常: $e');
    } finally {
      dio.close(force: true);
    }

    // ── ⑤ 嗅探兜底：HTTP 全空手时，让真浏览器把页面跑起来抓 ──────
    if (found == null && sniffAllowed) {
      var left = totalBudget - DateTime.now().difference(startedAt);
      if (left > _sniffReserve) left = _sniffReserve;
      if (left >= _minSniffBudget) {
        // 平台页在这里同样要先套线路：直接嗅探平台页是 0 候选
        final target = await sniffTargetFor(pageUrl, headers: headers);
        onProgress?.call(
          target.viaParseLine ? '改用${target.label}嗅探…' : '改用浏览器嗅探…',
        );
        try {
          found = await MediaSniffService.instance.sniff(
            target.url,
            headers: target.headers,
            budget: left,
            onProgress: onProgress,
          );
          if (found != null) {
            AppLog.instance.log('[Resolve] 嗅探兜底成功: $found');
          }
        } catch (e) {
          AppLog.instance.w('[Resolve] 嗅探兜底异常: $e');
        }
      } else {
        AppLog.instance.log('[Resolve] 剩余预算不足，跳过嗅探兜底');
      }
    }

    if (found != null) {
      _cache[pageUrl] = found;
      if (_cache.length > _cacheLimit) {
        _cache.remove(_cache.keys.first);
      }
    } else {
      AppLog.instance
          .w('[Resolve] 解析失败（已用 ${totalBudget.inSeconds}s 预算）: $pageUrl');
    }
    return found;
  }

  /// ① 抓页面本身（递归跟 iframe / `?url=` / 返回的网页地址）
  Future<String?> _fromPage(
    Dio dio,
    String pageUrl,
    Map<String, String> headers,
    DateTime deadline,
  ) =>
      _digUrl(dio, pageUrl, headers, deadline, 0);

  /// 链路最大跳数。
  ///
  /// 真实链路经常是三层：`解析接口 → ckplayer 壳页 → iframe 播放器 → m3u8`。
  /// 只跟一跳会停在壳页上，把**网页地址**当播放地址交给播放器 —— 用户看到的
  /// 就是「这个地址是网页而不是视频直链」（2026-10-30 截图里的
  /// `www.ckplayer.vip/jiexi/` 正是这一层）。给到 3 跳够用，再多就是死循环了。
  static const int _maxChainDepth = 3;

  /// 抓 [url] 并从中挖媒体直链（递归）。
  Future<String?> _digUrl(
    Dio dio,
    String url,
    Map<String, String> headers,
    DateTime deadline,
    int depth,
  ) async {
    if (depth > _maxChainDepth) return null;
    final body = await _get(dio, url, headers, deadline);
    if (body == null) return null;
    return _digBody(dio, body, url, headers, deadline, depth);
  }

  /// 从一段响应正文里挖媒体直链（递归）。
  ///
  /// 顺序（每一层都一样）：
  ///   ① JSON 里的 `url` / `data.url` / `playUrl` —— **必须真的是媒体地址**，
  ///      不是就当成"下一页"继续挖；
  ///   ② 正文里直接出现的 m3u8/mp4；
  ///   ③ iframe 的 src / `?url=` 参数指向的下一页。
  Future<String?> _digBody(
    Dio dio,
    String body,
    String baseUrl,
    Map<String, String> headers,
    DateTime deadline,
    int depth,
  ) async {
    // ① 解析接口绝大多数返回 JSON：`{"url": "https://..."}` / `{"data":{"url":...}}`
    final fromJson = _mediaFromJson(body);
    if (fromJson != null) {
      if (MediaSniffer.isMediaUrl(fromJson)) return fromJson;
      // 返回的是**另一个网页**（壳页）→ 继续往下挖，别把它当播放地址
      if (depth < _maxChainDepth) {
        final deeper =
            await _digUrl(dio, fromJson, headers, deadline, depth + 1);
        if (deeper != null) return deeper;
      }
    }

    // ② 正文里直接有媒体地址（绝大多数 CMS 播放页 / 解析页的 HTML 内嵌 JSON）
    final direct = _pickBest(MediaSniffer.extractFromText(body));
    if (direct != null) return direct;

    // ③ 壳页面：跟 iframe / `?url=`
    if (depth >= _maxChainDepth) return null;
    final nested = _nestedTarget(body);
    if (nested == null || nested == baseUrl) return null;
    return _digUrl(dio, nested, headers, deadline, depth + 1);
  }

  /// ③ 走一条解析线路
  ///
  /// 2026-10-30 补了两个**实战必需的**细节：
  ///   ① 带上线路自己的请求头（`parses[].ext.header`）—— 不少接口按 UA
  ///      决定给不给地址，用默认 UA 请求只会拿回一个空白页；
  ///   ② 原样拼接失败后**再用编码后的地址试一次** —— TVBox 各分支对
  ///      `type=0` 的约定不统一，有的要 `?url=<原样>`，有的要 URL 编码，
  ///      只试一种会有一半接口用不了。
  Future<String?> _fromParseLine(
    Dio dio,
    ParseLine line,
    String pageUrl,
    Map<String, String> headers,
    DateTime deadline,
  ) async {
    // 线路自带的头优先（UA 之类必须覆盖，否则接口不认）
    final merged = <String, String>{...headers, ...line.headers};

    final raw = line.apply(pageUrl);
    final first = await _fromOneUrl(dio, raw, merged, deadline);
    if (first != null) return first;

    final encoded = line.applyEncoded(pageUrl);
    if (encoded == raw) return null;
    return _fromOneUrl(dio, encoded, merged, deadline);
  }

  /// 请求一个已拼好的解析地址，并从响应里挖出媒体直链。
  ///
  /// 走 [_digUrl] 而不是只取一次 `url` 字段：解析接口返回的往往还是
  /// **网页**（ckplayer / jiexi 这类壳），只取一次就会把网页当播放地址。
  Future<String?> _fromOneUrl(
    Dio dio,
    String target,
    Map<String, String> headers,
    DateTime deadline,
  ) =>
      _digUrl(dio, target, headers, deadline, 0);

  /// 从 JSON 响应里取 `url` / `data.url` / `playUrl`
  String? _mediaFromJson(String body) {
    final text = body.trim();
    if (!text.startsWith('{') && !text.startsWith('[')) return null;
    try {
      final decoded = jsonDecode(text);
      final candidate = _deepUrl(decoded, 0);
      if (candidate == null) return null;
      final url = _decodeEscaped(candidate);
      if (MediaSniffer.isMediaUrl(url)) return url;
      // 解析接口有时给的是"另一个解析页"，也当成可用结果交给上层
      if (url.startsWith('http')) return url;
    } catch (_) {}
    return null;
  }

  String? _deepUrl(Object? node, int depth) {
    if (depth > 4 || node == null) return null;
    if (node is String) return null;
    if (node is List) {
      for (final e in node) {
        final r = _deepUrl(e, depth + 1);
        if (r != null) return r;
      }
      return null;
    }
    if (node is Map) {
      for (final key in const ['url', 'playUrl', 'play_url', 'src', 'link']) {
        final v = node[key];
        if (v is String && v.trim().isNotEmpty) return v.trim();
      }
      for (final v in node.values) {
        final r = _deepUrl(v, depth + 1);
        if (r != null) return r;
      }
    }
    return null;
  }

  /// JSON 里常见 `https:\/\/a.b\/c.m3u8`，还原成正常地址
  String _decodeEscaped(String url) =>
      url.replaceAll(r'\/', '/').replaceAll(r'\u0026', '&').trim();

  /// 页面里的 iframe / `?url=` 目标
  String? _nestedTarget(String html) {
    final iframe = RegExp(
      r'''<iframe[^>]+src=["']([^"']+)["']''',
      caseSensitive: false,
    ).firstMatch(html);
    if (iframe != null) {
      final src = _decodeEscaped(iframe.group(1) ?? '');
      if (src.startsWith('http')) return src;
    }
    final param = RegExp(
      r'''(?:url|u|v|src)=([^&"'\s]+)''',
      caseSensitive: false,
    ).firstMatch(html);
    if (param != null) {
      var v = Uri.decodeComponent(_decodeEscaped(param.group(1) ?? ''));
      if (v.startsWith('http')) return v;
    }
    return null;
  }

  /// 候选里挑最优先的（m3u8 > mpd > mp4 > 其它）
  String? _pickBest(List<String> candidates) {
    if (candidates.isEmpty) return null;
    final ordered = [...candidates]
      ..sort((a, b) => MediaSniffer.score(a).compareTo(MediaSniffer.score(b)));
    return ordered.first;
  }

  Future<String?> _get(
    Dio dio,
    String url,
    Map<String, String> headers,
    DateTime deadline,
  ) async {
    final remaining = deadline.difference(DateTime.now());
    if (remaining.isNegative) return null;
    final timeout = remaining < _requestTimeout ? remaining : _requestTimeout;
    try {
      final resp = await dio.get<String>(
        url,
        options: Options(
          receiveTimeout: timeout,
          sendTimeout: timeout,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
                    'AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 '
                    'Mobile/15E148 Safari/604.1',
            ...headers,
          },
        ),
      );
      final data = resp.data;
      if (data == null) return null;
      return data;
    } catch (e) {
      AppLog.instance.log('[Resolve] 请求失败（继续下一条）: $url → $e');
      return null;
    }
  }
}

/// 「这次该嗅探哪个地址」的决策结果。
///
/// 普通播放页就是它自己；**平台页（爱奇艺 / 腾讯 / 优酷 / 芒果 / B站 /
/// PPTV）要先套一条解析线路**，嗅探的是线路页而不是平台页本身。
/// 详见 [MediaResolver.sniffTargetFor]。
class SniffTarget {
  const SniffTarget({
    required this.url,
    required this.label,
    this.headers = const {},
    this.viaParseLine = false,
  });

  /// 真正交给 WebView 的地址
  final String url;

  /// 给日志 / 界面看的一句话（`原页面` / `线路「xxx」`）
  final String label;

  /// 请求头。线路自带的 header 会覆盖调用方的 —— 不少接口按 UA
  /// 决定给不给地址，用默认 UA 请求只会拿回一个空白页。
  final Map<String, String> headers;

  /// 是否「套过解析线路」
  final bool viaParseLine;

  @override
  String toString() => 'SniffTarget($label → $url)';
}
