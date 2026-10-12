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

import 'app_log.dart';

class PythonManager {
  static final PythonManager _instance = PythonManager._internal();
  static PythonManager get instance => _instance;

  static const String _channelName = 'com.tvbox/flutter/python';

  MethodChannel? _channel;

  /// Python 引擎状态
  final ValueNotifier<bool> ready = ValueNotifier(false);
  final ValueNotifier<String?> lastError = ValueNotifier(null);

  /// 默认超时（ms）——与 Node 引擎同一量级
  int _timeoutMs = 10000;
  int get timeoutMs => _timeoutMs;

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
      final ok = await _channelImpl.invokeMethod<bool>('ensureStarted') ?? false;
      ready.value = ok;
      if (!ok) {
        lastError.value = 'Python 引擎启动失败（详见 App 日志）';
      }
      return ok;
    } catch (e) {
      lastError.value = 'Python 引擎启动异常: $e';
      AppLog.instance.w('[Python] ensureStarted 异常: $e');
      return false;
    }
  }

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
    if (!await ensureStarted()) {
      return {'ok': false, 'error': lastError.value ?? '未启动'};
    }
    try {
      final r = await _channelImpl.invokeMapMethod<String, dynamic>(
        'eval', {'code': code});
      return r ?? {'ok': false, 'error': '空返回'};
    } on PlatformException catch (e) {
      return {'ok': false, 'error': e.message ?? e.code};
    } catch (e) {
      return {'ok': false, 'error': '$e'};
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
    if (!await ensureStarted()) {
      return PythonCallResult(
          ok: false, error: lastError.value ?? '未启动', json: null);
    }
    try {
      final r = await _channelImpl.invokeMapMethod<String, dynamic>(
        'call', {
          'module': module,
          'method': method,
          'argsJson': jsonEncode(args),
        });
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
