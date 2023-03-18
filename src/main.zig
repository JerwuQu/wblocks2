const std = @import("std");
const C = @cImport({
    @cInclude("quickjs/quickjs.h");
});

fn initJS() !void {
    std.log.debug("JS init", .{});

    const rt = C.JS_NewRuntime();
    if (rt == null) {
        return error.QuickJSInitFailure;
    }
    errdefer C.JS_FreeRuntime(rt);

    const ctx = C.JS_NewContext(rt);
    if (ctx == null) {
        return error.QuickJSInitFailure;
    }
    errdefer C.JS_FreeContext(ctx);

    std.log.debug("JS init OK", .{});
}

pub fn main() !void {
    try initJS();
}
