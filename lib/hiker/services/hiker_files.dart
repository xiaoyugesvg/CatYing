import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/hiker/services/hiker_store.dart';

/// 文件区里的一个文件
typedef HikerFileEntry = ({String path, int size});

/// 「海阔」的**文件区**：`<Documents>/hiker/files`
///
/// ── 为什么需要它（实测依据）────────────────────────────────────────
/// 规则里的 `hiker://files/*` 读的就是这里。拿 115 个源统计，`hiker://files/`
/// 一共出现 **387 次**：`rules/` 38、`rules/Apollo/*` 38、`libs/` 13、
/// `data/` 12、`icon/` 9、`cache/` 9…
/// 最典型的是 **Apollo 规则包** —— 它**不在海阔 App 里**（我核对过官方源码的
/// `app/src/main/assets`，没有 Apollo），原版海阔同样要用户自己导入。
/// 所以这里提供"导入 zip / 放单文件"的入口：铺进去，那批源就能跑。
///
/// 路径安全：所有写操作都收敛在本目录内（zip 条目里的 `../` 一律拒绝），
/// 与 Node 侧 `safePath()` 的口径一致。
class HikerFiles {
  HikerFiles._();

  /// 文件区根目录（不存在则创建）
  static Future<Directory?> dir() async {
    try {
      final root = await HikerStore.rootDir();
      if (root == null) return null;
      final d = Directory('${root.path}/files');
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    } catch (e) {
      AppLog.instance.log('[Hiker] 取文件区失败: $e');
      return null;
    }
  }

  /// 递归列出文件（相对路径 + 字节数），路径升序
  static Future<List<HikerFileEntry>> list() async {
    final d = await dir();
    if (d == null) return const [];
    final out = <HikerFileEntry>[];
    try {
      final prefix = d.path.endsWith(Platform.pathSeparator)
          ? d.path
          : '${d.path}${Platform.pathSeparator}';
      await for (final e in d.list(recursive: true, followLinks: false)) {
        if (e is! File) continue;
        try {
          final st = await e.stat();
          out.add((path: e.path.substring(prefix.length), size: st.size));
        } catch (_) { /* 单个文件取不到就跳过 */ }
      }
    } catch (e) {
      AppLog.instance.log('[Hiker] 列文件区失败: $e');
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// 文件数 + 总字节数
  static Future<(int, int)> stats() async {
    final l = await list();
    var bytes = 0;
    for (final e in l) {
      bytes += e.size;
    }
    return (l.length, bytes);
  }

  /// 写入一个文件（自动建目录）。返回是否成功。
  static Future<bool> putBytes(String relPath, Uint8List bytes) async {
    final f = await _safeFile(relPath);
    if (f == null) return false;
    try {
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
      return true;
    } catch (e) {
      AppLog.instance.log('[Hiker] 写文件区失败（$relPath）: $e');
      return false;
    }
  }

  /// 解压 zip 到文件区（保持内部目录结构）。
  ///
  /// 返回 `(写入数, 跳过数)`；跳过的是目录项与**路径越界**的条目（zip-slip）。
  static Future<(int, int)> importZip(Uint8List bytes) async {
    final d = await dir();
    if (d == null) return (0, 0);
    var written = 0;
    var skipped = 0;
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final zf in archive) {
        if (!zf.isFile) {
          skipped++;
          continue;
        }
        // zip 里可能是 Windows 路径 / 带前导斜杠 → 统一成相对路径
        final rel = zf.name.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '');
        final target = await _safeFile(rel);
        if (target == null) {
          skipped++;
          continue;
        }
        final data = zf.content;
        final zb = data is Uint8List
            ? data
            : Uint8List.fromList(List<int>.from(data as List));
        await target.parent.create(recursive: true);
        await target.writeAsBytes(zb, flush: true);
        written++;
      }
    } catch (e) {
      AppLog.instance.log('[Hiker] 解压失败: $e');
      rethrow;
    }
    return (written, skipped);
  }

  static Future<void> delete(String relPath) async {
    final f = await _safeFile(relPath);
    if (f == null) return;
    try {
      if (await f.exists()) await f.delete();
    } catch (e) {
      AppLog.instance.log('[Hiker] 删文件失败（$relPath）: $e');
    }
  }

  /// 清空文件区（**含用户导入的规则包**，调用方必须二次确认）
  static Future<void> clearAll() async {
    final d = await dir();
    if (d == null) return;
    try {
      await for (final e in d.list()) {
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (e) {
      AppLog.instance.log('[Hiker] 清空文件区失败: $e');
    }
  }

  /// 常用目录（按实测引用频次给快捷创建：rules / libs / data / icon / cache）
  static const List<String> commonDirs = ['rules', 'libs', 'data', 'icon', 'cache'];

  /// 把相对路径收敛到文件区内；越界（`../`、绝对路径）返回 null
  static Future<File?> _safeFile(String relPath) async {
    final d = await dir();
    if (d == null) return null;
    final rel = relPath.replaceAll('\\', '/').replaceFirst(RegExp(r'^/+'), '').trim();
    if (rel.isEmpty) return null;
    final root = d.path.endsWith(Platform.pathSeparator)
        ? d.path
        : '${d.path}${Platform.pathSeparator}';
    // 逐段过滤 `.` / `..`：`..` 直接拒绝（不做"归一化后仍在根内"的宽容处理，
    // 因为规则包里的 `..` 没有正当用途）
    final parts = <String>[];
    for (final seg in rel.split('/')) {
      if (seg.isEmpty || seg == '.') continue;
      if (seg == '..') return null;
      parts.add(seg);
    }
    if (parts.isEmpty) return null;
    final path = '$root${parts.join(Platform.pathSeparator)}';
    if (!path.startsWith(root)) return null;
    return File(path);
  }
}
