// QuickJS 环境下的 axios 垫片：直接复用宿主注入的 globalThis.axios
// （由 `book_js_prelude.ts` 里的 prelude 提供，底层走 sendMessage('book_http')）
const ax = globalThis.axios;
if (!ax) {
    throw new Error('QuickJS 宿主没有注入 axios（book prelude 未加载）');
}
export default ax;
