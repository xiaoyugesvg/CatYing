// 守卫测试：源缓存丢失时不许让用户干等 60 秒。
//
// ── 现场（`app_2026-10-31(10).log`）─────────────────────────────
// 连着 3 次前台恢复，每次都是同一串：
//   ```
//   GET  /source/status  → 200 {"sourceLoaded":false,"spiderPort":0}
//   POST /source/loadPath → 500 Cannot find module
//        '.../Documents/nodejs-project/src/source/cache_b0c089a06983f1bd87e1/index.js'
//   recover_attempt 1..6（每 10s 一次，全失败）
//   recover_all_fail → 弹「Node.js 重启失败」
//   ```
// 合计 3 × 60 秒，用户什么都做不了。
//
// 真实原因不是 Node 挂了，而是**源缓存目录里的 index.js 没了**（App 升级 /
// 系统清理 / 换源写到别的槽位）。这种失败重试一万次也是同一个 500，
// 唯一有效的动作是「重新下载源」或「重新选源」。
//
// `_recoverSpiderPort` 早就判了 `index.js` 在不在，但 `reloadSourceViaManagementPort`
// 没有 —— 而日志里走的是后者。这条测试盯着这个判断别再被删掉。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String relative) => File(relative).readAsStringSync();

String _stripComments(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  return noBlock
      .split('\n')
      .map((line) {
        final i = line.indexOf('//');
        return i < 0 ? line : line.substring(0, i);
      })
      .join('\n');
}

void main() {
  group('源缓存丢失要立刻报，不许白等', () {
    test('reload 前先判 index.js 存在', () {
      final src = _stripComments(_read('lib/services/nodejs_manager.dart'));
      final i = src.indexOf('Future<bool> reloadSourceViaManagementPort(');
      expect(i, greaterThan(-1));
      final body = src.substring(i, i + 2200);
      expect(
        body.contains("File('\$sourcePath/index.js').exists()"),
        isTrue,
        reason: '目录里没有 index.js 时 Node 必然 500 `Cannot find module`，'
            '必须 POST 之前就挡掉',
      );
      expect(
        body.contains('_sourceCacheMissing = true'),
        isTrue,
        reason: '要把「缓存丢了」这个事实传给上层，否则上层还在傻等',
      );
      // 判断必须在 POST 之前：先 POST 再判等于没省时间
      final checkIdx = body.indexOf("File('\$sourcePath/index.js')");
      final postIdx = body.indexOf('dio.post(');
      expect(
        checkIdx < postIdx,
        isTrue,
        reason: '存在性检查必须排在 POST 之前，否则那一次 500 白打了',
      );
    });

    test('缓存丢失时跳过 6×10s 长重试', () {
      final src = _stripComments(_read('lib/services/scene_recovery.dart'));
      expect(
        src.contains('sourceCacheMissing'),
        isTrue,
        reason: '上层不看这个标记，就还是会走满 60 秒',
      );
      final skipIdx = src.indexOf('sourceCacheMissing');
      final recoverIdx = src.indexOf('_recoverSpiderService(cid)');
      expect(
        skipIdx < recoverIdx,
        isTrue,
        reason: '「跳过」判断必须在调用长重试**之前**',
      );
      expect(
        src.contains('index.js'),
        isTrue,
        reason: '失败文案要说清楚是源文件丢了，'
            '不能只说「Node.js 重启失败」（用户会以为要重装 App）',
      );
    });

    test('重新下载源成功后清掉「缓存丢失」标记', () {
      final src = _stripComments(_read('lib/services/scene_recovery.dart'));
      expect(
        src.contains('clearSourceCacheMissing'),
        isTrue,
        reason: '重下成功但端口没回来时，标记还留着会把后面误判成「源丢了」',
      );
    });

    test('拿不到重下地址时要写日志（别静默 return false）', () {
      final src = _stripComments(_read('lib/services/scene_recovery.dart'));
      final i = src.indexOf('Future<bool> _tryRedownloadSource(');
      final body = src.substring(i, i + 1600);
      expect(
        body.contains('拿不到地址'),
        isTrue,
        reason: '静默 false 在日志里完全看不出「为什么没去重下」，'
            '排查时只能猜',
      );
    });
  });
}
