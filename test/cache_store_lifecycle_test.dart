// CacheStore 的 flush / close 语义（"Hive box 只开不关"的补齐）。
//
// ⚠️ 本文件内的 test **按声明顺序执行**，且共用同一个 CacheStore 单例 +
//    同一个 Hive 目录 —— 因为 Hive 的箱是进程级全局状态。
//    "关闭后"的用例必须放在最后，否则会把后续用例的箱关掉。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:tvbox/models/cache_store.dart';

void main() {
  late Directory tmp;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('cachestore_test_');
    Hive.init(tmp.path);
    await CacheStore.instance.init();
  });

  tearDownAll(() async {
    await CacheStore.instance.close();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  test('init 后三个箱都已打开', () {
    expect(CacheStore.instance.isClosed, isFalse);
    expect(Hive.isBoxOpen('vod_collects'), isTrue);
    expect(Hive.isBoxOpen('vod_records'), isTrue);
    expect(Hive.isBoxOpen('cache_items'), isTrue);
  });

  test('写入后可读回（并行开箱不影响读写）', () async {
    await CacheStore.instance.setCacheItem('k1', 'v1');
    expect(CacheStore.instance.getCacheItem('k1'), 'v1');
    expect(CacheStore.instance.cacheItemsCount(), 1);
  });

  test('flush 幂等且不破坏可读性', () async {
    await CacheStore.instance.flush();
    await CacheStore.instance.flush();
    expect(CacheStore.instance.getCacheItem('k1'), 'v1');
  });

  test('close 后：幂等、不抛异常', () async {
    await CacheStore.instance.close();
    expect(CacheStore.instance.isClosed, isTrue);
    // 第二次 close 必须直接返回，不能抛
    await CacheStore.instance.close();
    await CacheStore.instance.close();
    expect(CacheStore.instance.isClosed, isTrue);
  });

  test('close 后：三个箱真的关了', () {
    expect(Hive.isBoxOpen('vod_collects'), isFalse);
    expect(Hive.isBoxOpen('vod_records'), isFalse);
    expect(Hive.isBoxOpen('cache_items'), isFalse);
  });

  test('close 后：写入静默跳过、读取返回空，全部不抛', () async {
    // 这些调用原来在箱关闭后会抛 "Box has already been closed"，
    // 现在必须安静返回 —— 退出流程里没人接得住那个异常。
    await CacheStore.instance.setCacheItem('k2', 'v2');
    await CacheStore.instance.setJsonCache('j1', {'a': 1});
    await CacheStore.instance.removeCacheItem('k1');
    await CacheStore.instance.clearItemsCache();
    await CacheStore.instance.clearItemsByPrefix('tmdb:');
    await CacheStore.instance.clearHistory();
    await CacheStore.instance.flush();

    expect(CacheStore.instance.getCacheItem('k2'), isNull);
    expect(CacheStore.instance.getCacheItem('k1'), isNull);
    expect(CacheStore.instance.getJsonCache('j1'), isNull);
    expect(CacheStore.instance.getJsonListCache('j1'), isNull);
    expect(CacheStore.instance.cacheItemsCount(), 0);
    expect(CacheStore.instance.cacheItemsByteSize(), 0);
    expect(CacheStore.instance.cacheItemsByteSizeByPrefix('tmdb:'), 0);
  });

  test('close 后可以重新 init（不留在"已关闭"死状态）', () async {
    await CacheStore.instance.init();
    expect(CacheStore.instance.isClosed, isFalse);
    await CacheStore.instance.setCacheItem('k3', 'v3');
    expect(CacheStore.instance.getCacheItem('k3'), 'v3');
  });
}
