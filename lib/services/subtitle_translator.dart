import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'translate_service.dart';

/// 一条字幕（时间轴原样保留，只换文本）
class SubtitleCue {
  SubtitleCue({
    required this.index,
    required this.timecode,
    required this.text,
    this.start = Duration.zero,
    this.end = Duration.zero,
  });

  final String index;
  final String timecode;

  /// 起止时间 —— 供播放器自己叠字幕用（不依赖内核的外挂字幕能力）
  final Duration start;
  final Duration end;

  String text;
}

/// 字幕文件翻译结果
class SubtitleResult {
  SubtitleResult({
    required this.outputPath,
    required this.total,
    required this.translated,
    required this.skipped,
    required this.failed,
    required this.cues,
  });

  final String outputPath;
  final int total;
  final int translated;
  final int skipped;
  final int failed;

  /// 已回填译文的字幕行（播放器直接拿去叠在画面上）
  final List<SubtitleCue> cues;
}

/// 外挂字幕翻译（方案 A）
///
/// 设计要点：
///   · **时间轴一个字不动** —— 只替换文本，不会错位
///   · 已经是中文的行跳过，不浪费请求
///   · 相同文本只翻一次（字幕里重复句很多）
///   · 输出成 `xxx.zh.srt` / `xxx.zh.ass`，播一次再播直接用
class SubtitleTranslator {
  SubtitleTranslator._();

  /// 只解析、不翻译 —— 用来加载已经译好的 `xxx.zh.srt`
  static Future<List<SubtitleCue>> loadCues(String path) async {
    final f = File(path);
    if (!await f.exists()) throw '文件不存在：$path';
    final raw = await f.readAsString();
    final ext = _ext(path);
    return ext == 'ass' || ext == 'ssa' ? _parseAss(raw) : _parseSrt(raw);
  }

  /// `a.srt` → `a.zh.srt`
  static String outputPathFor(String path) => _outputPath(path, _ext(path));

  /// 翻译一个字幕文件。失败抛异常。
  ///
  /// [concurrency] 并发请求数（默认 3，别太高 —— Google 会 429）
  static Future<SubtitleResult> translateFile(
    String path, {
    int concurrency = 3,
    void Function(int done, int total)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final f = File(path);
    if (!await f.exists()) throw '文件不存在：$path';
    final raw = await f.readAsString();
    final ext = _ext(path);

    final cues = ext == 'ass' || ext == 'ssa'
        ? _parseAss(raw)
        : _parseSrt(raw);
    if (cues.isEmpty) throw '没解析出字幕行（格式不支持？）';

    // 需要翻译的文本去重（字幕里重复句很多）
    final need = <String>{};
    for (final c in cues) {
      final t = c.text.trim();
      if (t.isEmpty) continue;
      if (TranslateService.needsTranslation(t)) need.add(t);
    }
    final total = cues.length;
    var translated = 0;
    var skipped = 0;
    var failed = 0;

    final cache = <String, String>{};
    final queue = need.toList();

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        if (isCancelled?.call() == true) return;
        final t = queue.removeLast();
        try {
          cache[t] = await TranslateService.instance.toZh(t);
        } catch (e) {
          failed++;
          debugPrint('[Subtitle] 翻译失败: $e');
        }
      }
    }

    final workers = <Future<void>>[];
    for (var i = 0; i < concurrency.clamp(1, 6); i++) {
      workers.add(worker());
    }
    // 进度：按"已处理的唯一文本"上报
    final totalUnique = need.length;
    var processedUnique = 0;
    final progressTimer = _Ticker(() {
      processedUnique = cache.length + failed;
      if (totalUnique > 0) {
        onProgress?.call(
          (processedUnique * total) ~/ totalUnique,
          total,
        );
      }
    });
    progressTimer.start();
    await Future.wait(workers);
    progressTimer.stop();

    // 取消：**不落盘**，避免留下一个"半中半英"的字幕文件被当成成品复用
    if (isCancelled?.call() == true) throw '已取消';

    // 回填文本
    for (final c in cues) {
      final t = c.text.trim();
      if (t.isEmpty) continue;
      final zh = cache[t];
      if (zh == null) {
        skipped++;
        continue;
      }
      c.text = zh;
      translated++;
    }

    final outPath = _outputPath(path, ext);
    final out = ext == 'ass' || ext == 'ssa'
        ? _buildAss(raw, cues)
        : _buildSrt(cues);
    await File(outPath).writeAsString(out, flush: true);

    onProgress?.call(total, total);
    return SubtitleResult(
      outputPath: outPath,
      total: total,
      translated: translated,
      skipped: skipped,
      failed: failed,
      cues: cues,
    );
  }

  // ── SRT ────────────────────────────────────────────────
  static List<SubtitleCue> _parseSrt(String raw) {
    final text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final blocks = text.split(RegExp(r'\n{2,}'));
    final out = <SubtitleCue>[];
    for (final b in blocks) {
      final lines = b.split('\n').where((l) => l.trim().isNotEmpty).toList();
      if (lines.length < 2) continue;
      // 找时间轴行：00:00:01,000 --> 00:00:03,000
      var tcIndex = -1;
      for (var i = 0; i < lines.length && i < 3; i++) {
        if (lines[i].contains('-->')) {
          tcIndex = i;
          break;
        }
      }
      if (tcIndex < 0) continue;
      final idx = tcIndex > 0 ? lines[tcIndex - 1].trim() : '${out.length + 1}';
      final body = lines.sublist(tcIndex + 1).join('\n');
      final tc = lines[tcIndex].trim();
      final arrow = tc.split('-->');
      out.add(SubtitleCue(
        index: idx,
        timecode: tc,
        text: body,
        start: _timeOf(arrow.first) ?? Duration.zero,
        end: arrow.length > 1
            ? (_timeOf(arrow[1]) ?? Duration.zero)
            : Duration.zero,
      ));
    }
    return out;
  }

  static String _buildSrt(List<SubtitleCue> cues) {
    final b = StringBuffer();
    for (var i = 0; i < cues.length; i++) {
      final c = cues[i];
      b.writeln('${i + 1}');
      b.writeln(c.timecode);
      b.writeln(c.text.trim());
      b.writeln();
    }
    return b.toString();
  }

  // ── ASS / SSA ──────────────────────────────────────────
  static List<SubtitleCue> _parseAss(String raw) {
    final out = <SubtitleCue>[];
    final lines = raw.split('\n');
    for (final line in lines) {
      if (!line.startsWith('Dialogue:')) continue;
      // Dialogue: 0,0:00:01.00,0:00:03.00,Default,,0,0,0,,文本
      final parts = line.substring('Dialogue:'.length).split(',');
      if (parts.length < 10) continue;
      final text = parts.sublist(9).join(',');
      out.add(SubtitleCue(
        index: '${out.length + 1}',
        timecode: parts.sublist(1, 3).join('|'), // 仅用于回填定位
        text: text,
        start: _timeOf(parts[1]) ?? Duration.zero,
        end: _timeOf(parts[2]) ?? Duration.zero,
      ));
    }
    return out;
  }

  /// ASS 回填：按出现顺序逐条替换 Dialogue 行里的最后一个字段
  static String _buildAss(String raw, List<SubtitleCue> cues) {
    final lines = raw.split('\n');
    var i = 0;
    for (var n = 0; n < lines.length; n++) {
      final line = lines[n];
      if (!line.startsWith('Dialogue:')) continue;
      if (i >= cues.length) break;
      final head = line.substring('Dialogue:'.length);
      final parts = head.split(',');
      if (parts.length < 10) continue;
      parts[9] = cues[i].text;
      lines[n] = 'Dialogue:${parts.join(',')}';
      i++;
    }
    return lines.join('\n');
  }

  /// `00:00:01,000`（SRT，毫秒）/ `0:00:01.00`（ASS，百分秒）→ Duration
  static Duration? _timeOf(String raw) {
    final m = RegExp(r'(\d+):(\d{1,2}):(\d{1,2})[.,](\d{1,3})').firstMatch(raw);
    if (m == null) return null;
    final frac = m.group(4)!;
    final ms = switch (frac.length) {
      1 => int.parse(frac) * 100,
      2 => int.parse(frac) * 10,
      _ => int.parse(frac),
    };
    return Duration(
      hours: int.parse(m.group(1)!),
      minutes: int.parse(m.group(2)!),
      seconds: int.parse(m.group(3)!),
      milliseconds: ms,
    );
  }

  static String _ext(String path) {
    final i = path.lastIndexOf('.');
    return i < 0 ? 'srt' : path.substring(i + 1).toLowerCase();
  }

  static String _outputPath(String path, String ext) {
    final i = path.lastIndexOf('.');
    // 没有扩展名时不能按 ext.length 硬砍，否则会吃掉最后几个字符
    final base = i <= 0 ? path : path.substring(0, i);
    return '$base.zh.$ext';
  }
}

/// 进度节流器：每 250ms 回调一次，避免 setState 刷爆
class _Ticker {
  _Ticker(this.onTick);
  final VoidCallback onTick;
  Timer? _t;

  void start() {
    _t = Timer.periodic(const Duration(milliseconds: 250), (_) => onTick());
  }

  void stop() {
    _t?.cancel();
    _t = null;
  }
}
