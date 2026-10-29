// lib/services/play_pipeline.dart
//
// **统一播放管线** —— 详情页、海阔模块、小程序三处共用同一条取址链路。
//
// ── 为什么要有它（用户 2026-10-29 明确要求整体重构）──────────────
// 之前"直链判定 / 解析接口 / MIME 确认 / 转网页嗅探"这套逻辑在：
//   · `detail/controller.dart`（`_resolveSpiderPlayUrl` + `_startPlayback`，两份近似代码）
//   · `hiker/pages/hiker_detail_page.dart`（`_resolveAndPlay`）
//   · `miniapp/services/ant_bridge.dart`（`ant.player.open`）
// 各写一份，判据还出现了漂移（谁先补 Referer、谁做 MIME 确认、
// 谁把 `parse:0` 的无后缀直链当网页）。结果就是"同一个地址在影视端能播、
// 在海阔/小程序里黑屏"。
//
// 这里把链路收敛成**一条**，每一步的语义都固定：
//   ① 协议分流：`novel://` 正文、`pics://` 图片（阅读器，不是播放器）
//   ② 地址清洗：剥 `类型|哈希|真实URL` 包裹、相对地址按源站点 origin 补全
//   ③ 直链后缀命中 → 直接播放
//   ④ 需要解析（主流站 / 源声明 parse=1 / 用户强制）→ 解析接口；
//      手选线路失败自动回退全接口
//   ⑤ 仍不是媒体 → 交给 WebView 嗅探（由调用方决定内嵌还是嗅探页）
//
// 全链路**不抛异常**：任何一步失败都只是"这一层没命中"，继续下一层，
// 真原因写日志并回传给调用方（`PlayResolution.note`）。
library;

import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/parse_service.dart';
import 'package:tvbox/services/parse_store.dart';
import 'package:tvbox/services/play_route.dart';
import 'package:tvbox/services/play_url_sanitizer.dart';
import 'package:tvbox/services/player_prefs.dart';
import 'package:tvbox/services/sniff_filter.dart';

/// 取址结果的内容形态。
enum PlayKind {
  /// 可直接交给播放器（含无后缀但已由服务端确认的直链）
  media,

  /// 网页播放页 —— 交给内嵌 WebView / 嗅探页
  page,

  /// `novel://` 正文
  novel,

  /// `pics://` 图片列表
  pictures,
}

class PlayResolution {
  final String url;
  final PlayKind kind;
  final Map<String, String> headers;

  /// 命中的解析接口名（空 = 没过解析接口）
  final String parserName;

  /// 地址**没有**影视后缀，但已被 Content-Type / 首字节确认是媒体
  final bool mediaConfirmed;

  /// 链路说明 / 失败原因（用于日志与界面提示，可为空）
  final String note;

  const PlayResolution({
    required this.url,
    required this.kind,
    this.headers = const {},
    this.parserName = '',
    this.mediaConfirmed = false,
    this.note = '',
  });

  bool get isMedia => kind == PlayKind.media;
  bool get isPage => kind == PlayKind.page;

  PlayResolution copyWith({
    String? url,
    PlayKind? kind,
    Map<String, String>? headers,
    String? parserName,
    bool? mediaConfirmed,
    String? note,
  }) =>
      PlayResolution(
        url: url ?? this.url,
        kind: kind ?? this.kind,
        headers: headers ?? this.headers,
        parserName: parserName ?? this.parserName,
        mediaConfirmed: mediaConfirmed ?? this.mediaConfirmed,
        note: note ?? this.note,
      );
}

class PlayPipeline {
  PlayPipeline._();
  static final PlayPipeline instance = PlayPipeline._();

  /// 解析 [rawUrl]，返回最终该怎么播。
  ///
  /// [sourceWantsParse] 对应源 `playerContent` 里的 `parse:1` / `jx:1`；
  /// [sourceSaysDirect] 对应 `parse:0`（源明确声明"这是直链"，但地址可能没后缀）；
  /// [forceParse] 对应"用户在解析面板里主动选了线路"；
  /// [apiBase] 是源 api（相对播放地址按它的 origin 补全）；
  /// [refererPage] 是解析前的页面地址（V1 起不再做 MIME 确认，仅兼容保留）。
  Future<PlayResolution> resolve(
    String rawUrl, {
    Map<String, String>? headers,
    bool forceParse = false,
    bool allowParse = true,
    bool sourceWantsParse = false,
    bool sourceSaysDirect = false,
    String? apiBase,
    String? refererPage,
  }) async {
    final h = <String, String>{...?headers};
    final raw = rawUrl.trim();
    if (raw.isEmpty) {
      return PlayResolution(
        url: raw,
        kind: PlayKind.page,
        headers: h,
        note: '播放地址为空',
      );
    }

    // ① 非视频协议：漫画 / 小说（交给阅读器，不是播放器）
    final novel = parseNovelUrl(raw);
    if (novel != null && novel.content.trim().isNotEmpty) {
      return PlayResolution(url: raw, kind: PlayKind.novel, headers: h);
    }
    final pictures = parseImageListUrl(raw);
    if (pictures != null && pictures.isNotEmpty) {
      return PlayResolution(url: raw, kind: PlayKind.pictures, headers: h);
    }

    // ② 清洗 + 补全
    var candidate = sanitizePlayUrl(raw);
    candidate = absolutize(candidate, apiBase);

    // ③ 直链
    if (SniffFilter.isDirectMedia(candidate)) {
      AppLog.instance.log('[PlayPipeline] 直链: $candidate');
      return PlayResolution(url: candidate, kind: PlayKind.media, headers: h);
    }

    final canParse = allowParse &&
        (ParseService.instance.enabled || ParseService.instance.hasParsers);
    // 用户是否"强制用自己的线路"：主动选过线路，或关掉了"脚本内置解析优先"
    final userForced =
        forceParse || !PlayerPrefs.instance.preferScriptParse.value;
    final needParse = sourceWantsParse || forceParse || SniffFilter.shouldParse(candidate);

    var parserName = '';
    String? parseTarget;

    // ④ 解析接口
    if (needParse && canParse) {
      parseTarget = (sourceWantsParse || userForced)
          ? innerUrlOf(candidate)
          : candidate;
      try {
        final outcome = await _parse(parseTarget, forceParse: forceParse);
        if (outcome != null && outcome.url.isNotEmpty) {
          candidate = outcome.url;
          parserName = outcome.sourceName;
          // 解析接口自带的请求头要随播放一起带上；**源自己给的优先**（更具体）
          final oh = outcome.headers;
          if (oh != null && oh.isNotEmpty) {
            final merged = <String, String>{...oh, ...h};
            h
              ..clear()
              ..addAll(merged);
          }
          applyReferer(h, parseTarget);
          AppLog.instance.log(
              '[PlayPipeline] 「$parserName」解析 → $candidate'
              '（${outcome.direct ? '直链' : '仍为网页，继续嗅探'}）');
        } else {
          AppLog.instance.log('[PlayPipeline] 解析接口未命中，转嗅探');
        }
      } catch (e) {
        AppLog.instance.log('[PlayPipeline] 解析失败: $e');
      }
    }

    // 解析接口可能又给出一个带包裹格式的串（少数站会套娃）
    candidate = sanitizePlayUrl(candidate);

    // ⑤ 直链判定（V1：不再做 MIME 服务端确认）
    if (SniffFilter.isDirectMedia(candidate)) {
      AppLog.instance.log('[PlayPipeline] 直链: $candidate');
      return PlayResolution(
        url: candidate,
        kind: PlayKind.media,
        headers: h,
        parserName: parserName,
      );
    }

    // ⑥ 仍是网页 → 由调用方决定内嵌 WebView / 嗅探页
    AppLog.instance.log('[PlayPipeline] 网页地址 → 交由 WebView 嗅探: $candidate');
    return PlayResolution(
      url: candidate,
      kind: PlayKind.page,
      headers: h,
      parserName: parserName,
    );
  }

  /// 手选线路优先、失败自动回退全接口（原 `DetailController._tryParse` 的逻辑）。
  Future<ParseOutcome?> _parse(String target, {required bool forceParse}) async {
    if (!forceParse) return ParseService.instance.parseOutcome(target);
    final active = ParseStore.instance.activeBean;
    if (active == null) return ParseService.instance.parseOutcome(target);
    final first =
        await ParseService.instance.parseOutcome(target, only: active);
    if (first != null) return first;
    AppLog.instance.log('[PlayPipeline] 手选解析线「${active.name}」失败，自动回退全试');
    return ParseService.instance.parseOutcome(target);
  }

  /// 从解析站地址里取出内层原始地址（`?url=` / `?v=`），取不到原样返回。
  static String innerUrlOf(String url) {
    try {
      final uri = Uri.tryParse(url.trim());
      if (uri == null) return url;
      for (final k in const ['url', 'v', 'vid', 'link', 'u']) {
        final inner = uri.queryParameters[k];
        if (inner != null && inner.trim().isNotEmpty) {
          final v = inner.trim();
          if (v.startsWith('http://') || v.startsWith('https://')) return v;
        }
      }
    } catch (_) {}
    return url;
  }

  /// 相对播放地址按源站点的 **origin** 补全（TVBox 既有约定）。
  ///
  /// 必须取 origin 而不是 api 目录：实测按目录会拼出
  /// `/api/tvbox/source/vodplay/223052-1-1.html`（错），按 origin 才对。
  static String absolutize(String raw, String? apiBase) {
    final s = raw.trim();
    if (s.isEmpty || isPlayableShape(s)) return s;
    final base = (apiBase ?? '').trim();
    if (base.isEmpty) return s;
    final bu = Uri.tryParse(base);
    if (bu == null || !bu.hasScheme) return s;
    try {
      final origin = '${bu.scheme}://${bu.authority}/';
      final fixed = Uri.parse(origin).resolve(s).toString();
      if (fixed != s) {
        AppLog.instance.log('[PlayPipeline] 相对地址补全: $s → $fixed（$origin）');
      }
      return fixed;
    } catch (_) {
      return s;
    }
  }

  /// 是否"能交给播放器"的地址形态（有 scheme，含内容协议）。
  ///
  /// 裸相对路径（`vodplay/223052-1-1.html`）不能交给播放器：原生播放器会
  /// `Operation Stopped`，而 UI 又收不到错误，只能白卡到超时。
  static bool isPlayableShape(String url) {
    final raw = url.trim();
    if (raw.isEmpty) return false;
    final lower = raw.toLowerCase();
    for (final p in kPlayablePrefixes) {
      if (lower.startsWith(p)) return true;
    }
    final u = Uri.tryParse(raw);
    return u != null && u.hasScheme;
  }

  /// 「播放带 Referer」开关打开时，用解析前的原始页面补一次 Referer。
  static void applyReferer(Map<String, String> headers, String pageUrl) {
    if (!PlayerPrefs.instance.sniffSendReferer.value) return;
    final page = pageUrl.trim();
    if (page.isEmpty) return;
    headers.putIfAbsent('Referer', () => page);
  }

  static const List<String> kPlayablePrefixes = [
    'http://', 'https://', 'rtmp://', 'rtsp://', 'mms://',
    'x5://', 'novel://', 'pics://', 'mange://', 'manga://',
    'magnet:', 'ed2k://', 'thunder://', 'ftp://', 'file://',
  ];
}
