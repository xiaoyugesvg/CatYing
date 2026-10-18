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
    private var timeoutMs: Int64 = 25000
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
            // 碰 C API 就得持 GIL
            let gil = PyGILState_Ensure()
            Py_DecRef(m)
            PyGILState_Release(gil)
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

        // 1. 定位 stdlib 根（PYTHONHOME）
        //    ⚠️ 必须先**校验 <home>/lib/python3.12/encodings/__init__.py 存在**：
        //       PYTHONHOME 指错（或该目录里只有 lib-dynload、没有 encodings）时，
        //       Py_Initialize 会打 "Fatal Python error: init_fs_encoding..." 然后
        //       Py_ExitStatusException → exit(1)——进程当场死，Swift 侧拦不住
        //       （崩溃报告 Runner-2026-10-13-180034.ips：栈顶就是 Py_InitializeEx，
        //        随后在退出流程的 C++ finalizer 里二次崩 EXC_BAD_ACCESS at 0x60）。
        //       所以先在候选里挑一个**真的含 encodings** 的目录；挑不到就干净返回
        //       false（只打日志，不把进程交给 CPython 的 fatal 路径）。
        //
        //    ⚠️ 旧代码的回退 `Python.framework/Versions/3.12/lib` 在 iOS 上不存在
        //       （iOS 的 Python.framework 是扁平结构，没有 Versions/），一旦走到
        //       那个分支就是必崩 —— 已换成 xcframework 根（它自带 lib/python3.12）。
        let bundle = Bundle.main
        let candidates: [String] = [
            // ① CI 打包并塞进 bundle 的 python-home（stdlib + site-packages + 适配层）
            bundle.path(forResource: "python-home", ofType: nil, inDirectory: nil) ?? "",
            // ② 随包发布的 xcframework 自带的 stdlib
            //    （Runner.app/Frameworks/Python.xcframework/lib/python3.12）
            bundle.bundlePath + "/Frameworks/Python.xcframework",
        ]
        var pythonHome: String?
        for c in candidates where !c.isEmpty {
            if FileManager.default.fileExists(
                atPath: "\(c)/lib/python3.12/encodings/__init__.py") {
                pythonHome = c
                break
            }
        }
        guard let home = pythonHome else {
            print("[PythonBridge] ❌ 没有可用的 stdlib（需 <home>/lib/python3.12/encodings/__init__.py）"
                + "，候选：\(candidates)")
            return false
        }
        print("[PythonBridge] PYTHONHOME = \(home)")

        // 2. 环境变量（PYTHONHOME / PYTHONPATH / 代理透传）
        setenv("PYTHONHOME", home, 1)
        // PYTHONPATH 两个路径：
        //   - python-home 根：spider_runner.py / src/ / pylib/
        //   - <home>/lib/python3.12/site-packages：CI pip --target 装的常用库
        //     （requests / httpx / beautifulsoup4 / flask；lxml / pycryptodome /
        //       pyquery 由 pylib 下的纯 Python 垫片提供）
        let sitePath = "\(home)/lib/python3.12/site-packages"
        // 运行时兜底：把 xcframework（真机 slice）自带的 C 扩展目录也挂上 PYTHONPATH。
        // 为什么需要：标准库的 C 扩展（math / _socket / _ssl …）在两个地方各有一份，
        //   python-home/lib/python3.12/lib-dynload   ← CI 从 xcframework 拷过来的
        //   Frameworks/Python.xcframework/ios-arm64/lib-arm64/python3.12/lib-dynload  ← 框架自带(真机)
        // 只要 python-home 那份缺失、或被误拷成 simulator slice（.so 名是
        // `…-iphonesimulator.so`，真机只认 `…-iphoneos.so`），`import math/_socket`
        // 就会 ModuleNotFoundError（用户 2026-10-13 连续报的 'math' / '_socket'）。
        // 把框架那份也放进 sys.path，任一份可用即可 import 成功。
        let fwDynload = bundle.bundlePath
            + "/Frameworks/Python.xcframework/ios-arm64/lib-arm64/python3.12/lib-dynload"
        var pyPath = "\(home):\(sitePath)"
        if FileManager.default.fileExists(atPath: fwDynload) {
            pyPath += ":\(fwDynload)"
            print("[PythonBridge] C 扩展兜底路径已加入 PYTHONPATH: \(fwDynload)")
        }
        setenv("PYTHONPATH", pyPath, 1)
        if let proxy = ProcessInfo.processInfo.environment["ALL_PROXY"],
           !proxy.isEmpty {
            setenv("https_proxy", proxy, 1)
            setenv("http_proxy", proxy, 1)
            print("[PythonBridge] Python 代理已注入: \(proxy)")
        }

        // 3. 初始化解释器
        //    ⚠️ **GIL 必须在这里交还**（本轮修的那个 SIGABRT）：
        //       Py_Initialize() 会让**调用它的那个线程**持有 GIL。而这里是 GCD 的
        //       串行队列 —— 串行队列只保证"同一时刻只有一个 block 在跑"，**不保证
        //       同一个 OS 线程**（下一个 block 可能落在池里另一条线程上）。
        //       于是后面的 call()/eval() 在另一条线程上直接碰 Python C API：
        //         · PyGILState_Ensure() 之前没有任何线程状态 → PyThreadState_Get()
        //           直接 Py_FatalError("PyThreadState_Get: no current thread")
        //           → abort() → SIGABRT
        //         （崩溃报告 Runner-2026-10-13-201409.ips 的触发栈就是这么走的：
        //           PythonBridge.resetDeadline ← PythonBridge.call）
        //       ⇒ 标准嵌入姿势：init 完立刻 PyEval_SaveThread() 把 GIL 放掉，
        //         之后每个入口都用 PyGILState_Ensure()/Release() 成对包住。
        Py_Initialize()
        PyEval_SaveThread()
        // 4. 导入适配层（spider_runner.py 在 python-home 根，PYTHONPATH 可达）
        //    ⚠️ 上面刚放掉 GIL，所以这里必须先拿回来
        let gilInit = PyGILState_Ensure()
        let module = PyImport_ImportModule("spider_runner")
        if module == nil {
            let msg = pyLastErrorString() ?? "未知错误"
            PyGILState_Release(gilInit)
            print("[PythonBridge] ❌ 导入 spider_runner 失败: \(msg)")
            started = false
            return false
        }
        mainModule = module
        started = true
        // ⚠️ 版本串也是 C API 调用，必须在 Release 之前取
        let ver = pyVersionString()
        PyGILState_Release(gilInit)
        print("[PythonBridge] ✅ CPython \(ver) 就绪")
        return true
    }

    // ============================================================
    // eval / call
    // ============================================================

    private func eval(code: String) -> [String: Any] {
        guard started, let module = mainModule else {
            return ["ok": false, "error": "Python 未启动"]
        }
        // 进入 Python：拿 GIL + 本线程的 thread state（成对释放，见 ensureStarted 注释）
        let gil = PyGILState_Ensure()
        defer { PyGILState_Release(gil) }
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
        // ⚠️ **必须**先拿到 GIL/线程状态再碰任何 Python C API
        //   （`resetDeadline()` 里要读 thread state；上一版就是在这里 abort 的）
        let gil = PyGILState_Ensure()
        defer { PyGILState_Release(gil) }
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
        //
        // ⚠️ 这里**绝对不能用 `PyThreadState_Get()`**：它在本线程没有线程状态时
        //    会直接 `Py_FatalError` → abort（就是 201409.ips 那次 SIGABRT）。
        //    `PyGILState_GetThisThreadState()` 拿不到时**返回 nil**，不致命。
        //    调用方（eval/call）已经 PyGILState_Ensure() 过了，所以这里正常能拿到。
        if let tstate = PyGILState_GetThisThreadState() {
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
    ///
    /// 🔴 2026-10-13 崩溃根因（Runner-2026-10-13-230423.ips，EXC_BAD_ACCESS /
    ///    SIGSEGV，far=0x10，线程 com.tvbox.python.watchdog，帧
    ///    PyThreadState_SetAsyncExc +44）：
    ///    CPython 3.12 的 `PyThreadState_SetAsyncExc(unsigned long, PyObject*)`
    ///    内部走 `_PyInterpreterState_GET()` = `_PyThreadState_GET()->interp`
    ///    —— **要求调用线程自己有 PyThreadState**。watchdog 跑在 GCD 队列上、
    ///    没有线程状态 ⇒ 解引用 `NULL->interp`（偏移 0x10）⇒ 段错误。
    ///    而这一崩，App 进程被 SIGSEGV 直接杀死，NSUserDefaults 来不及落盘
    ///    ⇒「重启后音乐/阅读/弹幕/直播/小程序的设置全部丢失」。
    ///    ⇒ 必须先 `PyGILState_Ensure()` 取得线程状态再调用。
    ///    说明：目标线程若正持有 GIL，Ensure 会在它下一个字节码边界让出后拿到
    ///    （纯 Python 死循环也能拿到），超时中断依然生效，只是 watchdog 线程会
    ///    短暂等待。
    private static func fireTimeout() {
        let tid = PythonBridge.sharedExecTid
        guard tid != 0 else { return }
        // 解释器已销毁 / 未初始化时不能再碰 Python C API
        guard Py_IsInitialized() != 0 else { return }
        let gil = PyGILState_Ensure()
        // 签名：int PyThreadState_SetAsyncExc(unsigned long id, PyObject *exc)
        PyThreadState_SetAsyncExc(tid, PyExc_TimeoutError)
        PyGILState_Release(gil)
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
