const std = @import("std");

const win32 = @import("win32");
const wingdi = win32.graphics.gdi;
const winfon = win32.foundation;
const winwin = win32.ui.windows_and_messaging;
const winshl = win32.ui.shell;

const qjs = @import("./qjs.zig");
const QJSC = qjs.C;
const QJS = qjs.QJS;

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
        if (default) |def| {
            def.font.unRef();
            gpalloc.destroy(def);
            default = null;
        }
    }
    fn clone(self: *Block) !*Block {
        var new = try gpalloc.create(Block);
        new.* = self.*;
        new.wtext = try self.wtext.clone(gpalloc);
        new.font.addRef();
        return new;
    }
    fn destroy(self: *Block) void {
        if (self == default) {
            std.log.err("Attempt to destroy default block");
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

const BarManager = struct {
    blocks: std.ArrayListUnmanaged(*Block) = .{},
    mutex: std.Thread.Mutex = .{},

    bar: *BarWindow,
    jsThread: std.Thread,

    fn init() !*BarManager {
        try BarWindow.init();
        var self = try gpalloc.create(BarManager);
        self.* = .{
            .bar = try BarWindow.create(self),
            .jsThread = try std.Thread.spawn(.{}, jsThread, .{self}),
        };
        return self;
    }
    fn deinit(self: *BarManager) void {
        self.bar.destroy();
        self.jsThread.join();
        BarWindow.deinit();
        Block.destroyDefault();
    }

    fn recreateBar(self: *BarManager) void {
        self.bar.destroy();
        self.bar = BarWindow.create(self) catch |ex2| {
            std.log.err("Unable to recreate {}", .{ex2});
            std.os.exit(1);
        };
    }
    fn beginUpdate(self: *BarManager) void {
        self.mutex.lock();
    }
    fn endUpdate(self: *BarManager) void {
        self.mutex.unlock();
        self.bar.update() catch |ex| {
            std.log.err("Bar update failed: {}. Recreating.", .{ex});
            self.recreateBar();
        };
    }
};

const BarWindow = struct {
    const TITLE = "wblocks bar";
    const CLASS = "WBLOCKS_BAR_CLASS";
    const WM_WBLOCKS_UPDATE = winwin.WM_USER + 1;
    const WM_WBLOCKS_TRAY = winwin.WM_USER + 2;
    const TRAY_MENU_SHOW_LOG = 1;
    const TRAY_MENU_RELOAD = 2;
    const TRAY_MENU_EXIT = 3;

    var trayIcon: winwin.HICON = undefined;

    taskbar: winfon.HWND,
    manager: *BarManager,
    taskbarRect: winfon.RECT = std.mem.zeroes(winfon.RECT),
    drawSize: winfon.SIZE = std.mem.zeroes(winfon.SIZE),

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

    fn create(manager: *BarManager) !*BarWindow {
        const tray = winwin.FindWindowA("Shell_TrayWnd", null) orelse return error.TaskBarNotFound;
        const taskbar = winwin.FindWindowExA(tray, null, "ReBarWindow32", null) orelse return error.TaskBarNotFound;

        var self = try gpalloc.create(BarWindow);
        errdefer gpalloc.destroy(self);

        self.* = .{ .manager = manager, .taskbar = taskbar };
        self.wnd = winwin.CreateWindowExA(.LAYERED, CLASS, TITLE, .OVERLAPPED, 0, 0, 0, 0, taskbar, null, null, self) orelse return error.BarCreationFailed;
        return self;
    }
    fn initWindow(self: *BarWindow, wnd: winfon.HWND) void {
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

        // Update
        self.update() catch |err| {
            std.log.err("Failed to update bar: {}", .{err});
            self.manager.recreateBar();
            return;
        };
    }
    fn destroy(self: *BarWindow) void {
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
    fn fromWnd(wnd: winfon.HWND) !*BarWindow {
        const value = winwin.GetWindowLongPtrA(wnd, winwin.GWLP_USERDATA);
        if (value == 0) {
            return error.NoBarWindow;
        }
        return @intToPtr(*BarWindow, @bitCast(usize, value));
    }
    fn wndProc(wnd: winfon.HWND, msg: u32, wParam: usize, lParam: isize) callconv(.C) isize {
        switch (msg) {
            winwin.WM_NCCREATE => {
                var createData = @intToPtr(*winwin.CREATESTRUCTA, @bitCast(usize, lParam));
                var bar = @ptrCast(*BarWindow, @alignCast(@alignOf(*BarWindow), createData.lpCreateParams));
                bar.initWindow(wnd);
            },
            winwin.WM_NCDESTROY => blk: {
                var bar = fromWnd(wnd) catch break :blk;
                std.log.warn("wblocks BarWindow died, probably due to explorer.exe crashing", .{});
                bar.manager.recreateBar();
                return 0;
            },
            WM_WBLOCKS_TRAY => blk: {
                var bar = fromWnd(wnd) catch {
                    std.log.err("Missing *BarWindow reference on window", .{});
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
                        bar.manager.deinit();
                        std.os.exit(0);
                    }
                }
            },
            else => {},
        }
        return winwin.DefWindowProc(wnd, msg, wParam, lParam);
    }

    // On error, destroy BarWindow
    fn checkUpdate(self: *BarWindow) !void {
        var cmpRect: winfon.RECT = undefined;
        if (winwin.GetWindowRect(self.taskbar, cmpRect) == 0) {
            return error.TaskBarSizeError;
        }
        if (!std.mem.eql(winfon.RECT, &cmpRect, self.taskbarRect)) {
            try self.update();
        }
    }
    // On error, destroy BarWindow
    fn update(self: *BarWindow) !void {
        // Get taskbar size
        if (winwin.GetWindowRect(self.taskbar, &self.taskbarRect) == 0) {
            return error.TaskBarSizeError;
        }
        const pt = winfon.POINT{
            .x = @divFloor(self.taskbarRect.right - self.taskbarRect.left, 2),
            .y = 0,
        };
        const sz = winfon.SIZE{
            .cx = @divFloor(self.taskbarRect.right - self.taskbarRect.left, 2),
            .cy = self.taskbarRect.bottom - self.taskbarRect.top,
        };
        std.log.debug("Pt: {},{} - Sz: {},{}", .{ pt.x, pt.y, sz.cx, sz.cy });

        // TODO: https://github.com/JerwuQu/wblocks2/blob/master/src/main.cpp#L152
    }
};

// Ran entirely on the JS thread
const JSState = struct {
    const JSStateQJS = QJS(JSState);

    js: JSStateQJS,
    manager: *BarManager,
    blockClassId: QJSC.JSClassID,

    fn run(manager: *BarManager) !void {
        var self = try gpalloc.create(JSState);
        defer gpalloc.destroy(self);
        var js = try JSStateQJS.init(self);
        self.* = .{
            .js = js,
            .manager = manager,
            .blockClassId = 0,
        };

        defer js.deinit();
        const global = QJSC.JS_GetGlobalObject(js.ctx);
        defer QJSC.JS_FreeValue(js.ctx, global);

        // WB object
        const wb = QJSC.JS_NewObject(js.ctx);
        _ = QJSC.JS_SetPropertyStr(js.ctx, global, "wb", wb);

        // Internal object
        const wbInternal = QJSC.JS_NewObject(js.ctx);
        _ = QJSC.JS_SetPropertyStr(js.ctx, wb, "internal", wbInternal);
        try js.addFunction(wbInternal, "yield", js_yield);

        // Register Block class
        _ = QJSC.JS_NewClassID(&self.blockClassId);
        var jsBlockClass = std.mem.zeroes(QJSC.JSClassDef);
        jsBlockClass.class_name = "Block";
        _ = QJSC.JS_NewClass(js.rt, self.blockClassId, &jsBlockClass);

        // Block class prototype
        const proto = QJSC.JS_NewObject(js.ctx);
        // QJS_SET_PROP_FN(ctx, proto, "setFont", jsWrapBlockFn<jsBlockSetFont>, 2);
        // QJS_SET_PROP_FN(ctx, proto, "setText", jsWrapBlockFn<jsBlockSetText>, 1);
        // QJS_SET_PROP_FN(ctx, proto, "setColor", jsWrapBlockFn<jsBlockSetColor>, 3);
        // QJS_SET_PROP_FN(ctx, proto, "setPadding", jsWrapBlockFn<jsBlockSetPadding>, 2);
        // QJS_SET_PROP_FN(ctx, proto, "setVisible", jsWrapBlockFn<jsBlockSetVisible>, 1);
        // QJS_SET_PROP_FN(ctx, proto, "clone", jsWrapBlockFn<jsBlockClone>, 1);
        // QJS_SET_PROP_FN(ctx, proto, "remove", jsWrapBlockFn<jsBlockRemove>, 0);
        QJSC.JS_SetClassProto(js.ctx, self.blockClassId, proto);

        // Create default block
        const jsDefaultBlock = QJSC.JS_NewObjectClass(js.ctx, @intCast(c_int, self.blockClassId));
        QJSC.JS_SetOpaque(jsDefaultBlock, try Block.getDefault());
        _ = QJSC.JS_SetPropertyStr(js.ctx, wb, "default", jsDefaultBlock);

        // Main API
        try js.addFunction(wb, "createBlock", js_createBlock);
        // QJS_SET_PROP_FN(ctx, wb, "$", jsShell, 1);

        // Load JS
        try js.eval(@embedFile("lib.mjs"), true);

        // Start event loop
        QJSC.js_std_loop(js.ctx);

        std.log.err("Unexpected js_std_loop end", .{});
    }

    /// Polled by JS runtime to handle events from other threads on this
    fn js_yield(self: *JSState) void {
        // TODO
        _ = self;
    }

    fn js_createBlock(self: *JSState) !QJSC.JSValue {
        var block = try (try Block.getDefault()).clone();
        const obj = QJSC.JS_NewObjectClass(self.js.ctx, @intCast(c_int, self.blockClassId));
        QJSC.JS_SetOpaque(obj, block);

        self.manager.beginUpdate();
        defer self.manager.endUpdate();
        try self.manager.blocks.append(gpalloc, block);

        return obj;
    }
};

fn jsThread(manager: *BarManager) void {
    JSState.run(manager) catch {
        std.log.err("Exiting due to JS thread error", .{});
        std.os.exit(1);
    };
}

pub fn main() !void {
    const GPA = std.heap.GeneralPurposeAllocator(.{});
    var gpa = GPA{};
    gpalloc = gpa.allocator();
    defer _ = gpa.deinit();

    var manager = BarManager.init();
    defer manager.deinit();

    while (true) {
        var msg: winwin.MSG = undefined;
        while (winwin.PeekMessage(&msg, null, 0, 0, .REMOVE) != 0) {
            _ = winwin.TranslateMessage(&msg);
            _ = winwin.DispatchMessage(&msg);
        }

        std.time.sleep(10_000_000); // 10 ms
    }
}
