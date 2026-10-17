import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// OCR 识别出的一个文本块（坐标都是 **0~1 归一化**，原点左上）。
class OcrBlock {
  const OcrBlock({
    required this.text,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.confidence = 0,
  });

  final String text;
  final double x;
  final double y;
  final double w;
  final double h;
  final double confidence;

  factory OcrBlock.fromMap(Map<dynamic, dynamic> m) => OcrBlock(
        text: (m['text'] ?? '').toString(),
        x: (m['x'] as num?)?.toDouble() ?? 0,
        y: (m['y'] as num?)?.toDouble() ?? 0,
        w: (m['w'] as num?)?.toDouble() ?? 0,
        h: (m['h'] as num?)?.toDouble() ?? 0,
        confidence: (m['confidence'] as num?)?.toDouble() ?? 0,
      );
}

/// 本机 OCR（iOS = Apple Vision，走 `tvbox/ocr` 方法通道）。
///
/// 不依赖任何第三方模型/服务，离线可用；返回的坐标能直接用来把译文
/// 盖回原图（漫画气泡 / 影视字幕都是这个思路）。
class OcrService {
  OcrService._();

  static const MethodChannel _channel = MethodChannel('tvbox/ocr');

  /// 当前平台是否支持本机 OCR（目前只有 iOS 实现了原生侧）
  static bool get isAvailable => Platform.isIOS;

  /// 识别一张图片。
  ///
  /// [languages] 是 Vision 的语言优先级（`zh-Hans` / `zh-Hant` / `ja-JP` /
  /// `ko-KR` / `en-US`），传得越靠前越优先。
  static Future<List<OcrBlock>> recognize(
    Uint8List bytes, {
    List<String> languages = const ['zh-Hans', 'ja-JP', 'en-US', 'ko-KR'],
  }) async {
    if (!isAvailable || bytes.isEmpty) return const [];
    try {
      final raw = await _channel.invokeMethod<List<dynamic>>('recognize', {
        'bytes': bytes,
        'languages': languages,
      });
      if (raw == null) return const [];
      final out = <OcrBlock>[];
      for (final e in raw) {
        if (e is Map) {
          final b = OcrBlock.fromMap(e);
          if (b.text.trim().isNotEmpty) out.add(b);
        }
      }
      return out;
    } catch (_) {
      // 通道没注册 / 系统版本不支持：当作"识别不出文字"，不打断阅读
      return const [];
    }
  }

  /// 语言代码 → Vision 语言标识（按顺序给优先级）。
  static List<String> visionLanguages(String source) {
    switch (source) {
      case 'ja':
        return const ['ja-JP', 'en-US'];
      case 'ko':
        return const ['ko-KR', 'en-US'];
      case 'en':
        return const ['en-US'];
      case 'zh':
      case 'zh-CN':
        return const ['zh-Hans', 'zh-Hant', 'en-US'];
      case 'zh-TW':
        return const ['zh-Hant', 'zh-Hans', 'en-US'];
      default:
        return const ['ja-JP', 'ko-KR', 'zh-Hans', 'zh-Hant', 'en-US'];
    }
  }

  /// 按阅读顺序排序：从上到下；同一行（纵向重叠 > 50%）从左到右。
  ///
  /// 竖排日漫是"从右往左"，但文字块通常一列一个，纵向位置差更大，
  /// 所以这里先用"行"聚类，再在行内按 x 排，已经足够稳定。
  static List<OcrBlock> sortReadingOrder(List<OcrBlock> blocks) {
    final list = List<OcrBlock>.from(blocks);
    list.sort((a, b) => a.y.compareTo(b.y));
    final rows = <List<OcrBlock>>[];
    for (final b in list) {
      List<OcrBlock>? row;
      for (final r in rows) {
        final cy = r.first.y + r.first.h / 2;
        if ((cy - (b.y + b.h / 2)).abs() <
            (r.first.h + b.h) / 2 * 0.5) {
          row = r;
          break;
        }
      }
      if (row != null) {
        row.add(b);
      } else {
        rows.add([b]);
      }
    }
    final out = <OcrBlock>[];
    for (final r in rows) {
      r.sort((a, b) => a.x.compareTo(b.x));
      out.addAll(r);
    }
    return out;
  }
}
