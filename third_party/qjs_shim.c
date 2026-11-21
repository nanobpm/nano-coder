// Narrow C shim over quickjs-ng for nano-coder's codemode spike.
// D sees only strings: host functions take a JSON array of arguments and
// return a JSON value (or an error message); eval returns the script's result
// as JSON. JSValue handling (inline refcounting macros) stays on this side.
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "quickjs.h"

typedef int (*qjs_host_fn)(void *ud, const char *name, const char *args, size_t args_len,
                           char **out, size_t *out_len);

typedef struct qjs_box {
    JSRuntime *rt;
    JSContext *ctx;
    qjs_host_fn host;
    void *ud;
    long long deadline_ms;
    volatile int *cancel;
    int timed_out;
} qjs_box;

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

static int interrupt(JSContext *rt, void *opaque) {
    qjs_box *b = opaque;
    (void)rt;
    if (b->cancel && *b->cancel) return 1;
    if (b->deadline_ms && now_ms() > b->deadline_ms) { b->timed_out = 1; return 1; }
    return 0;
}

// __host(name, argsJson) -> resultJson; throws Error(message) on failure.
static JSValue host_call(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    qjs_box *b = JS_GetContextOpaque(ctx);
    (void)this_val;
    if (argc < 2) return JS_ThrowTypeError(ctx, "__host(name, argsJson)");
    size_t nlen, alen;
    const char *name = JS_ToCStringLen(ctx, &nlen, argv[0]);
    const char *args = JS_ToCStringLen(ctx, &alen, argv[1]);
    if (!name || !args) {
        if (name) JS_FreeCString(ctx, name);
        if (args) JS_FreeCString(ctx, args);
        return JS_EXCEPTION;
    }
    char *out = NULL;
    size_t out_len = 0;
    int err = b->host(b->ud, name, args, alen, &out, &out_len);
    JS_FreeCString(ctx, name);
    JS_FreeCString(ctx, args);
    JSValue r;
    if (err) r = JS_ThrowPlainError(ctx, "%.*s", (int)out_len, out ? out : ""); // InternalError is uncatchable in quickjs-ng
    else r = JS_NewStringLen(ctx, out ? out : "null", out ? out_len : 4);
    free(out);
    return r;
}

qjs_box *qjs_new(size_t mem_limit, qjs_host_fn host, void *ud) {
    qjs_box *b = calloc(1, sizeof *b);
    if (!b) return NULL;
    b->rt = JS_NewRuntime();
    if (!b->rt) { free(b); return NULL; }
    if (mem_limit) JS_SetMemoryLimit(b->rt, mem_limit);
    JS_SetMaxStackSize(b->rt, 1 << 20);
    JS_SetInterruptHandler(b->rt, interrupt, b);
    b->ctx = JS_NewContext(b->rt);
    if (!b->ctx) { JS_FreeRuntime(b->rt); free(b); return NULL; }
    b->host = host;
    b->ud = ud;
    JS_SetContextOpaque(b->ctx, b);
    JSValue g = JS_GetGlobalObject(b->ctx);
    JS_SetPropertyStr(b->ctx, g, "__host", JS_NewCFunction(b->ctx, host_call, "__host", 2));
    JS_FreeValue(b->ctx, g);
    return b;
}

void qjs_free(qjs_box *b) {
    if (!b) return;
    JS_FreeContext(b->ctx);
    JS_FreeRuntime(b->rt);
    free(b);
}

static char *dup_len(const char *s, size_t n, size_t *out_len) {
    char *d = malloc(n + 1);
    if (!d) return NULL;
    memcpy(d, s, n);
    d[n] = 0;
    *out_len = n;
    return d;
}

// Format the pending exception as "Name: message\nstack".
static char *exception_text(JSContext *ctx, size_t *out_len) {
    JSValue ex = JS_GetException(ctx);
    const char *msg = JS_ToCString(ctx, ex);
    JSValue stack = JS_IsError(ex) ? JS_GetPropertyStr(ctx, ex, "stack") : JS_UNDEFINED;
    const char *st = JS_IsString(stack) ? JS_ToCString(ctx, stack) : NULL;
    size_t ml = msg ? strlen(msg) : 0, sl = st ? strlen(st) : 0;
    char *out = malloc(ml + sl + 2);
    size_t n = 0;
    if (out) {
        if (ml) { memcpy(out, msg, ml); n = ml; }
        if (sl) { out[n++] = '\n'; memcpy(out + n, st, sl); n += sl; }
        out[n] = 0;
    }
    if (st) JS_FreeCString(ctx, st);
    if (msg) JS_FreeCString(ctx, msg);
    JS_FreeValue(ctx, stack);
    JS_FreeValue(ctx, ex);
    *out_len = n;
    return out;
}

// Evaluate `code` (a script; top-level `return` is not allowed, so callers
// wrap the body in a function). Returns 0 with JSON.stringify(result) in
// *out, 1 with the error text, 2 on timeout, 3 when cancelled.
int qjs_eval(qjs_box *b, const char *code, size_t code_len, long long timeout_ms,
             volatile int *cancel, char **out, size_t *out_len) {
    *out = NULL;
    *out_len = 0;
    b->deadline_ms = timeout_ms > 0 ? now_ms() + timeout_ms : 0;
    b->cancel = cancel;
    b->timed_out = 0;
    JSContext *ctx = b->ctx;
    JSValue v = JS_Eval(ctx, code, code_len, "<run_script>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(v)) {
        int code_ = b->timed_out ? 2 : (cancel && *cancel) ? 3 : 1;
        *out = exception_text(ctx, out_len);
        return code_;
    }
    JSValue json = JS_JSONStringify(ctx, v, JS_UNDEFINED, JS_NewInt32(ctx, 2));
    JS_FreeValue(ctx, v);
    if (JS_IsException(json)) {
        *out = exception_text(ctx, out_len);
        return 1;
    }
    size_t n;
    const char *s = JS_IsUndefined(json) ? NULL : JS_ToCStringLen(ctx, &n, json);
    if (s) {
        *out = dup_len(s, n, out_len);
        JS_FreeCString(ctx, s);
    } else {
        *out = dup_len("undefined", 9, out_len);
    }
    JS_FreeValue(ctx, json);
    return 0;
}

void qjs_free_str(char *s) { free(s); }
