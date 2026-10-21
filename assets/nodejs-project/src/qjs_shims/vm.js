/**
 * QuickJS 的 `node:vm` 垫片。
 *
 * book_rule.js 用它来跑 `@js` 规则和 jsLib：
 *   const context = vm.createContext(sandbox);
 *   new vm.Script(code).runInContext(context);
 *
 * QuickJS 没有 Node 的 vm，这里用 `new Function` 模拟：
 *   · sandbox 里的键作为函数参数传进去（规则能读到 result / baseUrl / java…）
 *   · 脚本顶层 `function foo(){}` / `var foo=…` 在函数里是**局部**的，
 *     跨 Script 会丢 ⇒ 执行完把检测到的顶层声明**回写**到 context，
 *     这样 jsLib 定义的函数后续规则还能用（与 Legado 语义一致）
 *
 * ⚠️ 这是**实验实现**：不支持 vm 的 timeout / 真正的隔离。书源规则本来就
 *    来自用户导入的源，与 Node 版信任模型一致。
 */

const IDENT = /^[A-Za-z_$][A-Za-z0-9_$]*$/;

function collectTopLevelNames(code) {
    const names = new Set();
    const re = /(?:^|[\n;{}])\s*(?:function\s+([A-Za-z_$][\w$]*)|(?:var|let|const)\s+([A-Za-z_$][\w$]*))/g;
    let m;
    while ((m = re.exec(code)) !== null) {
        names.add(m[1] || m[2]);
    }
    return [...names].filter((n) => IDENT.test(n));
}

function execInContext(code, context) {
    const ctx = context || {};
    const keys = Object.keys(ctx).filter((k) => IDENT.test(k));
    const src = String(code == null ? '' : code);
    const names = collectTopLevelNames(src);
    const tail = names
        .map((n) => `try{if(typeof ${n}!=="undefined")__assign(${JSON.stringify(n)},${n});}catch(e){}`)
        .join('\n');
    const args = [...keys, '__assign'];
    // ⚠️ 用**直接 eval** 而不是把源码直接当函数体：
    //   1) eval 的**完成值**就是最后一条语句的值（Rhino 语义），规则才能取到结果；
    //      直接当函数体会被后面的 tail 语句吞掉返回值 → @js 永远返回 undefined。
    //   2) sloppy 模式下 eval 里的顶层 var / function 会落到本函数作用域，
    //      tail 才能把 jsLib 定义的函数回写到 context。
    // new Function 的 body 默认是 sloppy mode，允许隐式全局。
    const fn = new Function(
        ...args,
        `var __ret = eval(${JSON.stringify(src)});\n${tail}\nreturn __ret;`,
    );
    return fn(...keys.map((k) => ctx[k]), (n, v) => {
        ctx[n] = v;
    });
}

export function createContext(contextObject) {
    return contextObject || {};
}

export function runInContext(code, context) {
    return execInContext(code, context);
}

export class Script {
    constructor(code) {
        this.code = String(code == null ? '' : code);
    }
    runInContext(context) {
        return execInContext(this.code, context);
    }
    runInNewContext(context) {
        return execInContext(this.code, context);
    }
}

export default { createContext, runInContext, Script };
