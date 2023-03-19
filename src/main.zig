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

    wtext: [:0]const u16,
    font: *FontRef,

    visible: bool = true,
    color: u32 = 0x00ffffff, // https://learn.microsoft.com/en-us/windows/win32/gdi/colorref
    padLeft: i32 = 5,
    padRight: i32 = 5,

    fn getDefault() !*Block {
        if (default == null) {
            default = try gpalloc.create(Block);
            default.?.* = .{
                .wtext = try std.unicode.utf8ToUtf16LeWithNull(gpalloc, ""),
                .font = try FontRef.create("Arial", 24),
            };
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
    fn clone(self: *const Block) !*Block {
        var new = try gpalloc.create(Block);
        new.* = self.*;
        new.wtext = try gpalloc.dupeZ(u16, self.wtext);
        new.font.addRef();
        return new;
    }
    fn destroy(self: *Block) void {
        if (self == default) {
            std.log.err("Attempt to destroy default block", .{});
        }
        self.font.unRef();
        gpalloc.destroy(self);
    }
    fn setText(self: *Block, text: []const u8) !void {
        const new = try std.unicode.utf8ToUtf16LeWithNull(gpalloc, text);
        gpalloc.free(self.wtext);
        self.wtext = new;
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
        self.* = .{ .bar = undefined, .jsThread = undefined };
        self.bar = try BarWindow.create(self);
        self.jsThread = try std.Thread.spawn(.{}, jsThread, .{self});
        return self;
    }
    fn deinit(self: *BarManager) void {
        self.bar.destroy();
        self.jsThread.join();
        BarWindow.deinit();
        Block.destroyDefault();
    }

    /// Called by Window thread
    fn recreateBar(self: *BarManager) void {
        self.bar.destroy();
        self.bar = BarWindow.create(self) catch |ex2| {
            std.log.err("Unable to recreate {}", .{ex2});
            std.os.exit(1);
        };
    }

    /// Called by JS thread
    fn jsBeginUpdate(self: *BarManager) void {
        self.mutex.lock();
    }
    /// Called by JS thread
    fn jsEndUpdate(self: *BarManager) void {
        self.mutex.unlock();
        if (self.bar.wnd) |wnd| {
            _ = winwin.PostMessage(wnd, BarWindow.WM_WBLOCKS_UPDATE, 0, 0);
        }
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

    manager: *BarManager,

    taskbarWnd: winfon.HWND,
    trayWnd: winfon.HWND,
    drawSize: winfon.SIZE = std.mem.zeroes(winfon.SIZE),

    // Set once window has been created
    wnd: ?winfon.HWND = null,
    barBitmap: ?wingdi.HBITMAP = null,
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
        const taskbarWnd = winwin.FindWindowA("Shell_TrayWnd", null) orelse return error.TaskBarNotFound;
        const trayWnd = winwin.FindWindowExA(taskbarWnd, null, "TrayNotifyWnd", null) orelse return error.TaskBarNotFound;

        var self = try gpalloc.create(BarWindow);
        errdefer gpalloc.destroy(self);

        self.* = .{ .manager = manager, .taskbarWnd = taskbarWnd, .trayWnd = trayWnd };
        self.wnd = winwin.CreateWindowExA(.LAYERED, CLASS, TITLE, .OVERLAPPED, 0, 0, 0, 0, taskbarWnd, null, null, self) orelse return error.BarCreationFailed;
        return self;
    }
    fn initWindow(self: *BarWindow, wnd: winfon.HWND) void {
        // Set up *Bar reference
        self.wnd = wnd;
        _ = winwin.SetWindowLongPtrA(self.wnd, winwin.GWLP_USERDATA, @bitCast(isize, @ptrToInt(self)));
        _ = winwin.SetParent(self.wnd, self.taskbarWnd);

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
            std.log.err("Failed to update bar on creation: {}, exiting", .{err});
            std.os.exit(1);
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
            winwin.WM_CREATE => {
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
                        // TODO: bar.manager.deinit();
                        _ = bar;
                        std.os.exit(0);
                    }
                }
            },
            WM_WBLOCKS_UPDATE => blk: {
                var bar = fromWnd(wnd) catch {
                    std.log.err("Missing *BarWindow reference on window", .{});
                    break :blk;
                };
                bar.update() catch |ex| {
                    std.log.err("Bar update failed: {}. Recreating.", .{ex});
                    bar.manager.recreateBar();
                };
            },
            else => {},
        }
        return winwin.DefWindowProc(wnd, msg, wParam, lParam);
    }

    fn getSupposedSize(self: *BarWindow) !winfon.SIZE {
        var taskbarRect: winfon.RECT = undefined;
        if (winwin.GetWindowRect(self.taskbarWnd, &taskbarRect) == 0) {
            return error.TaskBarSizeError;
        }
        var trayRect: winfon.RECT = undefined;
        if (winwin.GetWindowRect(self.trayWnd, &trayRect) == 0) {
            return error.TaskBarSizeError;
        }
        return winfon.SIZE{
            .cx = (taskbarRect.right - taskbarRect.left) - (trayRect.right - trayRect.left),
            .cy = taskbarRect.bottom - taskbarRect.top,
        };
    }

    // On error, recreate window
    fn checkUpdate(self: *BarWindow) !void {
        // TODO
        _ = self;
        // var cmpRect: winfon.RECT = undefined;
        // if (winwin.GetWindowRect(self.taskbar, cmpRect) == 0) {
        //     return error.TaskBarSizeError;
        // }
        // if (!std.mem.eql(winfon.RECT, &cmpRect, self.taskbarRect)) {
        //     try self.update();
        // }
    }
    // On error, recreate window
    fn update(self: *BarWindow) !void {
        var pt = winfon.POINT{ .x = 0, .y = 0 };
        var sz = try self.getSupposedSize();
        std.log.debug("Pt: {},{} - Sz: {},{}", .{ pt.x, pt.y, sz.cx, sz.cy });

        // Create bitmap
        if (self.barBitmap == null or sz.cx != self.drawSize.cx or sz.cy != self.drawSize.cy) {
            std.log.debug("Creating bitmap", .{});
            self.drawSize = sz;
            if (self.barBitmap) |bm| {
                _ = wingdi.DeleteObject(bm);
            }
            self.barBitmap = wingdi.CreateCompatibleBitmap(self.screenDC, sz.cx, sz.cy);
            _ = wingdi.SelectObject(self.barDC, self.barBitmap);
        }

        // Draw blocks
        {
            std.log.debug("Drawing blocks", .{});
            self.manager.mutex.lock();
            defer self.manager.mutex.unlock();
            var rect = winfon.RECT{ .left = 0, .top = 0, .right = sz.cx, .bottom = sz.cy };
            _ = wingdi.SetBkMode(self.barDC, .TRANSPARENT);
            for (self.manager.blocks.items) |block| {
                if (block.visible) {
                    rect.right -= block.padRight;
                    _ = wingdi.SetTextColor(self.barDC, block.color);
                    _ = wingdi.SelectObject(self.barDC, block.font.handle);
                    const DTF = wingdi.DRAW_TEXT_FORMAT;
                    const drawFlags = @intToEnum(DTF, @enumToInt(DTF.NOCLIP) | @enumToInt(DTF.NOPREFIX) |
                        @enumToInt(DTF.SINGLELINE) | @enumToInt(DTF.RIGHT) | @enumToInt(DTF.VCENTER));
                    const calcFlags = @intToEnum(DTF, @enumToInt(drawFlags) | @enumToInt(DTF.CALCRECT));
                    _ = wingdi.DrawTextW(self.barDC, block.wtext, @intCast(i32, block.wtext.len), &rect, drawFlags);
                    var rectCalc = rect;
                    _ = wingdi.DrawTextW(self.barDC, block.wtext, @intCast(i32, block.wtext.len), &rectCalc, calcFlags);
                    rect.right -= rectCalc.right + block.padLeft;
                }
            }
        }

        // Update window
        var blendfn = wingdi.BLENDFUNCTION{
            .BlendOp = wingdi.AC_SRC_OVER,
            .BlendFlags = 0,
            .SourceConstantAlpha = 255,
            .AlphaFormat = wingdi.AC_SRC_ALPHA,
        };
        var ptSrc = std.mem.zeroes(winfon.POINT);
        _ = winwin.UpdateLayeredWindow(self.wnd, self.screenDC, &pt, &sz, self.barDC, &ptSrc, 0, &blendfn, .ALPHA);
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
        try js.addFunction(proto, "clone", js_BlockClone);
        try js.addFunction(proto, "destroy", js_BlockDestroy);
        try js.addFunction(proto, "setText", js_BlockSetText);
        // QJS_SET_PROP_FN(ctx, proto, "setFont", jsWrapBlockFn<jsBlockSetFont>, 2);
        // QJS_SET_PROP_FN(ctx, proto, "setText", jsWrapBlockFn<jsBlockSetText>, 1);
        // QJS_SET_PROP_FN(ctx, proto, "setColor", jsWrapBlockFn<jsBlockSetColor>, 3);
        // QJS_SET_PROP_FN(ctx, proto, "setPadding", jsWrapBlockFn<jsBlockSetPadding>, 2);
        // QJS_SET_PROP_FN(ctx, proto, "setVisible", jsWrapBlockFn<jsBlockSetVisible>, 1);
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

    fn jsGetThisBlock(self: *JSState, this: QJSC.JSValue) *Block {
        return @ptrCast(*Block, @alignCast(@alignOf(*Block), QJSC.JS_GetOpaque(this, self.blockClassId)));
    }
    fn jsCloneBlock(self: *JSState, block: *const Block) !QJSC.JSValue {
        self.manager.jsBeginUpdate();
        defer self.manager.jsEndUpdate();

        var clone = try block.clone();
        const obj = QJSC.JS_NewObjectClass(self.js.ctx, @intCast(c_int, self.blockClassId));
        QJSC.JS_SetOpaque(obj, clone);
        try self.manager.blocks.append(gpalloc, clone);

        return obj;
    }

    /// Polled by JS runtime to handle events from other threads on this
    fn js_yield(self: *JSState) void {
        // TODO
        _ = self;
    }
    fn js_createBlock(self: *JSState) !QJSC.JSValue {
        return self.jsCloneBlock(try Block.getDefault());
    }
    fn js_BlockClone(self: *JSState, this: QJSC.JSValue) !QJSC.JSValue {
        return self.jsCloneBlock(self.jsGetThisBlock(this));
    }
    fn js_BlockDestroy(self: *JSState, this: QJSC.JSValue) void {
        self.manager.jsBeginUpdate();
        defer self.manager.jsEndUpdate();

        var block = self.jsGetThisBlock(this);
        block.destroy();
        const idx = std.mem.indexOfScalar(*Block, self.manager.blocks.items, block);
        if (idx != null) {
            _ = self.manager.blocks.orderedRemove(idx.?);
        }
    }
    fn js_BlockSetText(self: *JSState, this: QJSC.JSValueConst, text: []const u8) !void {
        self.manager.jsBeginUpdate();
        defer self.manager.jsEndUpdate();

        var block = self.jsGetThisBlock(this);
        try block.setText(text);
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
