import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tvbox/services/spider_service.dart';

/// 「引擎重启换端口」这条链路的回归测试（2026-10-30）。
///
/// ── 用户报的现象 ────────────────────────────────────────────────
/// 切到「官方聚合」后首页报：
///   「Exception: 引擎请求失败：DioExceptionType.unknown（动作 home）」
/// 紧接着又一条：
///   「connectionError ... host: 127.0.0.1, port: 61083」
/// 而同一时刻的日志里，引擎其实已经在 **61129** 上正常回了 200
/// （init / home / category 全 200）。点一下「重试」就好了。
///
/// ── 根因（两条，都在 `_postJSON`）────────────────────────────────
/// 1. URL 是在发请求**之前**用 `_spiderPort` 拼死的字符串。引擎重启换端口后，
///    重试仍然用那个旧 URL ⇒ 再打一次已经关掉的旧端口 ⇒ 整页报错。
///    ⇒ 重试前必须 `rewriteLoopbackPort(url, 当前端口)`。
/// 2. 旧代码在重试前 `_dio.close(force: true)` 重建客户端。而 `_dio` 是
///    **全进程共享**的 ⇒ 关闭会连带取消所有正在飞的请求，dio 报的原文
///    就是 `Connection attempt cancelled`（用户截图里那条 connectionError）。
///    ⇒ 改成 `persistentConnection: false`，本地回环每次新建连接，
///      既没有半死 socket，也不需要关共享客户端。
void main() {
  group('rewriteLoopbackPort', () {
    test('回环地址换端口', () {
      expect(
        rewriteLoopbackPort('http://127.0.0.1:61083/spider/k/3/home', 61129),
        'http://127.0.0.1:61129/spider/k/3/home',
      );
    });

    test('localhost 也认', () {
      expect(
        rewriteLoopbackPort('http://localhost:61083/config', 61129),
        'http://localhost:61129/config',
      );
    });

    test('端口相同 → 原样返回（不重建字符串）', () {
      const url = 'http://127.0.0.1:61129/spider/k/3/home';
      expect(rewriteLoopbackPort(url, 61129), same(url));
    });

    test('远端主机**不能**改端口（那是用户配置里的地址）', () {
      const url = 'https://api.example.com:8443/spider/k/3/home';
      expect(rewriteLoopbackPort(url, 61129), url);
    });

    test('端口未知（0 = 引擎还没起来）→ 原样返回', () {
      const url = 'http://127.0.0.1:61083/spider/k/3/home';
      expect(rewriteLoopbackPort(url, 0), url);
    });

    test('中文路径 / 查询串在换端口后保持不变', () {
      const url =
          'http://127.0.0.1:61083/spider/omnibox_Makka%E8%81%9A%E5%90%88/3/home?x=1';
      final out = rewriteLoopbackPort(url, 61129);
      expect(out, contains('%E8%81%9A%E5%90%88'));
      expect(out, endsWith('/3/home?x=1'));
      expect(out, contains(':61129'));
    });

    test('非法 URL 不抛异常', () {
      expect(rewriteLoopbackPort('not a url', 61129), 'not a url');
    });
  });

  group('_postJSON 的两条约束（源码级，防止改回去）', () {
    final src = File('lib/services/spider_service.dart').readAsStringSync();

    test('重试路径不许 close 共享 dio', () {
      // `_dio.close(force: true)` 会取消所有在飞请求 —— 只有
      // `invalidateSession()`（会话作废）里才允许出现。
      // 只数**代码行**：注释里提到这个调用不算。
      final codeLines = src
          .split('\n')
          .where((l) => !l.trimLeft().startsWith('//'))
          .join('\n');
      final occurrences = RegExp(
        r'_dio\.close\(force:\s*true\)',
      ).allMatches(codeLines).length;
      expect(
        occurrences,
        1,
        reason: '只应剩 invalidateSession 里那一处；重试里再关会误杀并发请求',
      );
    });

    test('spider 请求一律不复用连接', () {
      expect(
        src.contains('persistentConnection: false'),
        isTrue,
        reason: '复用半死 socket 是"切回前台第一次请求必失败"的根因',
      );
    });

    test('重试时会用当前端口重写 URL', () {
      expect(src.contains('rewriteLoopbackPort(url, _spiderPort)'), isTrue);
    });
  });
}
