/**
 * 书源规则引擎的 **QuickJS 打包入口**（2026-10-21 实验）
 *
 * 复用 Node 侧同一套 book_source.js / book_rule.js（不重写规则逻辑），
 * 通过 esbuild 打成一份 IIFE，配合 `qjs_shims/`（axios / vm / crypto / Buffer）
 * 在 QuickJS 里执行。
 *
 * Dart 侧调用：
 *   __bookRun('bsSearch', '{"source":…,"keyword":…}')
 * 返回 Promise<string>（JSON 字符串），与 Node `/book/source` 的响应同形。
 */

import {
    bsSearch,
    bsBookInfo,
    bsToc,
    bsContent,
    bsLogin,
    bsExplore,
} from './book_source.js';

const ACTIONS = {
    bsSearch,
    bsBookInfo,
    bsToc,
    bsContent,
    bsLogin,
    bsExplore,
};

globalThis.__bookRun = function (action, payloadJson) {
    return new Promise(function (resolve) {
        try {
            const fn = ACTIONS[String(action)];
            if (!fn) {
                resolve(JSON.stringify({ ok: false, error: '未知 action: ' + action }));
                return;
            }
            let payload = {};
            try {
                payload = JSON.parse(payloadJson || '{}');
            } catch (e) {
                payload = {};
            }
            Promise.resolve(fn(payload)).then(
                function (r) {
                    resolve(JSON.stringify(r == null ? null : r));
                },
                function (e) {
                    resolve(
                        JSON.stringify({
                            ok: false,
                            error: '书源执行异常：' + ((e && e.message) || String(e)),
                        }),
                    );
                },
            );
        } catch (e) {
            resolve(
                JSON.stringify({
                    ok: false,
                    error: '书源执行异常：' + ((e && e.message) || String(e)),
                }),
            );
        }
    });
};
