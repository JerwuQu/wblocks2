const std = @import("std");
const C = @cImport({
    @cInclude("quickjs/quickjs.h");
    @cInclude("quickjs/quickjs-libc.h");
});

const JS = struct {
    rt: *C.JSRuntime,
    ctx: *C.JSContext,

    fn init() !JS {
        const rt = C.JS_NewRuntime() orelse return error.QuickJSInitFailure;
        errdefer C.JS_FreeRuntime(rt);

        const ctx = C.JS_NewContext(rt) orelse return error.QuickJSInitFailure;
        errdefer C.JS_FreeContext(ctx);

        _ = C.js_init_module_std(ctx, "std");
        _ = C.js_init_module_os(ctx, "os");
        C.js_std_add_helpers(ctx, 0, null);

        return .{
            .rt = rt,
            .ctx = ctx,
        };
    }
    fn deinit(self: *JS) void {
        C.JS_FreeContext(self.ctx);
        C.JS_FreeRuntime(self.rt);
    }
    fn eval(self: *JS, str: []const u8) !void {
        // TODO: make sure there's a null-terminator
        var retval = C.JS_Eval(self.ctx, str.ptr, str.len, "<eval>", C.JS_EVAL_TYPE_GLOBAL);
        defer C.JS_FreeValue(self.ctx, retval);
        try self.checkJSValue(retval);
    }

    fn checkJSValue(self: *JS, jsv: C.JSValue) !void {
        if (C.JS_IsException(jsv) != 0) {
            var exval = C.JS_GetException(self.ctx);
            defer C.JS_FreeValue(self.ctx, exval);
            var str = C.JS_ToCString(self.ctx, exval);
            defer C.JS_FreeCString(self.ctx, str);
            std.log.err("JS Exception: {s}", .{str});
            return error.JSException;
        }
    }
};

pub fn main() !void {
    var js = try JS.init();
    defer js.deinit();
    try js.eval("console.log('Hello from JS')");
}
