const std = @import("std");
pub const C = @cImport({
    @cInclude("quickjs.h");
    @cInclude("quickjs-libc.h");
});

pub fn QJS(comptime UserDataT: type) type {
    return struct {
        const Self = @This();

        pub const JSValue = C.JSValue;

        // NOTE: there's some translate-c bug so the #define JS_UNDEFINED doesn't work
        pub const JS_UNDEFINED = JSValue{ .tag = C.JS_TAG_UNDEFINED, .u = .{ .int32 = 0 } };

        rt: *C.JSRuntime,
        ctx: *C.JSContext,

        pub fn init(ud: *UserDataT) !Self {
            const rt = C.JS_NewRuntime() orelse return error.QuickJSInitFailure;
            errdefer C.JS_FreeRuntime(rt);
            C.js_std_set_worker_new_context_func(C.JS_NewContext);
            C.js_std_init_handlers(rt);
            C.JS_SetModuleLoaderFunc(rt, null, C.js_module_loader, null);

            const ctx = C.JS_NewContext(rt) orelse return error.QuickJSInitFailure;
            errdefer C.JS_FreeContext(ctx);
            C.JS_SetContextOpaque(ctx, ud);

            _ = C.js_init_module_std(ctx, "std");
            _ = C.js_init_module_os(ctx, "os");
            C.js_std_add_helpers(ctx, 0, null);

            return .{
                .rt = rt,
                .ctx = ctx,
            };
        }
        pub fn deinit(self: *Self) void {
            C.JS_FreeContext(self.ctx);
            C.JS_FreeRuntime(self.rt);
        }
        pub fn eval(self: *Self, codeZ: [:0]const u8, module: bool) !void {
            var retval = C.JS_Eval(self.ctx, codeZ.ptr, codeZ.len, "<eval>", if (module) C.JS_EVAL_TYPE_MODULE else C.JS_EVAL_TYPE_GLOBAL);
            defer C.JS_FreeValue(self.ctx, retval);
            try self.checkJSValue(retval);
        }

        fn checkJSValue(self: *Self, jsv: JSValue) !void {
            if (C.JS_IsException(jsv) != 0) {
                var exval = C.JS_GetException(self.ctx);
                defer C.JS_FreeValue(self.ctx, exval);
                var str = C.JS_ToCString(self.ctx, exval);
                defer C.JS_FreeCString(self.ctx, str);
                std.log.err("JS Exception: {s}", .{str});
                return error.JSException;
            }
        }

        fn fnWrapRetVal(ctx: *C.JSContext, val: anytype) JSValue {
            const ValT = @TypeOf(val);
            if (ValT == void) {
                return JS_UNDEFINED;
            } else if (@typeInfo(ValT) == .ErrorUnion) {
                return fnWrapRetVal(ctx, val catch |err| {
                    return C.JS_ThrowTypeError(ctx, @errorName(err));
                });
            } else if (comptime std.meta.trait.isZigString(ValT)) {
                // TODO: null-terminator?
                return C.JS_NewString(ctx, val);
            } else if (comptime std.meta.trait.isFloat(ValT)) {
                return C.JS_NewFloat64(ctx, val);
            } else if (comptime (std.meta.trait.isSignedInt(ValT) or std.meta.trait.isUnsignedInt(ValT))) {
                return C.JS_NewInt64(ctx, @intCast(i64, val));
            } else if (ValT == bool) {
                return C.JS_NewBool(ctx, val);
            } else if (ValT == JSValue) {
                return val;
            } else {
                @compileError("Unknown type");
            }
        }
        pub fn addFunction(self: *Self, parent: JSValue, name: [:0]const u8, comptime func: anytype) !void {
            const T = @TypeOf(func);
            const TI = @typeInfo(T);
            if (TI != .Fn) {
                @compileError("bind expects a function");
            }
            const ArgsTup = std.meta.ArgsTuple(T);
            const argFields = std.meta.fields(ArgsTup);
            const argCount = argFields.len;
            const fnWrap = struct {
                fn wrap(ctx: ?*C.JSContext, this: C.JSValueConst, argc: c_int, argv: [*c]C.JSValueConst) callconv(.C) JSValue {
                    if (ctx == null) {
                        @panic("JSContext == null");
                    }
                    var callArgs: ArgsTup = undefined;
                    callArgs[0] = @ptrCast(*UserDataT, @alignCast(@alignOf(*UserDataT), C.JS_GetContextOpaque(ctx)));
                    if (argc + 1 != argCount) {
                        return C.JS_ThrowTypeError(ctx, "Invalid argument count");
                    }
                    defer {
                        inline for (1..argFields.len) |i| {
                            const ArgT = argFields[i].type;
                            if (comptime std.meta.trait.isZigString(ArgT)) {
                                C.JS_FreeCString(ctx, callArgs[i]);
                            }
                        }
                    }
                    inline for (1..argFields.len) |i| {
                        const ArgT = argFields[i].type;
                        if (comptime std.meta.trait.isZigString(ArgT)) {
                            if (C.JS_IsString(argv[i]) == 0) {
                                return C.JS_ThrowTypeError(ctx, "Invalid argument");
                            }
                            callArgs[i] = C.JS_ToCString(ctx, argv[i]);
                        } else if (comptime std.meta.trait.isNumber(ArgT)) {
                            if (C.JS_IsNumber(argv[i]) == 0) {
                                return C.JS_ThrowTypeError(ctx, "Invalid argument");
                            }
                            if (comptime std.meta.trait.isFloat(ArgT)) {
                                var val: f64 = undefined;
                                _ = C.JS_ToFloat64(ctx, &val, argv[i]);
                                callArgs[i] = @floatCast(ArgT, val);
                            } else {
                                var val: i64 = undefined;
                                _ = C.JS_ToInt64(ctx, &val, argv[i]);
                                callArgs[i] = @intCast(ArgT, val);
                            }
                        } else if (ArgT == bool) {
                            if (C.JS_IsBool(argv[i]) == 0) {
                                return C.JS_ThrowTypeError(ctx, "Invalid argument");
                            }
                            callArgs[i] = C.JS_VALUE_GET_BOOL(argv[i]) != 0;
                        } else if (ArgT == C.JSValueConst) { // Assume "this"
                            callArgs[i] = this;
                        } else {
                            @compileError("Unknown type");
                        }
                    }

                    return fnWrapRetVal(ctx.?, @call(.auto, func, callArgs));
                }
            }.wrap;
            const jsfn = C.JS_NewCFunction(self.ctx, fnWrap, name, argCount);
            _ = C.JS_SetPropertyStr(self.ctx, parent, name, jsfn);
        }
    };
}
