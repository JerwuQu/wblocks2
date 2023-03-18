const std = @import("std");
const C = @cImport({
    @cInclude("quickjs.h");
    @cInclude("quickjs-libc.h");
});

const win32 = @import("win32");
const wingdi = win32.graphics.gdi;
const winfon = win32.foundation;
const winwin = win32.ui.windows_and_messaging;

var gpalloc: std.mem.Allocator = undefined;

// TODO: use std.atomic.Queue
// TODO: use std.Thread

const FontRef = struct {
    handle: wingdi.HFONT,
    refs: usize,

    // Create and add reference
    fn create(name: []const u8, size: isize) !*FontRef {
        const wname = try std.unicode.utf8ToUtf16LeWithNull(gpalloc, name);
        defer gpalloc.free(wname);
        const handle = wingdi.CreateFont(
            @intCast(i32, size),
            0,
            0,
            0,
            wingdi.FW_NORMAL,
            0,
            0,
            0,
            0,
            .DEFAULT_PRECIS,
            .DEFAULT_PRECIS,
            .DEFAULT_QUALITY,
            .DONTCARE,
            wname.ptr,
        ) orelse return error.CreateFontFailed;
        var self = try gpalloc.create(FontRef);
        self.* = .{
            .handle = handle,
            .refs = 1,
        };
        return self;
    }
    fn addRef(self: *FontRef) void {
        self.refs += 1;
    }
    fn unRef(self: *FontRef) void {
        self.refs -= 1;
        if (self.refs == 0) {
            _ = wingdi.DeleteObject(self.handle);
            gpalloc.destroy(self);
        }
    }
};

const Block = struct {
    var default: ?*Block = null;

    wtext: std.ArrayListUnmanaged(u16) = .{},
    font: *FontRef,

    visible: bool = true,
    color: u32 = 0x00ffffff, // https://learn.microsoft.com/en-us/windows/win32/gdi/colorref
    padLeft: usize = 5,
    padRight: usize = 5,

    fn getDefault() !*Block {
        if (default == null) {
            default = try gpalloc.create(Block);
            default.?.* = .{ .font = try FontRef.create("Arial", 32) };
        }
        return default.?;
    }
    fn destroyDefault() void {
        if (default != null) {
            default.?.destroy();
            default = null;
        }
    }
    fn clone(self: *Block) *Block {
        var new = gpalloc.dupe(Block, self);
        new.wtext = self.wtext.clone(gpalloc);
        new.font.addRef();
        return new;
    }
    fn destroy(self: *Block) void {
        if (self == default) {
            default = null;
        }
        self.font.unRef();
        gpalloc.destroy(self);
    }
    fn setText(self: *Block, text: []const u8) !void {
        self.wtext.clearRetainingCapacity(gpalloc);
        self.wtext.ensureTotalCapacity(gpalloc, text.len);
        var len = try std.unicode.utf8ToUtf16Le(self.wtext.items, text);
        self.wtext.shrinkRetainingCapacity(gpalloc, len);
    }
    fn setFont(self: *Block, name: []const u8, size: isize) !void {
        self.font.unRef();
        self.font = try FontRef.create(name, size);
    }
};

const BlockManager = struct {
    blocks: std.ArrayListUnmanaged(Block) = &.{},
    dirty: bool = true,
};

const Bar = struct {
    const TITLE = "wblocks bar";
    const CLASS = "WBLOCKS_BAR_CLASS";

    wnd: ?winfon.HWND = null,
    taskbar: winfon.HWND,
    screen_dc: wingdi.HDC,
    dc: wingdi.HDC,

    fn init() !void {
        // Reg class
        var wc = std.mem.zeroes(winwin.WNDCLASSEXA);
        wc.cbSize = @sizeOf(winwin.WNDCLASSEXA);
        wc.lpfnWndProc = wndProc;
        wc.lpszClassName = CLASS;
        wc.hCursor = winwin.LoadCursor(null, winwin.IDC_ARROW);
        if (winwin.RegisterClassExA(&wc) == 0) {
            return error.RegisterClassFailed;
        }
    }
    fn create() !*Bar {
        const tray = winwin.FindWindowA("Shell_TrayWnd", null) orelse return error.TaskBarNotFound;
        const taskbar = winwin.FindWindowExA(tray, null, "ReBarWindow32", null) orelse return error.TaskBarNotFound;

        var self = try gpalloc.create(Bar);
        errdefer gpalloc.destroy(self);
        const screen_dc = wingdi.GetDC(null) orelse return error.DCCreationFailed;
        self.* = .{
            .taskbar = taskbar,
            .screen_dc = screen_dc,
            .dc = wingdi.CreateCompatibleDC(screen_dc),
        };
        _ = winwin.CreateWindowExA(.LAYERED, CLASS, TITLE, .OVERLAPPED, 0, 0, 0, 0, taskbar, null, null, self) orelse return error.BarCreationFailed;
        return self;
    }
    fn destroy(self: *Bar) void {
        _ = wingdi.DeleteDC(self.dc);
        _ = wingdi.ReleaseDC(null, self.screen_dc);
        _ = winwin.DestroyWindow(self.wnd);
        gpalloc.destroy(self);
    }

    fn initWindow(self: *Bar, wnd: winfon.HWND) void {
        // Set up reference
        self.wnd = wnd;
        _ = winwin.SetWindowLongPtrA(self.wnd, winwin.GWLP_USERDATA, @bitCast(isize, @ptrToInt(self)));
        _ = winwin.SetParent(self.wnd, self.taskbar);
    }
    fn fromWnd(wnd: winfon.HWND) *Bar {
        const value = winwin.GetWindowLongPtrA(wnd, winwin.GWLP_USERDATA);
        if (value == 0) {
            std.log.warn("Empty UserData for window", .{});
        }
        return @intToPtr(*Bar, @bitCast(usize, value));
    }

    fn wndProc(wnd: winfon.HWND, msg: u32, wParam: usize, lParam: isize) callconv(.C) isize {
        std.log.debug("msg: {}", .{msg});
        switch (msg) {
            winwin.WM_NCCREATE => {
                var createData = @intToPtr(*winwin.CREATESTRUCTA, @bitCast(usize, lParam));
                std.log.debug("{}", .{createData.cx});
                var bar = @ptrCast(*Bar, @alignCast(@alignOf(*Bar), createData.lpCreateParams));
                bar.initWindow(wnd);
            },
            winwin.WM_NCDESTROY => {
                var bar = fromWnd(wnd);
                _ = bar; // TODO
            },
            else => {},
        }
        return winwin.DefWindowProc(wnd, msg, wParam, lParam);
    }
};

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
    fn eval(self: *JS, codeZ: [:0]const u8) !void {
        var retval = C.JS_Eval(self.ctx, codeZ.ptr, codeZ.len, "<eval>", C.JS_EVAL_TYPE_GLOBAL);
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

fn jsThreadErr() !void {
    var js = try JS.init();
    defer js.deinit();
    try js.eval("console.log('Hello from JS')");
}

fn jsThread() void {
    jsThreadErr() catch {
        std.log.err("Exiting due to JS thread error", .{});
        std.os.exit(1);
    };
}

pub fn main() !void {
    const GPA = std.heap.GeneralPurposeAllocator(.{});
    var gpa = GPA{};
    gpalloc = gpa.allocator();
    defer _ = gpa.deinit();

    try Bar.init();
    var bar = try Bar.create();
    defer bar.destroy();

    var thread = try std.Thread.spawn(.{}, jsThread, .{});
    defer thread.join();

    while (true) {
        var msg: winwin.MSG = undefined;
        while (winwin.PeekMessage(&msg, null, 0, 0, .REMOVE) != 0) {
            _ = winwin.TranslateMessage(&msg);
            _ = winwin.DispatchMessage(&msg);
        }

        std.time.sleep(10_000_000); // 10 ms
    }
}
