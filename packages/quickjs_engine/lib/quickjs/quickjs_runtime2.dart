/* START PARTS IMPORT QJS ENGINE */
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:quickjs_engine/quickjs_engine.dart';

import 'ffi.dart';

export 'ffi.dart' show JSEvalFlag, JSRef;

part './isolate.dart';
part './object.dart';
part './wrapper.dart';

/// Handler function to manage js module.
typedef _JsModuleHandler = String Function(String name);

/// Handler to manage unhandled promise rejection.
typedef _JsHostPromiseRejectionHandler = void Function(dynamic reason);

/// Quickjs engine for flutter.
class QuickJsRuntime2 extends JavascriptRuntime {
  Pointer<JSRuntime>? _rt;
  Pointer<JSContext>? _ctx;

  /// Max stack size for quickjs.
  int stackSize;

  /// Max stack size for quickjs.
  final int? timeout;

  /// Max memory for quickjs.
  final int? memoryLimit;

  /// Message Port for event loop. Close it to stop dispatching event loop.
  ReceivePort port = ReceivePort();

  /// Handler function to manage js module.
  final _JsModuleHandler? moduleHandler;

  /// Handler function to manage js module.
  final _JsHostPromiseRejectionHandler? hostPromiseRejectionHandler;

  QuickJsRuntime2({
    this.moduleHandler,
    this.stackSize = 1024 * 1024,
    this.timeout,
    this.memoryLimit,
    this.hostPromiseRejectionHandler,
  }) {
    this.init();
  }

  _ensureEngine() {
    if (_rt != null) return;
    final rt = jsNewRuntime((ctx, type, ptr) {
      try {
        switch (type) {
          case JSChannelType.METHON:
            final pdata = ptr.cast<Pointer<JSValue>>();
            final argc = pdata[1].cast<Int32>().value;
            final pargs = [];
            for (var i = 0; i < argc; ++i) {
              pargs.add(_jsToDart(
                ctx,
                Pointer.fromAddress(
                  pdata[2].address + sizeOfJSValue * i,
                ),
              ));
            }
            final JSInvokable func = _jsToDart(
              ctx,
              pdata[3],
            );
            return _dartToJs(
                ctx,
                func.invoke(
                  pargs,
                  _jsToDart(ctx, pdata[0]),
                ));
          case JSChannelType.MODULE:
            if (moduleHandler == null) throw JSError('No ModuleHandler');
            final ret = moduleHandler!(
              ptr.cast<Utf8>().toDartString(),
            ).toNativeUtf8();
            Future.microtask(() {
              malloc.free(ret);
            });
            return ret.cast();
          case JSChannelType.PROMISE_TRACK:
            final err = _parseJSException(ctx, ptr);
            if (hostPromiseRejectionHandler != null) {
              hostPromiseRejectionHandler!(err);
            } else {
              print('unhandled promise rejection: $err');
            }
            return nullptr;
          case JSChannelType.FREE_OBJECT:
            final rt = ctx.cast<JSRuntime>();
            _DartObject.fromAddress(rt, ptr.address)?.free();
            return nullptr;
        }
        throw JSError('call channel with wrong type');
      } catch (e) {
        if (type == JSChannelType.FREE_OBJECT) {
          print('DartObject release error: $e');
          return nullptr;
        }
        if (type == JSChannelType.MODULE) {
          print('host Promise Rejection Handler error: $e');
          return nullptr;
        }
        final throwObj = _dartToJs(ctx, e);
        final err = jsThrow(ctx, throwObj);
        jsFreeValue(ctx, throwObj);
        if (type == JSChannelType.MODULE) {
          jsFreeValue(ctx, err);
          return nullptr;
        }
        return err;
      }
    }, timeout ?? 0, port);
    final stackSize = this.stackSize;
    if (stackSize > 0) jsSetMaxStackSize(rt, stackSize);
    final memoryLimit = this.memoryLimit ?? 0;
    if (memoryLimit > 0) jsSetMemoryLimit(rt, memoryLimit);
    _rt = rt;
    _ctx = jsNewContext(rt);
  }

  /// Free Runtime and Context which can be recreate when evaluate again.
  close() {
    final rt = _rt;
    final ctx = _ctx;
    _rt = null;
    _ctx = null;
    if (ctx != null) jsFreeContext(ctx);
    if (rt == null) return;
    _executePendingJob();
    try {
      for (final obj in localContext.values) {
        JSRef.freeRecursive(obj);
      }
      jsFreeRuntime(rt);
    } on String catch (e) {
      throw JSError(e);
    }
  }

  void _executePendingJob() {
    final rt = _rt;
    final ctx = _ctx;
    if (rt == null || ctx == null) return;
    while (true) {
      int err = jsExecutePendingJob(rt);
      if (err <= 0) {
        if (err < 0) print(_parseJSException(ctx));
        break;
      }
    }
  }

  /// Dispatch JavaScript Event loop.
  Future<void> dispatch() async {
    //await for (final _ in port) {
    _executePendingJob();
    //}
  }

  @override
  void setInspectable(bool inspectable) {
    // Nothing to do.
  }

  /// Evaluate js script.
  ///
  /// 构造时若传了 [timeout]（> 0），本次求值受「JS 执行预算」约束：
  /// 脚本自身跑超时会被中断并返回一条可读的超时错误，而不是卡死线程。
  /// 宿主函数（Dart 侧 IO，如 java.ajax 抓网页）的等待**不计入**预算 ——
  /// 原生侧每次宿主调用返回后都会重新计时（见 js_eval_rearm），
  /// 所以合法的慢速网络请求不会被误杀。
  JsEvalResult evaluate(
    String command, {
    String? name,
    int? evalFlags,
    String? sourceUrl,
  }) {
    _ensureEngine();
    final ctx = _ctx!;
    final budgetMs = timeout ?? 0;
    // 原生库未导出 jsSetEvalTimeout（未打补丁/旧预编译库）时静默跳过，
    // 退化为旧的无限时行为，不会崩。
    final armTimeout = budgetMs > 0 && jsSetEvalTimeout != null;
    if (armTimeout) jsSetEvalTimeout!(_rt!, budgetMs);
    try {
      final jsval = jsEval(
        ctx,
        command,
        name ?? '<eval>',
        evalFlags ?? JSEvalFlag.GLOBAL,
      );

      if (jsIsException(jsval) != 0) {
        jsFreeValue(ctx, jsval);
        JSError exception = _parseJSException(ctx);
        // 超时中断原生只抛 `InternalError: interrupted`，对用户不直观 ⇒
        // 识别出来换成明确说明，便于在运行日志里定位是哪个源跑飞了。
        if (armTimeout && _looksInterrupted(exception)) {
          final e = JSError('书源脚本执行超时（${budgetMs}ms），已强制中断'
              '（仅计脚本自身耗时，宿主请求等待不计入）');
          return JsEvalResult(e.toString(), e, isError: true);
        }
        return JsEvalResult(exception.toString(), exception, isError: true);
      }
      final result = _jsToDart(ctx, jsval);
      jsFreeValue(ctx, jsval);
      return JsEvalResult(result?.toString() ?? "null", result);
    } finally {
      // 求值结束立刻清掉预算：否则截止时间已过，会瞬间打断后续每一次求值
      if (armTimeout) jsSetEvalTimeout!(_rt!, 0);
    }
  }

  /// 异常是否来自超时中断（QuickJS 抛 `InternalError: interrupted`）。
  static bool _looksInterrupted(JSError e) =>
      e.message.toLowerCase().contains('interrupt');

  @override
  JsEvalResult callFunction(Pointer<NativeType> fn, Pointer<NativeType> obj) {
    throw UnimplementedError();
  }

  @override
  T? convertValue<T>(JsEvalResult jsValue) {
    return true as T;
  }

  @override
  void dispose() {
    try {
      port.close(); // stop dispatch loop
      close(); // close engine
    } on JSError catch (e) {
      print(e); // catch reference leak exception
    }
  }

  @override
  Future<JsEvalResult> evaluateAsync(String code, {String? sourceUrl}) {
    return Future.value(evaluate(code, sourceUrl: sourceUrl));
  }

  @override
  int executePendingJob() {
    this.dispatch();
    return 0;
  }

  @override
  String getEngineInstanceId() {
    return this.hashCode.toString();
  }

  @override
  void initChannelFunctions() {
    JavascriptRuntime.channelFunctionsRegistered[getEngineInstanceId()] = {};
    final setToGlobalObject =
        evaluate("(key, val) => { this[key] = val; }").rawResult;
    localContext['setToGlobalObject'] = setToGlobalObject;
    (setToGlobalObject as JSInvokable).invoke([
      'sendMessage',
      (String channelName, String message) {
        final channelFunctions = JavascriptRuntime
            .channelFunctionsRegistered[getEngineInstanceId()]!;

        if (channelFunctions.containsKey(channelName)) {
          return channelFunctions[channelName]!.call(jsonDecode(message));
        } else {
          print('No channel $channelName registered');
        }
        if (JavascriptRuntime.debugEnabled) {
          print('CHANNEL: $channelName - Message: $message');
        }
      }
    ]);
  }

  @override
  String jsonStringify(JsEvalResult jsValue) {
    throw UnimplementedError();
  }

  @override
  bool setupBridge(String channelName, void Function(dynamic args) fn) {
    final channelFunctionCallbacks =
        JavascriptRuntime.channelFunctionsRegistered[getEngineInstanceId()]!;

    if (channelFunctionCallbacks.keys.contains(channelName)) return false;

    channelFunctionCallbacks[channelName] = fn;

    return true;
  }
}
