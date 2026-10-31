import 'package:tvbox/services/app_log.dart';
import 'package:tvbox/services/api_config.dart';
import 'package:tvbox/services/network_manager.dart';
import 'package:tvbox/services/nodejs_manager.dart';
import 'package:tvbox/services/spider_service.dart';

/// 前台恢复状态机（原 AppState.handleSceneActive 四级流程）
///
/// 1) Node 死了则重启
/// 2) verify /source/status
/// 3) reload 源并等新 spiderPort
/// 4) 6×10s 长重试兜底
class SceneRecovery {
  SceneRecovery({
    required this.markNodeStarted,
    required this.setReconnecting,
    required this.setCompleted,
    required this.setFailed,
  });

  final void Function() markNodeStarted;
  final void Function() setReconnecting;
  final void Function() setCompleted;
  final void Function(String message) setFailed;

  /// reload 500 后的「强制重新下载源」每个恢复流程只做一次。
  bool _redownloadTried = false;

  /// Node `/source/loadPath` 500 说明缓存里的 index.js 本身坏了
  ///（require 失败 / start() 抛异常），单纯重试永远失败。
  /// 这里删掉缓存并走完整 `loadSource()` 重新下载一次。
  Future<bool> _tryRedownloadSource() async {
    if (_redownloadTried) return false;
    _redownloadTried = true;
    // 优先当前线路清单里的 JS 源（反映用户此刻选中的订阅）；
    // 清单里没有再用 SpiderService 记下的主源地址。
    var url = '';
    for (final s in ApiConfig.instance.sourceBeanList) {
      if (!s.isJsScriptSource) continue;
      final api = s.api.trim();
      if (api.startsWith('http')) {
        url = api;
        break;
      }
    }
    if (url.isEmpty) {
      url = SpiderService.instance.mainScriptUrl.trim();
    }
    if (url.isEmpty) {
      // 以前这里静默 return false —— 日志里完全看不出来「为什么没去重下」，
      // 只能看到 reload 失败后直接进入 60 秒长重试。现在把原因写下来。
      AppLog.instance.w(
        '[SceneRecovery] 想重新下载源，但拿不到地址：'
        '当前线路清单里没有 JS 源，SpiderService.mainScriptUrl 也是空的',
      );
      return false;
    }
    AppLog.instance
        .log('[SceneRecovery] reload 失败 → 强制重新下载源: $url');
    final (ok, msg) = await NodeJSManager.instance.redownloadSource(url);
    AppLog.instance.log(
        '[SceneRecovery] 重新下载源${ok ? "成功" : "失败"}: ${msg ?? ""}');
    if (ok) {
      // 重新下载成功后缓存目录里有 index.js 了 —— 清掉「缓存丢失」标记，
      // 否则后面「跳过 60 秒长重试」的判断会用到过期的值。
      NodeJSManager.instance.clearSourceCacheMissing();
    }
    return ok;
  }

  Future<void> recover() async {
    final startAt = DateTime.now();
    final hasSpiderSource =
        NodeJSManager.instance.isRunning || NodeJSManager.instance.managementPort > 0;
    final spiderPort = NodeJSManager.instance.spiderPort;
    final managementPort = NodeJSManager.instance.managementPort;
    final nodeIsRunning = NodeJSManager.instance.isRunning;

    final cid = AppLog.instance.sceneStart(
      'handleSceneActive',
      fields: {
        'spiderPort': spiderPort,
        'managementPort': managementPort,
        'nodeIsRunning': nodeIsRunning,
        'hasSpiderSource': hasSpiderSource,
      },
    );

    // **第零关**: 如果 Node.js 已死 (isRunning=false), 先重启
    // iOS SIGKILL 场景: Swift 端 onNodeExit 因 node_start 阻塞不返回没跑,
    // Swift 主动 ping /check 失败时发 onNodeExit 给 Dart, Dart onNodeExit
    // 收到时清 isRunning/旧端口. handleSceneActive 看到 isRunning=false
    // 调 startNodeJS 重启. 注意: startNodeJS 调 Swift 启动新 Node.js, 新
    // Node.js 启动后会通过 onCatPawOpenPort 通知新端口给 Dart (Dart HTTP
    // server 一直跑没停, 通知链没断).
    if (!nodeIsRunning) {
      AppLog.instance.sceneStep(cid, 'restart_needed',
          fields: {
            'reason': 'isRunning=false, Node.js 已死 (iOS SIGKILL 或异常退出)',
            'oldSpiderPort': spiderPort,
            'oldMgmtPort': managementPort,
          });
      final restartStart = DateTime.now();
      final restartOk = await NodeJSManager.instance.startNodeJS();
      AppLog.instance.sceneStep(
        cid,
        restartOk ? 'restart_ok' : 'restart_fail',
        elapsedMs: DateTime.now().difference(restartStart).inMilliseconds,
        level: restartOk ? LogLevel.info : LogLevel.error,
        fields: {'ok': restartOk},
      );
      if (!restartOk) {
        setFailed('Node.js 重启失败, 请关闭应用后重新打开');
        AppLog.instance.sceneEnd(
          cid,
          'restart_fail',
          elapsedMs: DateTime.now().difference(startAt).inMilliseconds,
          ok: false,
          fields: {'path': 'restart'},
        );
        return;
      }
      // 启动成功, 重新读端口 (新 Node.js 刚 listen, 应该已经通过
      // onCatPawOpenPort 通知过). 短暂 wait 让 Dart 同步最新状态.
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // **第一步**: 立即重建 dio：恢复 iOS 后台断开的 socket
    AppLog.instance.sceneStep(cid, 'invalidate_dio',
        fields: {'reason': 'iOS 后台断开 socket 恢复'});
    SpiderService.instance.invalidateSession();
    NetworkManager.instance.invalidateSession();

    // **第二关**: 真实 HTTP 探测 mgmtServer 的 /source/status 端点
    // **2026-07-08 修复**: 旧版用 spiderPort (9988) 调永远 404,
    // 改成用 managementPort. /source/status 是 mgmtServer 端点不是 spiderServer.
    if (managementPort > 0) {
      final verifyStart = DateTime.now();
      AppLog.instance.sceneStep(cid, 'verify_start',
          fields: {'managementPort': managementPort});
      try {
        final ok = await NodeJSManager.instance
            .verifySourceLoaded(managementPort);
        AppLog.instance.sceneStep(
          cid,
          ok ? 'verify_ok' : 'verify_fail',
          elapsedMs: DateTime.now().difference(verifyStart).inMilliseconds,
          fields: {'managementPort': managementPort, 'ok': ok},
        );
        if (ok) {
          AppLog.instance.sceneEnd(
            cid,
            'verify_ok',
            elapsedMs: DateTime.now().difference(startAt).inMilliseconds,
            ok: true,
            fields: {'path': 'verify'},
          );
          return;
        }
      } catch (e) {
        AppLog.instance.sceneStep(
          cid,
          'verify_exception',
          elapsedMs: DateTime.now().difference(verifyStart).inMilliseconds,
          level: LogLevel.error,
          fields: {'managementPort': managementPort},
          error: e.toString(),
        );
      }
    } else {
      AppLog.instance.sceneStep(cid, 'verify_skip',
          fields: {'reason': 'managementPort=0'});
    }

    setReconnecting();
    AppLog.instance.sceneStep(cid, 'phase_reconnecting');

    // **第三关**: 尝试 reload 源 (不判定 Node.js 死活)
    if (managementPort > 0) {
      final oldSpiderPort = spiderPort;
      final reloadStart = DateTime.now();
      AppLog.instance.sceneStep(cid, 'reload_start',
          fields: {'managementPort': managementPort});
      final reloaded = await NodeJSManager.instance
          .reloadSourceViaManagementPort(managementPort) ||
          await _tryRedownloadSource();
      AppLog.instance.sceneStep(
        cid,
        reloaded ? 'reload_ok' : 'reload_fail',
        elapsedMs: DateTime.now().difference(reloadStart).inMilliseconds,
        fields: {'managementPort': managementPort, 'ok': reloaded},
      );
      if (reloaded) {
        // 等新 spiderPort, 10s
        var newPortSeen = false;
        var portSeenAt = 0;
        for (var i = 0; i < 20; i++) {
          final newPort = NodeJSManager.instance.spiderPort;
          if (newPort > 0 && newPort != oldSpiderPort) {
            newPortSeen = true;
            portSeenAt = i * 500;
            break;
          }
          await Future.delayed(const Duration(milliseconds: 500));
        }
        if (newPortSeen) {
          AppLog.instance.sceneStep(cid, 'new_spider_port',
              elapsedMs: portSeenAt,
              fields: {
                'oldSpiderPort': oldSpiderPort,
                'newSpiderPort': NodeJSManager.instance.spiderPort,
              });
          await Future.delayed(const Duration(seconds: 1));
          markNodeStarted();
          setCompleted();
          AppLog.instance.sceneEnd(
            cid,
            'reload_ok',
            elapsedMs: DateTime.now().difference(startAt).inMilliseconds,
            ok: true,
            fields: {'path': 'reload'},
          );
          return;
        }
        AppLog.instance.sceneStep(cid, 'reload_no_new_port',
            level: LogLevel.warn,
            fields: {'oldSpiderPort': oldSpiderPort, 'waitedMs': 10000});
      }
    } else {
      AppLog.instance.sceneStep(cid, 'reload_skip',
          fields: {'reason': 'managementPort=0'});
    }

    // **第四关**: 兜底 _recoverSpiderService (2026-07-08: 6×10s=60s 长重试)
    //
    // 但**源缓存目录整个丢了**（`index.js` 不存在）时，spiderPort 永远回不来：
    // 每次 reload 都是同一个 `Cannot find module`。这时候再等 60 秒纯粹是
    // 让用户干等（`app_2026-10-31(10).log` 里连等 3 轮 = 3 分钟）。
    // 直接判失败，文案指向「重新选源」这个唯一有效的动作。
    if (NodeJSManager.instance.sourceCacheMissing) {
      AppLog.instance.sceneStep(
        cid,
        'recover_skip_missing_source',
        level: LogLevel.warn,
        fields: {
          'reason': '源缓存目录里没有 index.js，6×10s 长重试不可能成功',
        },
      );
      setFailed('源文件已丢失（缓存目录里没有 index.js），'
          '请到「设置 → 线路」重新选一个源');
      AppLog.instance.sceneEnd(
        cid,
        'recover_fail',
        elapsedMs: DateTime.now().difference(startAt).inMilliseconds,
        ok: false,
        fields: {'path': 'missing_source_cache'},
      );
      return;
    }
    AppLog.instance.sceneStep(cid, 'recover_start',
        fields: {'reason': 'verify+reload 都失败, 走兜底 6×10s=60s 长重试'});
    final recoverStart = DateTime.now();
    final recovered = await _recoverSpiderService(cid);
    AppLog.instance.sceneStep(
      cid,
      recovered ? 'recover_ok' : 'recover_fail',
      elapsedMs: DateTime.now().difference(recoverStart).inMilliseconds,
      level: recovered ? LogLevel.info : LogLevel.error,
      fields: {'ok': recovered},
    );

    if (recovered) {
      setCompleted();
    } else {
      // 只报一条：`setFailed` 写的是同一个 configLoadError，连续两次调用
      // 会让第一条（更具体的"Node.js 重启失败"）被后一条覆盖 ⇒ 用户永远看不到
      setFailed('Node.js 重启失败，服务已断开，请关闭应用后重新打开');
    }
    AppLog.instance.sceneEnd(
      cid,
      recovered ? 'recover_ok' : 'recover_fail',
      elapsedMs: DateTime.now().difference(startAt).inMilliseconds,
      ok: recovered,
      fields: {
        'path': 'recover',
        'finalSpiderPort': NodeJSManager.instance.spiderPort,
        'finalMgmtPort': NodeJSManager.instance.managementPort,
        'finalNodeIsRunning': NodeJSManager.instance.isRunning,
      },
    );
  }

  /// 恢复 Spider 服务 - 对应 Swift recoverSpiderService
  ///
  /// [cid] handleSceneActive 的 correlation id, 串联所有日志
  ///
  /// **2026-07-08 改**: 6 次 × 10s = 60s 长重试. 之前 4 × 2s = 8s 不够
  /// (iOS 后台冻结 Node.js, 解冻时间可达 30s+). 给 iOS 自动解冻老 Node.js
  /// 充足时间. iOS NodeMobile V8 单例, 不能重启 Node.js (force_restart
  /// 路径 6988e13 实测无效: 第二次 node_start 卡 V8 init, 新 Node.js
  /// 起不来).
  Future<bool> _recoverSpiderService(String cid) async {
    AppLog.instance.sceneStep(cid, 'recover_wait_10s');
    await Future.delayed(const Duration(seconds: 10));

    for (var attempt = 0; attempt < 6; attempt++) {
      final attemptNo = attempt + 1;
      AppLog.instance.sceneStep(cid, 'recover_attempt',
          fields: {'attempt': attemptNo, 'maxAttempts': 6});

      final spiderPort = NodeJSManager.instance.spiderPort;
      AppLog.instance.sceneStep(cid, 'recover_check_spider',
          fields: {'attempt': attemptNo, 'spiderPort': spiderPort});
      if (spiderPort > 0) {
        final checkStart = DateTime.now();
        final portOk =
            await NodeJSManager.instance.checkLocalPort(spiderPort);
        AppLog.instance.sceneStep(
          cid,
          'recover_check_spider_result',
          elapsedMs: DateTime.now().difference(checkStart).inMilliseconds,
          fields: {'attempt': attemptNo, 'spiderPort': spiderPort, 'ok': portOk},
        );
        if (portOk) {
          AppLog.instance.sceneStep(cid, 'recover_spider_ok',
              fields: {'attempt': attemptNo, 'spiderPort': spiderPort});
          markNodeStarted();
          return true;
        }
      }

      final managementPort = NodeJSManager.instance.managementPort;
      AppLog.instance.sceneStep(cid, 'recover_check_mgmt',
          fields: {'attempt': attemptNo, 'managementPort': managementPort});
      if (managementPort > 0) {
        final checkStart = DateTime.now();
        final portOk =
            await NodeJSManager.instance.checkLocalPort(managementPort);
        AppLog.instance.sceneStep(
          cid,
          'recover_check_mgmt_result',
          elapsedMs: DateTime.now().difference(checkStart).inMilliseconds,
          fields: {
            'attempt': attemptNo,
            'managementPort': managementPort,
            'ok': portOk
          },
        );
        if (portOk) {
          final reloadStart = DateTime.now();
          final reloaded = await NodeJSManager.instance
                  .reloadSourceViaManagementPort(managementPort) ||
              await _tryRedownloadSource();
          AppLog.instance.sceneStep(
            cid,
            'recover_mgmt_reload',
            elapsedMs: DateTime.now().difference(reloadStart).inMilliseconds,
            fields: {
              'attempt': attemptNo,
              'managementPort': managementPort,
              'ok': reloaded
            },
          );
          if (reloaded) {
            markNodeStarted();
            return true;
          }
        } else {
          AppLog.instance.sceneStep(cid, 'recover_mgmt_fail',
              fields: {'attempt': attemptNo, 'managementPort': managementPort});
        }
      } else {
        AppLog.instance.sceneStep(cid, 'recover_mgmt_skip',
            fields: {'attempt': attemptNo, 'reason': 'managementPort=0'});
      }

      if (attempt < 5) {
        AppLog.instance.sceneStep(cid, 'recover_wait_10s',
            fields: {'attempt': attemptNo, 'nextAttemptIn': '10s'});
        await Future.delayed(const Duration(seconds: 10));
      }
    }

    AppLog.instance.sceneStep(cid, 'recover_all_fail',
        level: LogLevel.error, fields: {'attempts': 6});

    // **2026-07-08 删 force_restart 路径**:
    // 6988e13 的 resetPlatformStateForRestart + startNodeJS 强制重启
    // 实测无效: iOS NodeMobile 是 embed library, V8 单例, 第二次 node_start
    // 调会卡 V8 init 阶段, node.log 0 行新 boot 记录, 新 Node.js 永远起不来.
    // 而且老 Node.js 通常只是 iOS 后台冻结 (74s 后台不触发 SIGKILL), 实际
    // 还活着, 端口冲突让新 Node.js EADDRINUSE 立即失败.
    //
    // 现在改为: 60s 长重试后仍 fail → 弹窗告诉用户"服务已冻结, 请手动重启
    // app", 不再尝试重启 Node.js. 用户手动重启 app 后, iOS 会清空所有进程
    // 状态, 重新 init 一切, 不会受 V8 单例限制.
    AppLog.instance.sceneStep(cid, 'force_restart_removed',
        level: LogLevel.warn,
        fields: {
          'reason':
              'iOS NodeMobile V8 单例限制, 强制重启 Node.js 实测无效, 改为弹窗',
          'spiderPort': NodeJSManager.instance.spiderPort,
          'mgmtPort': NodeJSManager.instance.managementPort,
        });
    return false;
  }
}
