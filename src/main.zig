const std = @import("std");
const C = @cImport({
    @cInclude("quickjs.h");
    @cInclude("quickjs-libc.h");
});

const win32 = @import("win32");
const wingdi = win32.graphics.gdi;
const winfon = win32.foundation;
const winwin = win32.ui.windows_and_messaging;
const winshl = win32.ui.shell;

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
        const new = try FontRef.create(name, size);
        self.font.unRef();
        self.font = new;
    }
};

const BlockManager = struct {
    blocks: std.ArrayListUnmanaged(Block) = &.{},
    dirty: bool = true,
};

const Bar = struct {
    const TITLE = "wblocks bar";
    const CLASS = "WBLOCKS_BAR_CLASS";
    const WM_WBLOCKS_TRAY = winwin.WM_USER + 1;
    const TRAY_MENU_SHOW_LOG = 1;
    const TRAY_MENU_RELOAD = 2;
    const TRAY_MENU_EXIT = 3;

    var trayIcon: winwin.HICON = undefined;

    taskbar: winfon.HWND,

    // Set once window has been created
    wnd: ?winfon.HWND = null,
    screenDC: wingdi.HDC = undefined,
    barDC: wingdi.HDC = undefined,

    fn init() !void {
        // Reg class
        var wc = std.mem.zeroes(winwin.WNDCLASSEXA);
        wc.cbSize = @sizeOf(@TypeOf(wc));
        wc.lpfnWndProc = wndProc;
        wc.lpszClassName = CLASS;
        wc.hCursor = winwin.LoadCursor(null, winwin.IDC_ARROW);
        if (winwin.RegisterClassExA(&wc) == 0) {
            return error.RegisterClassFailed;
        }

        // Alloc resources
        // TODO: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-createicon
        trayIcon = winwin.LoadIcon(null, winwin.IDI_APPLICATION) orelse return error.LoadIconFailed;
        errdefer _ = winwin.DestroyIcon(trayIcon);
    }
    fn deinit() void {
        _ = winwin.UnregisterClassA(CLASS, null);
        _ = winwin.DestroyIcon(trayIcon);
    }
    fn create() !*Bar {
        const tray = winwin.FindWindowA("Shell_TrayWnd", null) orelse return error.TaskBarNotFound;
        const taskbar = winwin.FindWindowExA(tray, null, "ReBarWindow32", null) orelse return error.TaskBarNotFound;

        var self = try gpalloc.create(Bar);
        errdefer gpalloc.destroy(self);

        self.* = .{ .taskbar = taskbar };
        self.wnd = winwin.CreateWindowExA(.LAYERED, CLASS, TITLE, .OVERLAPPED, 0, 0, 0, 0, taskbar, null, null, self) orelse return error.BarCreationFailed;
        return self;
    }
    fn initWindow(self: *Bar, wnd: winfon.HWND) void {
        // Set up *Bar reference
        self.wnd = wnd;
        _ = winwin.SetWindowLongPtrA(self.wnd, winwin.GWLP_USERDATA, @bitCast(isize, @ptrToInt(self)));
        _ = winwin.SetParent(self.wnd, self.taskbar);

        // Alloc resources
        self.screenDC = wingdi.GetDC(null) orelse @panic("GetDC failed");
        self.barDC = wingdi.CreateCompatibleDC(self.screenDC);

        // Create tray icon
        var notifData = std.mem.zeroes(winshl.NOTIFYICONDATAA);
        notifData.cbSize = @sizeOf(@TypeOf(notifData));
        notifData.hWnd = wnd;
        notifData.uFlags = @intToEnum(win32.ui.shell.NOTIFY_ICON_DATA_FLAGS, @enumToInt(winshl.NIF_MESSAGE) | @enumToInt(winshl.NIF_ICON) | @enumToInt(winshl.NIF_TIP));
        notifData.uCallbackMessage = WM_WBLOCKS_TRAY;
        notifData.hIcon = trayIcon;
        std.mem.copy(u8, &notifData.szTip, "wblocks\x00");
        _ = winshl.Shell_NotifyIconA(.ADD, &notifData);
    }
    fn destroy(self: *Bar) void {
        if (self.wnd == null) {
            return;
        }

        _ = wingdi.DeleteDC(self.barDC);
        _ = wingdi.ReleaseDC(null, self.screenDC);

        var notifData = std.mem.zeroes(winshl.NOTIFYICONDATAA);
        notifData.cbSize = @sizeOf(@TypeOf(notifData));
        notifData.hWnd = self.wnd;
        _ = winshl.Shell_NotifyIconA(.DELETE, &notifData);

        _ = winwin.SetWindowLongPtrA(self.wnd, winwin.GWLP_USERDATA, 0); // Prevent accessing *Bar later
        _ = winwin.DestroyWindow(self.wnd.?);
        self.wnd = null;

        gpalloc.destroy(self);
    }
    fn fromWnd(wnd: winfon.HWND) !*Bar {
        const value = winwin.GetWindowLongPtrA(wnd, winwin.GWLP_USERDATA);
        if (value == 0) {
            return error.NoBarWindow;
        }
        return @intToPtr(*Bar, @bitCast(usize, value));
    }
    fn wndProc(wnd: winfon.HWND, msg: u32, wParam: usize, lParam: isize) callconv(.C) isize {
        switch (msg) {
            winwin.WM_NCCREATE => {
                var createData = @intToPtr(*winwin.CREATESTRUCTA, @bitCast(usize, lParam));
                var bar = @ptrCast(*Bar, @alignCast(@alignOf(*Bar), createData.lpCreateParams));
                bar.initWindow(wnd);
            },
            winwin.WM_NCDESTROY => blk: {
                var bar = fromWnd(wnd) catch break :blk;
                std.log.warn("wblocks window died, probably due to explorer.exe crashing", .{});
                bar.destroy();
            },
            WM_WBLOCKS_TRAY => blk: {
                var bar = fromWnd(wnd) catch {
                    std.log.err("Missing *Bar reference on window", .{});
                    break :blk;
                };
                if ((lParam & 0xffff) == winwin.WM_LBUTTONUP or (lParam & 0xffff) == winwin.WM_RBUTTONUP) {
                    var pt: winfon.POINT = undefined;
                    _ = winwin.GetCursorPos(&pt);
                    var hmenu: winwin.HMENU = winwin.CreatePopupMenu() orelse break :blk;
                    const itemFlags = @intToEnum(winwin.MENU_ITEM_FLAGS, @enumToInt(winwin.MF_BYPOSITION) | @enumToInt(winwin.MF_STRING));
                    _ = winwin.InsertMenuA(hmenu, 0, itemFlags, TRAY_MENU_SHOW_LOG, "Show Log");
                    _ = winwin.InsertMenuA(hmenu, 1, itemFlags, TRAY_MENU_RELOAD, "Reload");
                    _ = winwin.InsertMenuA(hmenu, 2, itemFlags, TRAY_MENU_EXIT, "Exit");
                    _ = winwin.SetForegroundWindow(wnd);
                    const cmd = winwin.TrackPopupMenu(hmenu, winwin.TRACK_POPUP_MENU_FLAGS.initFlags(.{
                        .LEFTBUTTON = 1,
                        .BOTTOMALIGN = 1,
                        .NONOTIFY = 1,
                        .RETURNCMD = 1,
                    }), pt.x, pt.y, 0, wnd, null);
                    _ = winwin.PostMessage(wnd, 0, 0, 0);

                    if (cmd == TRAY_MENU_SHOW_LOG) {
                        // TODO
                    } else if (cmd == TRAY_MENU_RELOAD) {
                        // TODO
                    } else if (cmd == TRAY_MENU_EXIT) {
                        bar.destroy();
                        std.os.exit(0);
                    }
                }
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
    defer Bar.deinit();
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
