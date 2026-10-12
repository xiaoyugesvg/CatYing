#include "quickjs/quickjs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <chrono>
#include <mutex>
#include <unordered_map>
#ifdef __ANDROID__
#include <android/log.h>
#else
#define __android_log_print(a, b, c, d)
#endif

#ifdef _MSC_VER
#define DLLEXPORT __declspec(dllexport)
#else
#define DLLEXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

int QUICKJS_RUNTIME_DEBUG_ENABLED = 0;

int ONE_VALUE = 0;

extern "C"
{

    // ── 求值墙钟超时（新增）──────────────────────────────────────────────
    // 背景：书源 JS 里一个 `while(true){}` 或病态正则会让 evaluate 永不返回，
    //   在主 isolate 上同步求值即冻死界面。原生侧此前**没有**装中断处理器
    //   （旧 jsNewRuntime 只收 channel 一个参数，Dart 侧传的 timeout 在 ABI 上
    //   被当作多余实参丢弃），所以这里补上真实现。
    //
    // 语义：jsSetEvalTimeout(rt, ms) 设「JS 执行预算」——
    //   · ms <= 0 ⇒ 清除预算，不限制（默认，行为与补丁前完全一致）
    //   · ms >  0 ⇒ 装入截止时间；QuickJS 在解释器循环里回调中断处理器，
    //               超时就抛可捕获的 "interrupted" 错误，而非卡死线程
    // 关键：宿主函数（Dart 侧 IO，如 java.ajax 抓网页）的等待**不计入**预算——
    //   js_channel / js_module_loader 每次宿主调用返回后都会重新计时
    //   （见 js_eval_rearm），所以合法的慢速网络请求不会被误杀。
    //
    // 按 JSRuntime 分别记账：同进程内多个 isolate 各持有独立 runtime，
    //   全局单值会互相踩，故用 map 键控 + 互斥锁保护。
    static std::mutex g_eval_timeout_mutex;
    static std::unordered_map<JSRuntime *, long long> g_eval_budget_ms;
    static std::unordered_map<JSRuntime *, long long> g_eval_deadline;

    static long long js_eval_now_ms()
    {
        using namespace std::chrono;
        return (long long)duration_cast<milliseconds>(
                   steady_clock::now().time_since_epoch())
            .count();
    }

    // 中断处理器：返回非 0 让 QuickJS 抛错。QuickJS 内部按指令间隔节流回调，
    // 这里的加锁开销可忽略。未设预算的 runtime 直接返回 0（完全无副作用）。
    static int js_eval_interrupt_handler(JSRuntime *rt, void *opaque)
    {
        std::lock_guard<std::mutex> lock(g_eval_timeout_mutex);
        auto it = g_eval_deadline.find(rt);
        if (it == g_eval_deadline.end())
            return 0;
        return js_eval_now_ms() > it->second ? 1 : 0;
    }

    // 宿主调用返回后重新计时：把「等待 Dart 侧 IO」的时间从预算里剔除。
    static void js_eval_rearm(JSRuntime *rt)
    {
        std::lock_guard<std::mutex> lock(g_eval_timeout_mutex);
        auto bit = g_eval_budget_ms.find(rt);
        if (bit == g_eval_budget_ms.end())
            return;
        g_eval_deadline[rt] = js_eval_now_ms() + bit->second;
    }

    DLLEXPORT int doReturnOne()
    {
        ONE_VALUE += 3;
        return ONE_VALUE;
    }
    DLLEXPORT JSRuntime *JS_NewRuntimeDartBridge(void)
    {
        JSRuntime *runtime = JS_NewRuntime();
        JS_SetGCThreshold(runtime, (size_t)-1); // disable GC - to prevent GC disallocate variables
                                                // yet in use in the Dart side
        JS_SetMemoryLimit(runtime, 0x4000000);  // 64 Mo
        //JS_SetMemoryLimit(runtime, -1); is the default
        return runtime;
    }

#define QUICKJS_CHANNEL_CONSOLELOG 0;
#define QUICKJS_CHANNEL_SETTIMEOUT 1;
#define QUICKJS_CHANNEL_SENDNATIVE 2;

    typedef JSValue *(*ChannelFunc)(const JSContext *ctx, const char *channel, const char *message);
    struct channel
    {
        char *name;
        JSContext *ctx;
        ChannelFunc func;
        int assigned;
    };

    struct channel channel_functions[10] = {/*{"cat", cat_func}, {"dog", dog_func}, {NULL, NULL}*/
                                            {NULL, NULL, 0},
                                            {NULL, NULL, 0},
                                            {NULL, NULL, 0},
                                            {NULL, NULL, 0},
                                            {NULL, NULL, 0},
                                            {NULL, NULL, 0},
                                            {NULL, NULL, 0},
                                            {NULL, NULL, 0},
                                            {NULL, NULL, 0},
                                            {NULL, NULL, 0}};

    // where cat_func is declared int cat_func(const char **args);.
    // You can search the list with

    int contextsLength = 0;

    static JSValue CChannelFunction(JSContext *ctx, JSValueConst this_val,
                                    int argc, JSValueConst *argv)
    {

        const char *channelName = JS_ToCString(ctx, argv[0]);
        const char *message = JS_ToCString(ctx, argv[1]);

        JSValue jsResult = JS_NULL;
        // while(cur->ctx) {
        //     //if(!strcmp(cur->name, channelName)) {
        //     if (cur->ctx == ctx && cur->assigned == 1) {
        //         JS_Eval(ctx, "console.log('Aqui no CChannelFunction3');", 40,"arquivo.js",0);
        //         result = cur->func(channelName, message);
        //         JS_Eval(ctx, "console.log('Aqui no CChannelFunction4');", 40,"arquivo.js",0);
        //         jsResult = JS_NewString(ctx, result);
        //         JS_Eval(ctx, "console.log('Aqui no CChannelFunction5');", 40,"arquivo.js",0);
        //     }
        // }

        int idxChannel = 0;
        if (strcmp("SendNative", channelName) == 0)
        {
            idxChannel = QUICKJS_CHANNEL_SENDNATIVE;
        }
        else if (strcmp("ConsoleLog", channelName) == 0)
        {
            idxChannel = QUICKJS_CHANNEL_CONSOLELOG;
        }
        if (strcmp("SetTimeout", channelName) == 0)
        {
            idxChannel = QUICKJS_CHANNEL_SETTIMEOUT;
        }

        if (channel_functions[idxChannel].assigned == 1)
        {
            ChannelFunc funcCaller = channel_functions[idxChannel].func;

            if (funcCaller != nullptr)
            {
                jsResult = *funcCaller(ctx, channelName, message);
            }
            else
            {
                jsResult = JS_NewString(ctx, "No function found");
            }
        }

        return jsResult;
    }

    JSValue stringifyFn;

    DLLEXPORT JSContext *JS_NewContextDartBridge(
        JSRuntime *rt,
        ChannelFunc consoleLogChannelFunction,
        ChannelFunc setTimeoutChannelFunction,
        ChannelFunc sendNativeChannelFunction)
    {
        JSContext *ctx;
        ctx = JS_NewContext(rt);

        // create the QuickJS Function passing the CChannelFunction ;
        // register the function jsBridgeFunction into the global object
        JSValue globalObject = JS_GetGlobalObject(ctx);

        stringifyFn = JS_Eval(
            ctx,
            "function simpleStringify(obj) { return JSON.stringify(obj);}simpleStringify;",
            strlen("function simpleStringify(obj) { return JSON.stringify(obj);}"),
            "f1.js",
            0);

        JS_SetPropertyStr(
            ctx,
            globalObject,
            "FLUTTER_JS_NATIVE_BRIDGE_sendMessage",
            JS_NewCFunction(ctx, CChannelFunction, "FLUTTER_JS_NATIVE_BRIDGE_sendMessage", 2));

        if (consoleLogChannelFunction)
        {
            channel_functions[0].func = consoleLogChannelFunction;
            channel_functions[0].ctx = ctx;
            channel_functions[0].name = (char *)"ConsoleLog";
            channel_functions[0].assigned = 1;

            channel_functions[1].func = setTimeoutChannelFunction;
            channel_functions[1].ctx = ctx;
            channel_functions[1].name = (char *)"SetTimeout";
            channel_functions[1].assigned = 1;

            // store in the function register the dartChannelFunction passed
            channel_functions[2].func = sendNativeChannelFunction;
            channel_functions[2].ctx = ctx;
            channel_functions[2].name = (char *)"SendNative";
            channel_functions[2].assigned = 1;

            contextsLength = 3;
        }

        // JS_FreeValue(ctx, globalObject);

        // JS_FreeValue(ctx, stringifyFn);

        // returns the generated context
        return ctx;
    }

    DLLEXPORT JSValue *copyToHeap(JSValueConst value)
    {
        auto *result = static_cast<JSValue *>(malloc(sizeof(JSValueConst)));
        if (result)
        {
            memcpy(result, &value, sizeof(JSValueConst));
        }
        return result;
    }
    DLLEXPORT const void *JSEvalWrapper(JSContext *ctx, const char *input, size_t input_len,
                                        const char *filename, int eval_flags,
                                        int *errors, JSValue *result, char **stringResult)
    {
        JSRuntime *rt = JS_GetRuntime(ctx);
        JS_UpdateStackTop(rt);

        // __android_log_print(ANDROID_LOG_DEBUG, "LOG_TAG", "Before Eval: %p", result);
        result = new JSValue(JS_Eval(ctx, input, input_len, filename, eval_flags));
        // __android_log_print(ANDROID_LOG_DEBUG, "LOG_TAG", "After Eval: %p", result);
        *errors = 0;

        if (JS_IsException(*result) == 1)
        {
            // __android_log_print(ANDROID_LOG_DEBUG, "LOG_TAG", "Inside is exception: %p", result);
            JS_FreeValue(ctx, *result);
            *errors = 1;
            * result = JS_GetException(ctx);
            *stringResult = (char *)JS_ToCString(ctx, *result);
            // __android_log_print(ANDROID_LOG_DEBUG, "LOG_TAG", "After get  exception: %p", result);
            return nullptr;
        }
        // __android_log_print(ANDROID_LOG_DEBUG, "LOG_TAG", "Before string result: %p", stringResult);
        *stringResult = (char *)JS_ToCString(ctx, *result);
        // __android_log_print(ANDROID_LOG_DEBUG, "LOG_TAG", "After string result: %p", stringResult);
        return nullptr;
    }

    DLLEXPORT void *JS_GetNullValue(JSContext *ctx, JSValue *result)
    {
        result = copyToHeap(JS_Eval(
            ctx,
            "null",
            4,
            "f1.js",
            0));
        return nullptr;
    }


    DLLEXPORT int32_t jsIsFunction(JSContext *ctx, JSValueConst *val)
    {
        return JS_IsFunction(ctx, *val);
    }

    // used in method callFunction in quickjs_method_bindings
    DLLEXPORT int callJsFunction1Arg(JSContext *ctx, JSValueConst *function, JSValueConst *object, JSValueConst *result, char **stringResult)
    {
        JSRuntime *rt = JS_GetRuntime(ctx);
        JS_UpdateStackTop(rt);
        JSValue globalObject = JS_GetGlobalObject(ctx);
        // JSValue function = JS_GetPropertyStr(ctx, globalObject, functionName);

        result = copyToHeap(JS_Call(ctx, *function, globalObject, 1, object));

        int successOperation = 1;

        if (JS_IsException(*result) == 1)
        {
            successOperation = 0;
            result = copyToHeap(JS_GetException(ctx));
        }
        *stringResult = (char *)JS_ToCString(ctx, *result);
        return successOperation;
    }

    DLLEXPORT int getTypeTag(JSValue *jsValue)
    {
        if (jsValue)
        {
            return JS_VALUE_GET_TAG(*jsValue);
        }
        else
        {
            return JS_TAG_NULL;
        }
    }

    DLLEXPORT int JS_IsArrayDartWrapper(JSContext *_unused_ctx, JSValueConst *val)
    {
        return JS_IsArray(*val);
    }

    DLLEXPORT int JS_JSONStringifyDartWrapper(
        JSContext *ctx,
        JSValue *obj, JSValueConst *result, char **stringResult)
    {
        if (QUICKJS_RUNTIME_DEBUG_ENABLED == 1)
        {
            __android_log_print(ANDROID_LOG_DEBUG, "LOG_TAG", "JS_JSONStringifyDartWrapper %p", result);
        }
        JSValue globalObject = JS_GetGlobalObject(ctx);
        if (QUICKJS_RUNTIME_DEBUG_ENABLED == 1)
        {
            __android_log_print(ANDROID_LOG_DEBUG, "LOG_TAG", "JS_JSONStringifyDartWrapper2 %p", result);
        }
        if (JS_IsUndefined(*obj) == 1)
        {
            if (QUICKJS_RUNTIME_DEBUG_ENABLED == 1)
            {
                __android_log_print(ANDROID_LOG_DEBUG, "LOG_TAG", "JS_JSONStringifyDartWrapper3 %p", result);
            }
            *stringResult = (char *)"undefined";
            return 0;
        }
        else if (JS_IsNull(*obj) == 1)
        {
            if (QUICKJS_RUNTIME_DEBUG_ENABLED == 1)
            {
                __android_log_print(ANDROID_LOG_DEBUG, "LOG_TAG", "JS_JSONStringifyDartWrapper4 %p", result);
            }
            *stringResult = (char *)"null";
            return 0;
        }
        else
        {
            if (QUICKJS_RUNTIME_DEBUG_ENABLED == 1)
            {
                __android_log_print(ANDROID_LOG_DEBUG, "LOG_TAG", "JS_JSONStringifyDartWrapper5 %p", result);
            }
            result = copyToHeap(JS_Call(ctx, stringifyFn, globalObject, 1, obj));
            *stringResult = (char *)JS_ToCString(ctx, *result);
            if (QUICKJS_RUNTIME_DEBUG_ENABLED == 1)
            {
                __android_log_print(ANDROID_LOG_DEBUG, "LOG_TAG", "JS_JSONStringifyDartWrapper6 %p", result);
            }
            return 1;
        }
    }

    enum JSChannelType
    {
        JSChannelType_METHON = 0,
        JSChannelType_MODULE = 1,
        JSChannelType_PROMISE_TRACK = 2,
        JSChannelType_FREE_OBJECT = 3,
    };

    typedef void *JSChannel(JSContext *ctx, size_t type, void *argv);

    DLLEXPORT JSValue *jsThrow(JSContext *ctx, JSValue *obj)
    {
        return new JSValue(JS_Throw(ctx, JS_DupValue(ctx, *obj)));
    }

    DLLEXPORT JSValue *jsEXCEPTION()
    {
        return new JSValue(JS_EXCEPTION);
    }

    DLLEXPORT JSValue *jsUNDEFINED()
    {
        return new JSValue(JS_UNDEFINED);
    }

    DLLEXPORT JSValue *jsNULL()
    {
        return new JSValue(JS_NULL);
    }

    JSModuleDef *js_module_loader(
        JSContext *ctx,
        const char *module_name, void *opaque)
    {
        JSRuntime *rt = JS_GetRuntime(ctx);
        JSChannel *channel = (JSChannel *)JS_GetRuntimeOpaque(rt);
        const char *str = (char *)channel(ctx, JSChannelType_MODULE, (void *)module_name);
        // 模块加载走 Dart 侧 IO ⇒ 返回后重新计时，等待不计入 JS 执行预算
        js_eval_rearm(rt);
        if (str == 0)
            return NULL;
        JSValue func_val = JS_Eval(ctx, str, strlen(str), module_name, JS_EVAL_TYPE_MODULE | JS_EVAL_FLAG_COMPILE_ONLY);
        if (JS_IsException(func_val))
            return NULL;
        /* the module is already referenced, so we must free it */
        JSModuleDef *m = (JSModuleDef *)JS_VALUE_GET_PTR(func_val);
        JS_FreeValue(ctx, func_val);
        return m;
    }

    JSValue js_channel(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *func_data)
    {
        JSRuntime *rt = JS_GetRuntime(ctx);
        JSChannel *channel = (JSChannel *)JS_GetRuntimeOpaque(rt);
        void *data[4];
        data[0] = &this_val;
        data[1] = &argc;
        data[2] = argv;
        data[3] = func_data;
        JSValue *ret = (JSValue *)channel(ctx, JSChannelType_METHON, data);
        // 宿主函数（Dart 侧同步 IO，如 java.ajax）返回后重新计时：
        // 网络等待不计入 JS 执行预算，避免合法的慢请求被超时误杀。
        js_eval_rearm(rt);
        return *ret;
    }

    void js_promise_rejection_tracker(JSContext *ctx, JSValueConst promise,
                                      JSValueConst reason,
                                      bool is_handled, void *opaque)
    {
        if (is_handled)
            return;
        JSRuntime *rt = JS_GetRuntime(ctx);
        JSChannel *channel = (JSChannel *)JS_GetRuntimeOpaque(rt);
        channel(ctx, JSChannelType_PROMISE_TRACK, &reason);
    }

    DLLEXPORT JSRuntime *jsNewRuntime(JSChannel channel)
    {
        JSRuntime *rt = JS_NewRuntime();
        JS_SetRuntimeOpaque(rt, (void *)channel);
        JS_SetHostPromiseRejectionTracker(rt, js_promise_rejection_tracker, nullptr);
        JS_SetModuleLoaderFunc(rt, nullptr, js_module_loader, nullptr);
        // 装中断处理器以支持求值超时。**默认未设预算 ⇒ 处理器恒返回 0，
        // 行为与补丁前完全一致**；只有 Dart 侧显式调用 jsSetEvalTimeout 才生效。
        JS_SetInterruptHandler(rt, js_eval_interrupt_handler, nullptr);
        return rt;
    }

    // 设置/清除本 runtime 的求值墙钟预算（毫秒）。ms <= 0 = 不限制。
    // Dart 侧每次 evaluate 前装入、求值后清除（见 QuickJsRuntime2.evaluate）。
    DLLEXPORT void jsSetEvalTimeout(JSRuntime *rt, long long ms)
    {
        std::lock_guard<std::mutex> lock(g_eval_timeout_mutex);
        if (ms <= 0)
        {
            g_eval_budget_ms.erase(rt);
            g_eval_deadline.erase(rt);
            return;
        }
        g_eval_budget_ms[rt] = ms;
        g_eval_deadline[rt] = js_eval_now_ms() + ms;
    }

    DLLEXPORT uint32_t jsNewClass(JSContext *ctx, const char *name)
    {
        JSClassID QJSClassId = 0;
        JSRuntime *rt = JS_GetRuntime(ctx);
        JS_NewClassID(rt, &QJSClassId);
        if (!JS_IsRegisteredClass(rt, QJSClassId))
        {
            JSClassDef def{
                name,
                // destructor
                [](JSRuntime *rt, JSValue obj) noexcept {
                    JSClassID classid = JS_GetClassID(obj);
                    void *opaque = JS_GetOpaque(obj, classid);
                    JSChannel *channel = (JSChannel *)JS_GetRuntimeOpaque(rt);
                    if (channel == nullptr)
                        return;
                    channel((JSContext *)rt, JSChannelType_FREE_OBJECT, opaque);
                }};
            int e = JS_NewClass(rt, QJSClassId, &def);
            if (e < 0)
            {
                JS_ThrowInternalError(ctx, "Cant register class %s", name);
                return 0;
            }
        }
        return QJSClassId;
    }

    DLLEXPORT void *jsGetObjectOpaque(JSValue *obj, uint32_t classid)
    {
        return JS_GetOpaque(*obj, classid);
    }

    DLLEXPORT JSValue *jsNewObjectClass(JSContext *ctx, uint32_t QJSClassId, void *opaque)
    {
        auto jsobj = new JSValue(JS_NewObjectClass(ctx, QJSClassId));
        if (JS_IsException(*jsobj))
            return jsobj;
        JS_SetOpaque(*jsobj, opaque);
        return jsobj;
    }
    DLLEXPORT void jsSetMaxStackSize(JSRuntime *rt, size_t stack_size)
    {
        JS_SetMaxStackSize(rt, stack_size);
    }

    DLLEXPORT void jsSetMemoryLimit(JSRuntime *rt, size_t limit)
    {
        JS_SetMemoryLimit(rt, limit);
    }

    DLLEXPORT void jsFreeRuntime(JSRuntime *rt)
    {
        // 先摘掉本 runtime 的超时记账，避免 map 里残留已释放的指针
        {
            std::lock_guard<std::mutex> lock(g_eval_timeout_mutex);
            g_eval_budget_ms.erase(rt);
            g_eval_deadline.erase(rt);
        }
        JS_SetRuntimeOpaque(rt, nullptr);
        JS_FreeRuntime(rt);
    }

    DLLEXPORT JSValue *jsNewCFunction(JSContext *ctx, JSValue *funcData)
    {
        return new JSValue(JS_NewCFunctionData(ctx, js_channel, 0, 0, 1, funcData));
    }

    DLLEXPORT JSContext *jsNewContext(JSRuntime *rt)
    {
        JSContext *ctx = JS_NewContext(rt);
        return ctx;
    }

    DLLEXPORT void jsFreeContext(JSContext *ctx)
    {
        JS_FreeContext(ctx);
    }

    DLLEXPORT JSRuntime *jsGetRuntime(JSContext *ctx)
    {
        return JS_GetRuntime(ctx);
    }

    DLLEXPORT JSValue *jsEval(JSContext *ctx, const char *input, size_t input_len, const char *filename, int32_t eval_flags)
    {
        JSRuntime *rt = JS_GetRuntime(ctx);
        JS_UpdateStackTop(rt);
        JSValue *ret = new JSValue(JS_Eval(ctx, input, input_len, filename, eval_flags));
        return ret;
    }

    DLLEXPORT int32_t jsValueGetTag(JSValue *val)
    {
        return JS_VALUE_GET_TAG(*val);
    }

    DLLEXPORT void *jsValueGetPtr(JSValue *val)
    {
        return JS_VALUE_GET_PTR(*val);
    }

    DLLEXPORT int32_t jsTagIsFloat64(int32_t tag)
    {
        return JS_TAG_IS_FLOAT64(tag);
    }

    DLLEXPORT JSValue *jsNewBool(JSContext *ctx, int32_t val)
    {
        return new JSValue(JS_NewBool(ctx, val));
    }

    DLLEXPORT JSValue *jsNewInt64(JSContext *ctx, int64_t val)
    {
        return new JSValue(JS_NewInt64(ctx, val));
    }

    DLLEXPORT JSValue *jsNewFloat64(JSContext *ctx, double val)
    {
        return new JSValue(JS_NewFloat64(ctx, val));
    }

    DLLEXPORT JSValue *jsNewString(JSContext *ctx, const char *str)
    {
        return new JSValue(JS_NewString(ctx, str));
    }

    DLLEXPORT JSValue *jsNewArrayBufferCopy(JSContext *ctx, const uint8_t *buf, size_t len)
    {
        return new JSValue(JS_NewArrayBufferCopy(ctx, buf, len));
    }

    DLLEXPORT JSValue *jsNewArray(JSContext *ctx)
    {
        return new JSValue(JS_NewArray(ctx));
    }

    DLLEXPORT JSValue *jsNewObject(JSContext *ctx)
    {
        return new JSValue(JS_NewObject(ctx));
    }

    DLLEXPORT void jsFreeValue(JSContext *ctx, JSValue *v, int32_t free)
    {
        JS_FreeValue(ctx, *v);
        if (free)
            delete v;
    }

    DLLEXPORT void jsFreeValueRT(JSRuntime *rt, JSValue *v, int32_t free)
    {
        JS_FreeValueRT(rt, *v);
        if (free)
            delete v;
    }

    DLLEXPORT JSValue *jsDupValue(JSContext *ctx, JSValueConst *v)
    {
        return new JSValue(JS_DupValue(ctx, *v));
    }

    DLLEXPORT JSValue *jsDupValueRT(JSRuntime *rt, JSValue *v)
    {
        return new JSValue(JS_DupValueRT(rt, *v));
    }

    DLLEXPORT int32_t jsToBool(JSContext *ctx, JSValueConst *val)
    {
        return JS_ToBool(ctx, *val);
    }

    DLLEXPORT int64_t jsToInt64(JSContext *ctx, JSValueConst *val)
    {
        int64_t p;
        JS_ToInt64(ctx, &p, *val);
        return p;
    }

    DLLEXPORT double jsToFloat64(JSContext *ctx, JSValueConst *val)
    {
        double p;
        JS_ToFloat64(ctx, &p, *val);
        return p;
    }

    DLLEXPORT const char *jsToCString(JSContext *ctx, JSValueConst *val)
    {
        JSRuntime *rt = JS_GetRuntime(ctx);
        JS_UpdateStackTop(rt);
        const char *ret = JS_ToCString(ctx, *val);
        return ret;
    }

    DLLEXPORT void jsFreeCString(JSContext *ctx, const char *ptr)
    {
        return JS_FreeCString(ctx, ptr);
    }

    DLLEXPORT uint8_t *jsGetArrayBuffer(JSContext *ctx, size_t *psize, JSValueConst *obj)
    {
        return JS_GetArrayBuffer(ctx, psize, *obj);
    }

    DLLEXPORT int32_t jsIsPromise(JSContext *_unused_ctx, JSValueConst *val)
    {
        return JS_IsPromise(*val);
    }

    DLLEXPORT int32_t jsIsArray(JSContext *_unused_ctx, JSValueConst *val)
    {
        return JS_IsArray(*val);
    }

    DLLEXPORT int32_t jsIsError(JSContext *_unused_ctx, JSValueConst *val)
    {
        return JS_IsError(*val);
    }

    DLLEXPORT JSValue *jsNewError(JSContext *ctx)
    {
        return new JSValue(JS_NewError(ctx));
    }

    DLLEXPORT JSValue *jsGetProperty(JSContext *ctx, JSValueConst *this_obj,
                                     JSAtom prop)
    {
        return new JSValue(JS_GetProperty(ctx, *this_obj, prop));
    }

    DLLEXPORT int32_t jsDefinePropertyValue(JSContext *ctx, JSValueConst *this_obj,
                                            JSAtom prop, JSValue *val, int32_t flags)
    {
        return JS_DefinePropertyValue(ctx, *this_obj, prop, *val, flags);
    }

    DLLEXPORT void jsFreeAtom(JSContext *ctx, JSAtom v)
    {
        JS_FreeAtom(ctx, v);
    }

    DLLEXPORT JSAtom jsValueToAtom(JSContext *ctx, JSValueConst *val)
    {
        return JS_ValueToAtom(ctx, *val);
    }

    DLLEXPORT JSValue *jsAtomToValue(JSContext *ctx, JSAtom val)
    {
        return new JSValue(JS_AtomToValue(ctx, val));
    }

    DLLEXPORT int32_t jsGetOwnPropertyNames(JSContext *ctx, JSPropertyEnum **ptab,
                                            uint32_t *plen, JSValueConst *obj, int32_t flags)
    {
        return JS_GetOwnPropertyNames(ctx, ptab, plen, *obj, flags);
    }

    DLLEXPORT JSAtom jsPropertyEnumGetAtom(JSPropertyEnum *ptab, int32_t i)
    {
        return ptab[i].atom;
    }

    DLLEXPORT uint32_t sizeOfJSValue()
    {
        return sizeof(JSValue);
    }

    DLLEXPORT void setJSValueList(JSValue *list, uint32_t i, JSValue *val)
    {
        list[i] = *val;
    }

    DLLEXPORT JSValue *jsCall(JSContext *ctx, JSValueConst *func_obj, JSValueConst *this_obj,
                              int32_t argc, JSValueConst *argv)
    {
        JSRuntime *rt = JS_GetRuntime(ctx);
        JS_UpdateStackTop(rt);
        JSValue *ret = new JSValue(JS_Call(ctx, *func_obj, *this_obj, argc, argv));
        return ret;
    }

    DLLEXPORT int32_t jsIsException(JSValueConst *val)
    {
        return JS_IsException(*val);
    }

    DLLEXPORT JSValue *jsGetException(JSContext *ctx)
    {
        return new JSValue(JS_GetException(ctx));
    }

    DLLEXPORT int32_t jsExecutePendingJob(JSRuntime *rt)
    {
        JS_UpdateStackTop(rt);
        JSContext *ctx;
        int ret = JS_ExecutePendingJob(rt, &ctx);
        return ret;
    }

    DLLEXPORT JSValue *jsNewPromiseCapability(JSContext *ctx, JSValue *resolving_funcs)
    {
        return new JSValue(JS_NewPromiseCapability(ctx, resolving_funcs));
    }

    DLLEXPORT void jsFree(JSContext *ctx, void *ptab)
    {
        js_free(ctx, ptab);
    }
}