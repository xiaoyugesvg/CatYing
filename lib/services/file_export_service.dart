import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 导出已下载的本地文件：交给系统分享面板（iOS `UIActivityViewController`）。
///
/// - 文件本身就在 App 沙盒 `Documents/` 下（Info.plist 已开启
///   `UIFileSharingEnabled`，可在「文件」App → 我的 iPhone → 猫影 里直接看到）。
/// - 目录（如一本漫画的多话图片）先打成 ZIP 再分享，避免分享面板里出现
///   几百个散图。
/// - 原生通道缺失（Android / 桌面）时返回 false，由调用方给出提示，不抛异常。
class FileExportService {
  FileExportService._();

  static const _channel = MethodChannel('tvbox/file_export');

  /// 调起系统分享面板。返回是否成功拉起。
  static Future<bool> shareFiles(List<String> paths) async {
    final valid = <String>[];
    for (final p in paths) {
      if (p.isEmpty) continue;
      try {
        if (FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound) {
          valid.add(p);
        }
      } catch (_) {}
    }
    if (valid.isEmpty) return false;
    try {
      final r = await _channel.invokeMethod<bool>('share', {'paths': valid});
      return r ?? false;
    } on PlatformException catch (e) {
      debugPrint('[FileExport] 分享失败: $e');
      return false;
    } on MissingPluginException {
      // Android / 桌面没有注册该通道
      return false;
    }
  }

  /// 把目录压缩成 ZIP（默认放在临时目录），返回 zip 路径；失败返回 null。
  ///
  /// [outputDir] 仅测试用（默认系统临时目录）。
  static Future<String?> zipDirectory(
    Directory dir, {
    String? archiveName,
    Directory? outputDir,
  }) async {
    try {
      if (!await dir.exists()) return null;
      final tmp = outputDir ?? await getTemporaryDirectory();
      final stamp = DateTime.now().millisecondsSinceEpoch;
      final outDir = Directory('${tmp.path}/export_$stamp');
      await outDir.create(recursive: true);
      final rawName = (archiveName == null || archiveName.trim().isEmpty)
          ? dir.path.split(RegExp(r'[/\\]')).last
          : archiveName.trim();
      final name = _safeName(rawName);
      final outPath =
          '${outDir.path}${Platform.pathSeparator}$name.zip';
      final encoder = ZipFileEncoder();
      await encoder.zipDirectoryAsync(dir, filename: outPath);
      return outPath;
    } catch (e) {
      debugPrint('[FileExport] 压缩失败: $e');
      return null;
    }
  }

  /// 压缩目录后分享（一本漫画 = 一个 ZIP）。
  static Future<bool> shareDirectory(
    Directory dir, {
    String? archiveName,
  }) async {
    final zip = await zipDirectory(dir, archiveName: archiveName);
    if (zip == null) return false;
    return shareFiles([zip]);
  }

  /// 文件名净化：去掉路径分隔符与文件系统敏感字符，限长。
  static String _safeName(String s) {
    var name = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
    name = name.replaceAll(RegExp(r'[.\s]+$'), '');
    if (name.isEmpty) name = 'export';
    if (name.length > 80) name = name.substring(0, 80);
    return name;
  }
}
