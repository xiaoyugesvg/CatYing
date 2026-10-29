import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// m3u8 **分片级**去广告（插播片段过滤）。
///
/// ── 为什么需要它（与已有两层去广告的分工）────────────────────────
///   · `AdBlockService`：**网页层** —— 注入 CSS 把广告元素隐藏掉；
///   · `AdFilterService`：**地址层** —— host 黑名单 + 正则拦截/重写；
///   · 本文件：**媒体层** —— 播放列表里被塞进来的「广告分片」。
///
/// 前两层都拦不住第三种：正片是 A 站的分片，广告却是从 B 站/另一个目录
/// 插进来的几十秒切片，URL 既不在黑名单里、也不是网页元素。
///
/// ── 判定算法（移植自 huoyi 的 nativeFilterAdSegments）──────────
///   1. 只在**媒体清单**（含 `#EXTINF`）上动手；master 多码率清单原样放行
///      （由上层逐变体各自处理）；
///   2. 给每个分片算「来源指纹」= host + 目录（丢文件名与 query，同目录视为同源）；
///   3. 取出现最多的指纹当「主指纹」；若占比 < 40% ⇒ 结构不可信
///      （多半只是切片命名差异，不是插播），**放弃清洗**；
///   4. 丢掉指纹 ≠ 主指纹的分片，并回收它前面的分片级标签
///      （`#EXTINF` / `#EXT-X-BYTERANGE` / `#EXT-X-KEY` / `#EXT-X-DISCONTINUITY`）。
///
/// ⚠️ 三条保命线（都来自参考实现的踩坑）：
///   · 播放列表级头部标签（VERSION / TARGETDURATION / MEDIA-SEQUENCE /
///     PLAYLIST-TYPE / MAP…）**绝不能删** —— 贴片广告的头部就挂在第一个
///     分片前面，误删会让整份清单失效、直接黑屏；
///   · 清洗后若一个 `#EXTINF` 都不剩 ⇒ 回退原文（宁可不删也不黑屏）；
///   · 纯前置贴片（整段同来源）无法与正片区分，**不猜删**。
class M3u8AdFilter {
  M3u8AdFilter._();

  static const String prefsKey = 'm3u8_ad_filter_v1';

  /// 开关（默认开：只有真的删掉分片才会生效，删不掉时与关闭无差别）
  static final ValueNotifier<bool> enabled = ValueNotifier(true);

  static Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled.value = prefs.getBool(prefsKey) ?? true;
    } catch (_) {
      // 读不到就保持默认（开）
    }
  }

  static Future<void> setEnabled(bool v) async {
    enabled.value = v;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(prefsKey, v);
    } catch (_) {}
  }

  static final RegExp _masterVariantTag = RegExp(
    r'^#EXT-X-(STREAM-INF|MEDIA:|I-FRAME-STREAM-INF|IMAGE-STREAM-INF)',
    caseSensitive: false,
  );
  static final RegExp _segmentTag = RegExp(
    r'^#EXTINF:',
    caseSensitive: false,
  );
  static final RegExp _adTagLine = RegExp(
    r'^#EXT(INF:|-X-(BYTERANGE|KEY|DISCONTINUITY))',
    caseSensitive: false,
  );

  /// 清洗媒体清单。返回 `removed == 0` 时 [text] 就是原文。
  static ({String text, int removed}) filter(String text, String baseUrl) {
    if (text.isEmpty) return (text: text, removed: 0);
    final normalized = text.replaceAll('\r\n', '\n');
    final lines = normalized.split('\n');
    if (lines.isEmpty || lines.first.trim() != '#EXTM3U') {
      return (text: text, removed: 0);
    }

    final baseFp = _hostDirOf(Uri.tryParse(baseUrl)) ?? '-';
    final comments = <int>[];
    final segmentComments = <List<int>>[];
    final segmentUris = <int>[];
    final segmentFps = <String>[];
    var sawExtInf = false;

    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.isEmpty) continue;
      if (t.startsWith('#')) {
        if (_masterVariantTag.hasMatch(t)) {
          // master 清单：不改写
          return (text: text, removed: 0);
        }
        if (_segmentTag.hasMatch(t)) sawExtInf = true;
        comments.add(i);
        continue;
      }
      // 分片 URI 行
      if (!sawExtInf) {
        // 没有任何分片级标注 ⇒ 不是媒体清单
        return (text: text, removed: 0);
      }
      final fp = _lineFingerprint(t, baseUrl, baseFp);
      segmentComments.add(List<int>.of(comments));
      segmentUris.add(i);
      segmentFps.add(fp.isEmpty ? baseFp : fp);
      comments.clear();
    }

    if (segmentUris.length < 2) return (text: text, removed: 0);

    // 主指纹 = 出现最多的来源
    final counts = <String, int>{};
    for (final fp in segmentFps) {
      counts[fp] = (counts[fp] ?? 0) + 1;
    }
    var dominant = '';
    var dominantCount = 0;
    counts.forEach((fp, c) {
      if (c > dominantCount) {
        dominant = fp;
        dominantCount = c;
      }
    });
    if (dominant.isEmpty ||
        dominantCount / segmentUris.length < 0.4) {
      // 结构不可信：不猜删
      return (text: text, removed: 0);
    }

    final remove = <int>{};
    var removed = 0;
    for (var s = 0; s < segmentUris.length; s++) {
      if (segmentFps[s] == dominant) continue;
      removed++;
      remove.add(segmentUris[s]);
      // 从最靠近分片的注释行往上回溯：
      //   命中分片级标签 → 删；普通 # 注释 → 保留但继续；其它 #EXT 头部 → 停。
      final cms = segmentComments[s];
      for (var k = cms.length - 1; k >= 0; k--) {
        final line = lines[cms[k]].trim();
        if (_adTagLine.hasMatch(line)) {
          remove.add(cms[k]);
          continue;
        }
        if (line.startsWith('#') && !line.startsWith('#EXT')) {
          continue;
        }
        break;
      }
    }

    if (removed == 0 || removed >= segmentUris.length) {
      return (text: text, removed: 0);
    }

    final out = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      if (remove.contains(i)) continue;
      out.write(lines[i]);
      if (i != lines.length - 1) out.write('\n');
    }
    final cleaned = out.toString();
    if (!cleaned.contains('#EXTINF')) {
      // 极端情况：全删干净了 ⇒ 回退原文
      return (text: text, removed: 0);
    }
    return (text: cleaned, removed: removed);
  }

  /// 一行 URI 的来源指纹：绝对地址用自身，相对地址解析到主清单后取。
  static String _lineFingerprint(String ref, String baseUrl, String baseFp) {
    final r = ref.trim();
    if (r.isEmpty || r.startsWith('data:')) return '';
    final parsed = Uri.tryParse(r);
    if (parsed == null) return '';
    if (parsed.hasScheme && parsed.host.isNotEmpty) {
      return _hostDirOf(parsed) ?? '';
    }
    final base = Uri.tryParse(baseUrl);
    if (base == null) return baseFp;
    try {
      return _hostDirOf(base.resolveUri(parsed)) ?? baseFp;
    } catch (_) {
      return baseFp;
    }
  }

  /// host + 目录（丢文件名与 query；同目录视为同源）
  static String? _hostDirOf(Uri? uri) {
    if (uri == null || uri.host.isEmpty) return null;
    final path = uri.path.toLowerCase();
    final slash = path.lastIndexOf('/');
    final dir = slash >= 0 ? path.substring(0, slash) : '';
    return '${uri.host.toLowerCase()}|$dir';
  }
}
