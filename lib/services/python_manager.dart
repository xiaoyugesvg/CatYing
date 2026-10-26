// lib/services/python_manager.dart
//
// Python 管理器 - 跨平台单例（T3 Python spider 源引擎）
// -----------------------------------------------------------------------------
// 一期只支持 iOS（MethodChannel → PythonBridge.swift → CPython.xcframework）；
// Windows/macOS/Android 后续可加（Process 拉起或 Chaquopy），当前返回"未支持"。
//
// 用途：给 TVBox `sites[]` 里 `type:3 && api 以 .py 结尾` 的源提供
//   home/category/detail/play/search（视频）与 search/bookInfo/toc/content（书源）
//   四/五接口执行能力。超时中断由原生侧 watchdog + PyThreadState_SetAsyncExc
//   负责（字节码边界抛 TimeoutError），Dart 侧只管排队调用与结果 JSON 解析。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueNotifier, defaultTargetPlatform;
import 'package:flutter/services.dart' show MethodChannel, PlatformException;

import 'package:tvbox/services/app_log.dart';

class PythonManager {
  static final PythonManager _instance = PythonManager._internal();
  static PythonManager get instance => _instance;

  static const String _channelName = 'com.tvbox/flutter/python';

  MethodChannel? _channel;

  /// Python 引擎状态
  final ValueNotifier<bool> ready = ValueNotifier(false);
  final ValueNotifier<String?> lastError = ValueNotifier(null);

  /// 默认超时（ms）。
  ///
  /// 2026-10-18：10s → **25s**。用户日志里多次出现
  /// `call(video.xxx.category) 超时未返回（预算 10000ms）`——分类接口通常要
  /// 连续请求站点（列表 + 详情/分页），弱网或站点慢时 10s 很容易误杀，
  /// 随后引擎被标记卡死、后续请求全部失败。放宽后单次慢请求能正常完成。
  int _timeoutMs = 25000;
  int get timeoutMs => _timeoutMs;

  // ── 引擎「卡死」标记（2026-10-14）──────────────────────────────
  //
  // 原生侧靠 watchdog 的 `PyThreadState_SetAsyncExc` 抛 TimeoutError 中断超时
  // 脚本；但若脚本把该异常吞掉、或在**纯 C 扩展**里死循环，执行线程不会退出
  // ⇒ 原生那条串行 `workQueue` 被**永久占用** ⇒ 之后所有 Python 调用都排在
  // 它后面，Dart 侧表现为"点了永远没反应"（MethodChannel 本身没有超时）✗。
  //
  // Dart 侧兜底：
  //   ① 每次调用加**硬超时**（预算 + 3s）——不再无限等待；
  //   ② 超时即置 [_stuck]，后续调用**立刻失败**并说明原因，不再排队堆积。
  //   ③ 🔴 2026-10-14 补：**自动恢复**（见 [_scheduleAutoRecover]）——
  //      卡死的最常见根因是"脚本里不带 timeout 的网络请求永久阻塞"，已经在
  //      Python 侧兜住（spider_runner 给 `Session.request` / `urlopen` /
  //      socket 全局默认都补了 **8s** 超时，且**必须 < 原生 watchdog 的 10s**）
  //      ⇒ 卡住的那次调用会在超时内自己返回、原生队列随之解开。
  //   ④ 🔴 2026-10-14 二次修：恢复探针原来**只探 3 次（6/12/18s）就放弃**，
  //      而二级兜底当时给的是 20s ⇒ 那通请求 20s 才返回时，三个探针全部落空，
  //      标记**永久留在卡死态**（即使队列 2 秒后已经通了）—— 这才是用户抱怨
  //      "必须重启 App"的直接原因。现在改成**一直探到通为止**，且用
  //      [_probeInFlight] 防止探针自己往原生队列里堆积。
  bool _stuck = false;
  bool get isStuck => _stuck;

  /// 自动恢复：探针间隔（一直探到通为止，通了就停）+ 探针在飞标记
  static const Duration _kRecoverInterval = Duration(seconds: 4);
  Timer? _recoverTimer;
  bool _probeInFlight = false;

  PythonManager._internal() {
    if (!Platform.isIOS) {
      AppLog.instance.w('[Python] 非 iOS 平台：Python spider 引擎未实现（仅 iOS 一期）');
    }
  }

  bool get isIOS => Platform.isIOS;

  MethodChannel get _channelImpl {
    return _channel ??= const MethodChannel(_channelName);
  }

  // ============================================================
  // 生命周期
  // ============================================================

  /// 确保解释器已启动（Py_Initialize + 导入 spider_runner）
  Future<bool> ensureStarted() async {
    if (ready.value) return true;
    if (!isIOS) {
      lastError.value = 'Python 引擎仅支持 iOS（当前 ${defaultTargetPlatform.name}）';
      return false;
    }
    try {
      // 🔴 2026-10-14：必须加超时 —— ensureStarted 也走原生那条串行 workQueue，
      //    队列被上次执行占住时它会一直排队（MethodChannel 本身没有超时），
      //    表现就是「点加载半天没反应」。超时后按卡死处理 → 自动恢复接管。
      final ok = await _channelImpl
              .invokeMethod<bool>('ensureStarted')
              .timeout(_ensureTimeout) ??
          false;
      ready.value = ok;
      if (!ok) {
        lastError.value = 'Python 引擎启动失败（详见 App 日志）';
      }
      return ok;
    } on TimeoutException {
      _markStuck('ensureStarted');
      lastError.value = _stuckMsg;
      return false;
    } catch (e) {
      lastError.value = 'Python 引擎启动异常: $e';
      AppLog.instance.w('[Python] ensureStarted 异常: $e');
      return false;
    }
  }

  /// 启动/握手超时预算：冷启动要解 Py_Initialize + 导入适配层，给宽一点，
  /// 但**必须有限**（绝不能无限等原生队列）。
  /// 2026-10-18：20s → 30s（低端机冷启动 + 首次 import 依赖可能超过 20s）。
  static const Duration _ensureTimeout = Duration(seconds: 30);

  /// 设置超时预算（原生 watchdog 按此中断死循环脚本）
  Future<void> setTimeout(int ms) async {
    _timeoutMs = ms;
    if (isIOS && ready.value) {
      try {
        await _channelImpl.invokeMethod('setTimeout', ms);
      } catch (_) {/* 未启动时忽略 */}
    }
  }

  Future<void> dispose() async {
    _recoverTimer?.cancel();
    _recoverTimer = null;
    if (isIOS && ready.value) {
      try {
        await _channelImpl.invokeMethod('dispose');
      } catch (_) {}
    }
    ready.value = false;
  }

  // ============================================================
  // 执行
  // ============================================================

  /// 执行一段 Python 代码（调试/编辑器用），返回 {ok, output, error}
  Future<Map<String, dynamic>> eval(String code) async {
    if (_stuck) {
      return {'ok': false, 'error': _stuckMsg};
    }
    if (!await ensureStarted()) {
      return {'ok': false, 'error': lastError.value ?? '未启动'};
    }
    try {
      final r = await _channelImpl
          .invokeMapMethod<String, dynamic>('eval', {'code': code})
          .timeout(_hardTimeout);
      return r ?? {'ok': false, 'error': '空返回'};
    } on TimeoutException {
      _markStuck('eval');
      return {'ok': false, 'error': _stuckMsg};
    } on PlatformException catch (e) {
      return {'ok': false, 'error': e.message ?? e.code};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
    }
  }

  /// 单次调用的硬超时：原生预算 + 3s 余量（原生的中断本身也要时间）。
  Duration get _hardTimeout => Duration(milliseconds: _timeoutMs + 3000);

  // 文案刻意**不再提"重启 App"**：现在恢复是自动且一定能等到队列解开的，
  // 让用户去重启只会制造"必须重启"的错觉（用户 2026-10-14 的抱怨点）。
  static const String _stuckMsg = 'Python 引擎正忙（上一次执行超时未返回）。'
      '正在自动重试，请等几秒再试一次；'
      '若长时间没反应，可到「设置 → 订阅管理 → 引擎管理」点一次「加载」。';

  void _markStuck(String where) {
    _stuck = true;
    AppLog.instance.w('[Python] $where 超时未返回（预算 ${_timeoutMs}ms）→ 引擎标记为卡死');
    _scheduleAutoRecover();
  }

  /// 卡死后**自动尝试救回**，而不是让用户重启 App。
  ///
  /// 为什么救得回来：卡死的最常见根因是"脚本里不带 timeout 的网络请求永久
  /// 阻塞"，已在 Python 侧兜住（`spider_runner` 给 `Session.request` / `urlopen`
  /// / socket 全局默认都补了 8s 超时，**短于**原生 watchdog 的 10s）
  /// ⇒ 卡住的那次调用必然自己返回、原生 workQueue 随之解开。
  ///
  /// 所以这里**每 4 秒探一次、一直探到通为止**（通了立刻清标记并停表）：
  ///   · 探针带 3s 超时 —— 绝不会把 Dart 也挂住；
  ///   · [_probeInFlight] 保证同一时刻只有一发探针在飞 —— 否则卡死期间每轮都
  ///     往原生队列里塞一个块，越积越多。
  void _scheduleAutoRecover() {
    _recoverTimer?.cancel();
    var ticks = 0;
    _recoverTimer = Timer.periodic(_kRecoverInterval, (timer) async {
      if (!_stuck) {
        timer.cancel();
        return;
      }
      if (_probeInFlight) return; // 上一发探针还在队列里排队
      _probeInFlight = true;
      ticks++;
      final ok = await recover();
      _probeInFlight = false;
      if (ok) {
        timer.cancel();
        AppLog.instance.log('[Python] 已自动恢复（第 $ticks 发探针），后续调用恢复正常');
      } else if (ticks == 3 || ticks % 15 == 0) {
        // 别刷屏，但也别静默：让日志能看出"卡了多久"
        AppLog.instance.w('[Python] 仍在等原生队列解开（已探 ${ticks * 4}s）');
      }
    });
  }

  /// 从「卡死」中恢复；返回原生队列是否已通。
  ///
  /// 探针用 `ensureStarted`：原生侧它**幂等且不碰解释器**
  /// （`started` 已 true 就直接返回 true）⇒ 它只需等队列空出来，
  /// 正好就是"队列通不通"的判据。
  /// 「引擎管理 → 加载」按钮也会调它 —— 手动救命入口。
  Future<bool> recover() async {
    if (!_stuck) return true;
    if (!isIOS) return false;
    try {
      final ok = await _channelImpl
          .invokeMethod<bool>('ensureStarted')
          .timeout(const Duration(seconds: 3));
      if (ok != true) return false;
      _stuck = false;
      ready.value = true;
      lastError.value = null;
      AppLog.instance.log('[Python] 引擎已恢复（原生队列已通）');
      return true;
    } on TimeoutException {
      AppLog.instance.w('[Python] 恢复探针超时：原生队列仍被占住');
      return false;
    } catch (e) {
      AppLog.instance.w('[Python] 恢复探针异常: $e');
      return false;
    }
  }

  /// 调用适配层方法：module=spider_runner 下的逻辑模块，
  /// method=search/category/detail/play/home（视频）或 search/bookInfo/toc/content（书源）。
  /// [args] 会被 JSON 序列化后传给 Python（Python 侧 json.loads）。
  Future<PythonCallResult> call(
    String module,
    String method,
    Map<String, dynamic> args,
  ) async {
    if (_stuck) {
      return PythonCallResult(ok: false, error: _stuckMsg, json: null);
    }
    if (!await ensureStarted()) {
      return PythonCallResult(
          ok: false, error: lastError.value ?? '未启动', json: null);
    }
    try {
      final r = await _channelImpl
          .invokeMapMethod<String, dynamic>('call', {
            'module': module,
            'method': method,
            'argsJson': jsonEncode(args),
          })
          .timeout(_hardTimeout);
      final ok = r?['ok'] == true;
      if (ok) {
        final raw = r?['result'] as String?;
        if (raw == null || raw.isEmpty) {
          return PythonCallResult(ok: true, json: null, raw: raw);
        }
        // Python 侧返回 JSON 字符串；容错：解析失败按原样返回
        try {
          return PythonCallResult(
              ok: true, json: jsonDecode(raw), raw: raw);
        } catch (_) {
          return PythonCallResult(ok: true, json: null, raw: raw);
        }
      }
      return PythonCallResult(
          ok: false, error: r?['error'] as String? ?? '未知错误', json: null);
    } on TimeoutException {
      _markStuck('call($module.$method)');
      return PythonCallResult(ok: false, error: _stuckMsg, json: null);
    } on PlatformException catch (e) {
      return PythonCallResult(ok: false, error: e.message ?? e.code, json: null);
    } catch (e) {
      return PythonCallResult(ok: false, error: '$e', json: null);
    }
  }
}

/// Python call 的封装结果：json 为解析后的对象/列表；解析失败时 raw 保留原文。
class PythonCallResult {
  final bool ok;
  final dynamic json;
  final String? raw;
  final String? error;
  PythonCallResult({required this.ok, this.json, this.raw, this.error});
}
