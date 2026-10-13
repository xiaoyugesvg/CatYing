// PythonBridge.swift
// iOS 端 CPython 集成 - Platform Channel 实现
// -----------------------------------------------------------------------------
// 通过 FlutterMethodChannel 暴露以下 method 给 Dart 端（channel: com.tvbox/flutter/python）：
//   - ensureStarted() -> Bool          Py_Initialize + 导入 spider_runner 适配层
//   - eval({code}) -> {ok, output}     执行一段 Python 代码，返回 stdout 字符串
//   - call({module, method, argsJson}) -> {ok, result}   调适配层方法（JSON 入/出）
//   - setTimeout({ms}) -> Void         Swift 侧记录超时预算（watchdog 中断用）
//   - dispose() -> Void                置空状态（iOS 上 Py_Finalize 不做，进程级单例）
//
// 线程模型：所有 Python 调用经一个串行 workQueue（GIL 串行化，杜绝并发进解释器）。
// 超时中断（CPython 无 SetInterruptHandler）：
//   watchdog 线程在 deadline 到达后调 PyThreadState_SetAsyncExc 向执行线程
//   抛 TimeoutError —— 解释器在下一个字节码边界检查 async_exc，`while True: pass`
//   与 `time.sleep` 循环都能被中断（SetAsyncExc 不依赖调用线程持有 GIL）。
//   纯 C 扩展内部死循环（lxml/pycryptodome 等）拦不住 → 一期锁纯 Python 库。
//
// 目录约定：
//   - stdlib + site-packages 在 mainBundle 的 `python-home/`（workflow 嵌入）
//   - 用户源在 <Documents>/python-project/src/spider/{video,book}/（Dart 端写）

import Foundation
import Flutter
import UIKit
import Python

@objc class PythonBridge: NSObject {

    static let channelName = "com.tvbox/flutter/python"

    private let channel: FlutterMethodChannel
    private let messenger: FlutterBinaryMessenger
    private var started: Bool = false

    /// 全部 Python 调用串行执行（GIL 串行化）
    private let workQueue = DispatchQueue(label: "com.tvbox.python", qos: .userInitiated)
    /// watchdog 线程：deadline 到达后 SetAsyncExc 中断执行线程
    private let watchdogQueue = DispatchQueue(label: "com.tvbox.python.watchdog")

    /// 当前超时预算（ms）；截止时刻用 static（C 回调无捕获，只能访问全局）
    private var timeoutMs: Int64 = 10000
    private static var sharedDeadlineNanos: Int64 = 0
    /// 正在执行 Python 代码的**线程 id**（PyThreadState_GetID 的结果）。
    /// ⚠️ CPython 的 `PyThreadState_SetAsyncExc(unsigned long id, PyObject *exc)`
    ///   第一参是线程 id **不是** PyThreadState*（3.7 起改成 id），所以这里存 id。
    private static var sharedExecTid: UInt = 0
    private static var sharedWatchdog: DispatchWorkItem?
    /// spider_runner 模块（new reference，dispose 时 DecRef）
    /// 类型必须是 CPython 的 `PyObject *`（Swift 导入为 UnsafeMutablePointer<PyObject>）——
    /// 之前的 OpaquePointer 与头文件签名不兼容（CI 报 Cannot convert ... OpaquePointer）。
    private var mainModule: UnsafeMutablePointer<PyObject>?

    @objc init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        self.channel = FlutterMethodChannel(
            name: PythonBridge.channelName,
            binaryMessenger: messenger
        )
        super.init()
        self.channel.setMethodCallHandler { [weak self] (call, result) in
            self?.handle(call: call, result: result)
        }
        print("[PythonBridge] channel 已注册: \(PythonBridge.channelName)")
    }

    // ============================================================
    // Method call handler（全部转发到 workQueue，保证串行）
    // ============================================================

    private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
        workQueue.async { [weak self] in
            guard let self = self else {
                result(FlutterError(code: "DEALLOC", message: "PythonBridge 已释放", details: nil))
                return
            }
            switch call.method {
            case "ensureStarted":
                let ok = self.ensureStarted()
                DispatchQueue.main.async { result(ok) }
            case "eval":
                guard let args = call.arguments as? [String: Any],
                      let code = args["code"] as? String else {
                    self.reply(result, error: "eval 需要 {code: String}")
                    return
                }
                let r = self.eval(code: code)
                DispatchQueue.main.async { result(r) }
            case "call":
                guard let args = call.arguments as? [String: Any],
                      let module = args["module"] as? String,
                      let method = args["method"] as? String else {
                    self.reply(result, error: "call 需要 {module, method, argsJson}")
                    return
                }
                let argsJson = args["argsJson"] as? String ?? "{}"
                let r = self.call(module: module, method: method, argsJson: argsJson)
                DispatchQueue.main.async { result(r) }
            case "setTimeout":
                if let ms = call.arguments as? Int {
                    self.timeoutMs = Int64(ms)
                }
                DispatchQueue.main.async { result(nil) }
            case "dispose":
                self.teardown()
                DispatchQueue.main.async { result(nil) }
            default:
                DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
            }
        }
    }

    private func reply(_ result: @escaping FlutterResult, error: String) {
        DispatchQueue.main.async {
            result(FlutterError(code: "BAD_ARGS", message: error, details: nil))
        }
    }

    /// 置空状态（iOS 上 Py_Finalize 不做，进程级单例；只释放引用）
    private func teardown() {
        cancelDeadline()
        if let m = mainModule {
            Py_DecRef(m)
        }
        mainModule = nil
        PythonBridge.sharedExecTid = 0
        started = false
    }

    // ============================================================
    // ensureStarted：Py_Initialize + 定位 stdlib + 导入适配层
    // ============================================================

    private func ensureStarted() -> Bool {
        if started { return true }

        // 1. 定位 bundle 内的 python-home（stdlib + site-packages）
        //    BeeWare xcframework 自带 stdlib 在 Python.framework/Versions/3.12/lib，
        //    但我们固定用 bundle 的 python-home 目录（CI 打包，含三件套库），
        //    找不到才回退 framework 内置 lib。
        let bundle = Bundle.main
        var pythonHome: String? = bundle.path(forResource: "python-home", ofType: nil, inDirectory: nil)
        if pythonHome == nil,
           let fwPath = bundle.path(forResource: "Python", ofType: "framework") {
            pythonHome = "\(fwPath)/Versions/3.12/lib"
        }
        guard let home = pythonHome else {
            print("[PythonBridge] ❌ python-home 不在 bundle 中")
            return false
        }
        print("[PythonBridge] PYTHONHOME = \(home)")

        // 2. 环境变量（PYTHONHOME / PYTHONPATH / 代理透传）
        setenv("PYTHONHOME", home, 1)
        // PYTHONPATH 两个路径：
        //   - python-home 根：spider_runner.py / src/ / pylib/
        //   - <home>/lib/python3.12/site-packages：CI pip --target 装的三件套
        let sitePath = "\(home)/lib/python3.12/site-packages"
        setenv("PYTHONPATH", "\(home):\(sitePath)", 1)
        if let proxy = ProcessInfo.processInfo.environment["ALL_PROXY"],
           !proxy.isEmpty {
            setenv("https_proxy", proxy, 1)
            setenv("http_proxy", proxy, 1)
            print("[PythonBridge] Python 代理已注入: \(proxy)")
        }

        // 3. 初始化解释器（本函数在 workQueue 执行，主线程外的串行上下文，
        //    Py_Initialize 一次性持有 GIL；后续所有调用都在同一队列 → GIL 串行）
        Py_Initialize()
        // 4. 导入适配层（spider_runner.py 在 python-home 根，PYTHONPATH 可达）
        guard let module = PyImport_ImportModule("spider_runner") else {
            print("[PythonBridge] ❌ 导入 spider_runner 失败: \(pyLastErrorString() ?? "未知错误")")
            started = false
            return false
        }
        mainModule = module
        started = true
        print("[PythonBridge] ✅ CPython \(pyVersionString()) 就绪")
        return true
    }

    // ============================================================
    // eval / call
    // ============================================================

    private func eval(code: String) -> [String: Any] {
        guard started, let module = mainModule else {
            return ["ok": false, "error": "Python 未启动"]
        }
        // PyRun_String 的 globals/locals 必须是 **dict**；
        // 传模块对象会报 "globals must be a dict"。用 PyModule_GetDict 取模块命名空间
        // （borrowed reference，不需 DecRef）。
        let globals = PyModule_GetDict(module)
        guard let globals = globals else {
            return ["ok": false, "error": "无法获取模块命名空间"]
        }
        // 每轮 eval 前重置超时截止（返回路径统一取消 watchdog）
        resetDeadline()
        defer { cancelDeadline() }
        // 捕获 stdout：把 sys.stdout 换成 io.StringIO
        // ⚠️ `PyObject_CallMethod` 在 CPython 头里是 varargs 宏
        //    （`#define PyObject_CallMethod _PyObject_CallMethod_SizeT`），
        //    Swift 明确不可用（CI: 'PyObject_CallMethod' is unavailable: Variadic
        //    function is unavailable）⇒ 一律走 pyCallNoArg / pyCall3Strings
        //    （GetAttrString + CallObject，全部是普通函数）
        let oldOut = PySys_GetObject("stdout")
        let stringIO = PyImport_ImportModule("io")
        let buffer = pyCallNoArg(stringIO, "StringIO")
        PySys_SetObject("stdout", buffer)
        defer {
            PySys_SetObject("stdout", oldOut)
        }
        let result = PyRun_String(code, Py_file_input, globals, globals)
        // 取捕获输出
        var output = ""
        if let buf = buffer {
            let val = pyCallNoArg(buf, "getvalue")
            output = pyObjectToString(val) ?? ""
            if let val = val { Py_DecRef(val) }
            Py_DecRef(buf)
        }
        Py_DecRef(stringIO)

        if result == nil {
            let err = pyLastErrorString() ?? "未知错误"
            PyErr_Clear()
            return ["ok": false, "error": err, "output": output]
        }
        defer { Py_DecRef(result) }
        return ["ok": true, "output": output]
    }

    private func call(module: String, method: String, argsJson: String) -> [String: Any] {
        guard started, let main = mainModule else {
            return ["ok": false, "error": "Python 未启动"]
        }
        resetDeadline()
        defer { cancelDeadline() }
        // 拼 args 为 JSON 字符串传给 Python 侧适配层（Python 自己 json.loads）
        // spider_runner.call(module, method, args_json)
        // ⚠️ `PyObject_CallMethod` 是 varargs 宏，Swift 调不了（见 eval 里的说明）
        //    ⇒ 手动拼 tuple + PyObject_CallObject
        let result = pyCall3Strings(main, "call", module, method, argsJson)
        if result == nil {
            let err = pyLastErrorString() ?? "未知错误"
            PyErr_Clear()
            return ["ok": false, "error": err]
        }
        defer { Py_DecRef(result) }
        let str = pyObjectToString(result) ?? "null"
        return ["ok": true, "result": str]
    }

    // ============================================================
    // 超时：watchdog + PyThreadState_SetAsyncExc
    // ============================================================

    /// 每轮 eval/call 前调用：记录执行线程的 PyThreadState + 启动 watchdog。
    /// SetAsyncExc 向目标线程抛 TimeoutError，解释器在下一个字节码边界检查
    /// async_exc —— `while True: pass` / `time.sleep` 循环都能被中断；
    /// 该 C API 不要求调用线程持有 GIL，watchdog 线程可直接调用。
    private func resetDeadline() {
        let now = Int64(DispatchTime.now().uptimeNanoseconds)
        let deadline = now + timeoutMs * 1_000_000
        PythonBridge.sharedDeadlineNanos = deadline
        // ⚠️ SetAsyncExc 要的是**线程 id**（unsigned long），不是 PyThreadState*。
        //    旧代码把 PyThreadState_Get() 的指针直接传进去 ⇒
        //    CI: "Cannot convert value of type 'OpaquePointer' to expected argument
        //    type 'UInt'"。用 PyThreadState_GetID 取 id。
        if let tstate = PyThreadState_Get() {
            PythonBridge.sharedExecTid = UInt(PyThreadState_GetID(tstate))
        } else {
            PythonBridge.sharedExecTid = 0
        }
        // 取消上一轮残留的 watchdog
        PythonBridge.sharedWatchdog?.cancel()
        let watchdog = DispatchWorkItem {
            PythonBridge.fireTimeout()
        }
        PythonBridge.sharedWatchdog = watchdog
        watchdogQueue.asyncAfter(
            deadline: .now() + .nanoseconds(Int(timeoutMs) * 1_000_000),
            execute: watchdog
        )
    }

    /// 取消本轮 watchdog（eval/call 正常返回后调用）
    private func cancelDeadline() {
        PythonBridge.sharedWatchdog?.cancel()
        PythonBridge.sharedWatchdog = nil
        PythonBridge.sharedDeadlineNanos = 0
    }

    /// watchdog 触发：向正在执行的线程抛 TimeoutError
    private static func fireTimeout() {
        let tid = PythonBridge.sharedExecTid
        guard tid != 0 else { return }
        // 不依赖调用线程持有 GIL（内部通过信号打断目标线程）
        // 签名：int PyThreadState_SetAsyncExc(unsigned long id, PyObject *exc)
        PyThreadState_SetAsyncExc(tid, PyExc_TimeoutError)
        print("[PythonBridge] ⏱ watchdog 触发：Python 脚本超时中断")
    }

    // ============================================================
    // 工具
    // ============================================================

    /// 调 `obj.name()`（无参）。
    /// 为什么不用 PyObject_CallMethod：它是 varargs 宏，Swift 不可用。
    private func pyCallNoArg(
        _ obj: UnsafeMutablePointer<PyObject>?,
        _ name: String
    ) -> UnsafeMutablePointer<PyObject>? {
        guard let obj = obj, let fn = PyObject_GetAttrString(obj, name) else { return nil }
        defer { Py_DecRef(fn) }
        return PyObject_CallObject(fn, nil)
    }

    /// 调 `obj.name(a, b, c)`（三个字符串参数）。
    /// 同理绕开 varargs：手动组 tuple 再 CallObject（PyTuple_SetItem 会接手引用，
    /// 失败时才需要自己 DecRef）。
    private func pyCall3Strings(
        _ obj: UnsafeMutablePointer<PyObject>?,
        _ name: String,
        _ a: String,
        _ b: String,
        _ c: String
    ) -> UnsafeMutablePointer<PyObject>? {
        guard let obj = obj, let fn = PyObject_GetAttrString(obj, name) else { return nil }
        defer { Py_DecRef(fn) }
        guard let args = PyTuple_New(3) else { return nil }
        defer { Py_DecRef(args) }
        let s1 = PyUnicode_FromString(a)
        if PyTuple_SetItem(args, 0, s1) != 0, let s1 = s1 { Py_DecRef(s1) }
        let s2 = PyUnicode_FromString(b)
        if PyTuple_SetItem(args, 1, s2) != 0, let s2 = s2 { Py_DecRef(s2) }
        let s3 = PyUnicode_FromString(c)
        if PyTuple_SetItem(args, 2, s3) != 0, let s3 = s3 { Py_DecRef(s3) }
        return PyObject_CallObject(fn, args)
    }

    private func pyObjectToString(_ obj: UnsafeMutablePointer<PyObject>?) -> String? {
        guard let obj = obj else { return nil }
        let utf8 = PyUnicode_AsUTF8String(obj)
        guard let utf8 = utf8 else { return nil }
        defer { Py_DecRef(utf8) }
        if let bytes = PyBytes_AsString(utf8) {
            return String(cString: bytes)
        }
        return nil
    }

    private func pyLastErrorString() -> String? {
        var ptype: UnsafeMutablePointer<PyObject>?
        var pvalue: UnsafeMutablePointer<PyObject>?
        var ptraceback: UnsafeMutablePointer<PyObject>?
        PyErr_Fetch(&ptype, &pvalue, &ptraceback)
        guard let value = pvalue else { return nil }
        defer {
            if let t = ptype { Py_DecRef(t) }
            if let v = pvalue { Py_DecRef(v) }
            if let tb = ptraceback { Py_DecRef(tb) }
        }
        return pyObjectToString(PyObject_Str(value))
    }

    private func pyVersionString() -> String {
        return String(cString: Py_GetVersion())
    }
}
