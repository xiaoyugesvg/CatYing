import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../models/third_party_source.dart';
import 'music_api.dart';

/// 音源解析结果
class SourceResolveResult {
  final bool ok;
  final String url;
  final String error;

  /// 'keyword' = 模板法；'script' = 脚本法
  final String kind;

  /// 命中它的那个音源（用于提示"由 XX 音源提供"）
  final ThirdPartySource? source;

  const SourceResolveResult({
    required this.ok,
    this.url = '',
    this.error = '',
    this.kind = '',
    this.source,
  });
}

/// 第三方音源解析服务 —— 对应 Beans 的 `UnblockService.swift`。
///
/// ── 职责边界（重要）───────────────────────────────────────────
/// Dart 侧负责：
///   · 从 [ThirdPartySourceStore] 取**已启用**的音源
///   · 按顺序逐个试，记录每个的失败原因
///   · 决定"内置接口失败后要不要回退到音源"
/// Node 侧负责**纯解析**（模板填充 / 脚本沙箱执行）。
///
/// 这样音源列表的**唯一事实来源是 Dart**，Node 不囤一份，
/// 不会出现两边不一致的问题。
///
/// ── 为什么要逐个试而不是选一个 ────────────────────────────────
/// 用户导入的源质量参差，第一个可能正好挂了。全试一遍的成本可控
/// （每个超时 12s，但正常的几十毫秒就回来了），换来的是"可用率高很多"。
/// 顺序按用户导入顺序，前面的是他更信任的。
class UnblockService {
  UnblockService._();
  static final UnblockService instance = UnblockService._();

  /// 单个音源的解析在 Node 侧也有超时，这里只做整体上限保护
  static const _maxTries = 8;

  /// 最近一次解析的逐条失败原因（给"为什么都失败了"提供依据）
  final lastAttempts = <String>[];

  /// 用已启用的第三方音源解析播放地址。
  ///
  /// [onProgress] 用于 UI 显示"正在试第 N 个音源"，因为逐个试可能要几秒，
  /// 不反馈用户会以为卡住了。
  Future<SourceResolveResult> resolve(
    Song song, {
    void Function(int index, int total, String sourceName)? onProgress,
  }) async {
    lastAttempts.clear();

    final sources = ThirdPartySourceStore.instance.enabled;
    if (sources.isEmpty) {
      return const SourceResolveResult(ok: false, error: '没有启用中的音源');
    }

    final list = sources.take(_maxTries).toList();
    for (var i = 0; i < list.length; i++) {
      final s = list[i];
      onProgress?.call(i + 1, list.length, s.name);
      try {
        final r = await MusicApi.instance.resolveBySource(s, song);
        if (r.ok && r.url.isNotEmpty) {
          return SourceResolveResult(
            ok: true,
            url: r.url,
            kind: r.kind,
            source: s,
          );
        }
        // 记下每个源的失败原因 —— 全失败时一起展示，
        // 用户才知道是哪个源坏了、坏在哪
        lastAttempts.add('${s.name}：${r.message.isEmpty ? "未返回地址" : r.message}');
      } catch (e) {
        lastAttempts.add('${s.name}：$e');
      }
    }

    return SourceResolveResult(
      ok: false,
      error: lastAttempts.isEmpty ? '所有音源都没解析出播放地址' : '所有音源都失败了',
    );
  }

  /// 只试某一个音源（音源管理页的"测试"按钮用）
  Future<SourceResolveResult> testOne(ThirdPartySource s, Song song) async {
    try {
      final r = await MusicApi.instance.resolveBySource(s, song);
      if (r.ok && r.url.isNotEmpty) {
        return SourceResolveResult(ok: true, url: r.url, kind: r.kind, source: s);
      }
      return SourceResolveResult(
        ok: false,
        error: r.message.isEmpty ? '未返回播放地址' : r.message,
        kind: r.kind,
      );
    } catch (e) {
      return SourceResolveResult(ok: false, error: '$e');
    }
  }

  /// 汇总失败原因（给 UI 一行显示，太长就截断）
  String describeFailure() {
    if (lastAttempts.isEmpty) return '';
    debugPrint('[Unblock] 逐个失败原因:\n${lastAttempts.join('\n')}');
    if (lastAttempts.length == 1) return lastAttempts.first;
    return '试了 ${lastAttempts.length} 个音源都没成功';
  }
}
