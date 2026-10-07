import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:quickjs_engine/javascript_runtime.dart';
import './xhr.dart';

var _fetchDebug = false;

setFetchDebug(bool value) => _fetchDebug = value;

/// 该扩展要读的 JS 资源路径（**目前只有这一个**）。
///
/// 集中成常量是为了「预加载」那一侧不会写错路径 —— 主 isolate 预加载时
/// 用的就是它（见 [preloadFetchJs]）。
const String kFetchJsAssetPath =
    'packages/quickjs_engine/assets/js/fetch.js';

/// 预加载好的 `fetch.js` 源码（**静态 = per-isolate**）。
///
/// ── 🔴 为什么必须有它（真机/桌面实测报错）──────────────────────────
/// `enableFetch()` 原来直接 `rootBundle.loadString(...)`，而
/// `rootBundle` 走的是 `ServicesBinding.instance` —— **binding 是 per-isolate 的**，
/// 后台 isolate（书源 runner worker）里**没有 binding** ⇒
/// ```
/// Unhandled exception: Binding has not yet been initialized.
///   #8 JavascriptRuntimeFetchExtension.enableFetch (…/extensions/fetch.dart:14)
///   #10 JsEngine.runtime (…/analyze/js_engine.dart:38)
///   #20 _runnerMain (…/web_book/runner_isolate.dart)
/// ```
/// ⇒ 凡是在 worker 里跑的书源 `@js` 规则（搜索/目录/正文）**全部失败** ✗
///（发现页能用，是因为它跑在主 isolate。）
///
/// ⚠️ `BackgroundIsolateBinaryMessenger.ensureInitialized(token)` 与
///    `DartPluginRegistrant.ensureInitialized()` **都解决不了** ——
///    messenger 通了，但 `ServicesBinding.instance` 这个 **binding 对象**
///    在后台 isolate 里仍然不存在（实测加了这两句照样报同一个错 16 次）。
///
/// 正解：**主 isolate 先把字符串读出来，经 `Isolate.spawn` 参数传进 worker**，
/// 再由 [preloadFetchJs] 写进这个静态字段 ✓。
/// 静态字段是 **per-isolate** 的，所以每个 worker 必须自己 preload 一次 ✓。
String? preloadedFetchJs;

/// 在 worker isolate 里调用：把主 isolate 传进来的 JS 源码存好。
///
/// 返回是否有可用内容（便于调用方打日志，不做异常）。
bool preloadFetchJs(String? js) {
  if (js == null || js.trim().isEmpty) return false;
  preloadedFetchJs = js;
  return true;
}

extension JavascriptRuntimeFetchExtension on JavascriptRuntime {
  Future<JavascriptRuntime> enableFetch() async {
    debug('Before enable xhr');
    enableXhr();
    debug('After enable xhr');

    // ── 三级取 fetch.js，**任何一级失败都不许抛** ─────────────────────
    //
    // ⚠️ 这个方法被 `getJavascriptRuntime` **不 await** 地调用
    //（`if (xhr) runtime.enableFetch();`）⇒ 一旦这里抛异常，
    //    就是一个**未捕获的异步异常**，而且会让 fetch polyfill **静默不注入** ✗。
    //    所以顺序是"能拿到就用，拿不到就退到内置常量"，绝不向上抛。
    final src = await _loadFetchJsSafely();
    debug('Loaded fetchPolyfill (${src.length} chars)');
    final evalFetchResult = evaluate(src);
    debug('Eval Fetch Result: $evalFetchResult');
    return this;
  }

  /// 按 **预加载 → rootBundle → 磁盘 → 内置常量** 的顺序取源码，永不抛。
  Future<String> _loadFetchJsSafely() async {
    // ① 预加载（worker isolate 的正路；主 isolate 也可能被上层填过）
    final pre = preloadedFetchJs;
    if (pre != null && pre.trim().isNotEmpty) return pre;

    // ② rootBundle（主 isolate 常规路径）
    try {
      final s = await rootBundle.loadString(kFetchJsAssetPath);
      if (s.trim().isNotEmpty) return s;
    } catch (e) {
      debug('rootBundle 读 fetch.js 失败: $e');
    }

    // ③ 磁盘兜底：桌面/测试环境里 assets 就在 exe 旁的
    //    `data/flutter_assets/<assetPath>`（`flutter test` 下也常能命中）
    try {
      final fromDisk = _readFetchJsFromDisk();
      if (fromDisk != null && fromDisk.trim().isNotEmpty) return fromDisk;
    } catch (e) {
      debug('磁盘读 fetch.js 失败: $e');
    }

    // ④ 内置常量：**最后一道**，保证 polyfill 一定被注入（不会静默失效）
    debug('全部来源都失败，改用内置的 fetch polyfill 常量');
    return kBundledFetchJs;
  }
}

/// 从磁盘找 `fetch.js`。
///
/// 覆盖三类常见落点（Windows 桌面 / Linux / macOS 的构建产物布局）：
///   · `<exe目录>/data/flutter_assets/<assetPath>`
///   · `<cwd>/build/flutter_assets/<assetPath>`（`flutter test` / 未打包时）
///   · `<cwd>/packages/quickjs_engine/assets/js/fetch.js`（仓库内直接跑）
String? _readFetchJsFromDisk() {
  final candidates = <String>[];

  // ① exe 旁
  try {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    candidates.add('$exeDir/data/flutter_assets/$kFetchJsAssetPath');
    candidates.add('$exeDir/flutter_assets/$kFetchJsAssetPath');
  } catch (_) {/* 某些平台取不到 exe 路径，忽略 */}

  // ② 当前工作目录（含 flutter test）
  try {
    final cwd = Directory.current.path;
    candidates.add('$cwd/build/flutter_assets/$kFetchJsAssetPath');
    candidates.add('$cwd/packages/quickjs_engine/assets/js/fetch.js');
    candidates.add('$cwd/../packages/quickjs_engine/assets/js/fetch.js');
  } catch (_) {/* 同上 */}

  for (final p in candidates) {
    try {
      final f = File(p);
      if (f.existsSync()) {
        final s = f.readAsStringSync();
        if (s.trim().isNotEmpty) return s;
      }
    } catch (_) {/* 单个候选失败不影响其它候选 */}
  }
  return null;
}

/// 内置的 fetch polyfill（与 `assets/js/fetch.js` 同源的精简版）。
///
/// ⚠️ 只在"预加载 / rootBundle / 磁盘"**三者都失败**时使用 ——
///    目的是**保证 fetch 一定存在**，避免书源脚本里 `fetch(...)`
///    直接 `ReferenceError`（那比"fetch 走不通"更难排查）。
///
/// 实现口径与 `assets/js/fetch.js` 保持一致：返回一个带 `ok/status/headers`
/// 与 `text()/json()` 的**Promise**对象，底层走已注入的 `XMLHttpRequest`（同步实现）。
const String kBundledFetchJs = r'''
// quickjs_engine 内置 fetch polyfill（兜底常量）
(function () {
  if (typeof globalThis.fetch === 'function') return;
  function makeHeaders(raw) {
    var map = {};
    (raw || '').split(/\r?\n/).forEach(function (line) {
      var i = line.indexOf(':');
      if (i > 0) map[line.slice(0, i).trim().toLowerCase()] = line.slice(i + 1).trim();
    });
    return {
      get: function (k) { var v = map[String(k).toLowerCase()]; return v === undefined ? null : v; },
      has: function (k) { return Object.prototype.hasOwnProperty.call(map, String(k).toLowerCase()); },
      forEach: function (fn) { for (var k in map) fn(map[k], k); }
    };
  }
  globalThis.fetch = function (url, options) {
    options = options || {};
    return new Promise(function (resolve, reject) {
      try {
        var xhr = new XMLHttpRequest();
        xhr.open(options.method || 'GET', url, false);
        var h = options.headers || {};
        for (var k in h) { try { xhr.setRequestHeader(k, h[k]); } catch (e) {} }
        xhr.send(options.body === undefined ? null : options.body);
        var text = xhr.responseText;
        resolve({
          ok: xhr.status >= 200 && xhr.status < 300,
          status: xhr.status,
          statusText: xhr.statusText || '',
          url: url,
          headers: makeHeaders(xhr.getAllResponseHeaders ? xhr.getAllResponseHeaders() : ''),
          text: function () { return Promise.resolve(text); },
          json: function () { return Promise.resolve(JSON.parse(text)); }
        });
      } catch (e) {
        reject(e);
      }
    });
  };
})();
''';

void debug(String message) {
  if (_fetchDebug) {
    debugPrint('JavascriptRuntimeFetchExtension: $message');
  }
}
