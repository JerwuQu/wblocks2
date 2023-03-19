const std = @import("std");

const C = @cImport({
    @cDefine("UNICODE", "1");
    @cInclude("windows.h");
    @cInclude("gdiplus/gdiplus.h");
});

const qjs = @import("./qjs.zig");
const QJSC = qjs.C;
const QJS = qjs.QJS;

var gpalloc: std.mem.Allocator = undefined;

fn gpAssert(comptime src: std.builtin.SourceLocation, status: C.GpStatus) void {
    if (status != 0) {
        std.log.err("GDI+ error: {d} ({s}@{s}:{d})", .{ status, src.fn_name, src.file, src.line });
        std.os.exit(1);
    }
}

const FontRef = struct {
    handle: *C.GpFont,
    refs: usize,

    // Create and add reference
    fn create(name: []const u8, size: isize) !*FontRef {
        const wname = try std.unicode.utf8ToUtf16LeWithNull(gpalloc, name);
        defer gpalloc.free(wname);

        // TODO
        var ff: ?*C.GpFontFamily = null;
        gpAssert(@src(), C.GdipGetGenericFontFamilySansSerif(&ff));
        var handle: ?*C.GpFont = null;
        gpAssert(@src(), C.GdipCreateFont(ff, @intToFloat(f32, size), C.FontStyleRegular, C.UnitPixel, &handle));

        var self = try gpalloc.create(FontRef);
        self.* = .{
            .handle = handle.?,
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
            // TODO _ = C.DeleteObject(self.handle);
            gpalloc.destroy(self);
        }
    }
};

const Block = struct {
    var default: ?*Block = null;

    wtext: [:0]const u16,
    font: *FontRef,

    visible: bool = true,
    padLeft: i32 = 5,
    padRight: i32 = 5,
    brush: ?*C.GpSolidFill = null,

    fn getDefault() !*Block {
        if (default == null) {
            default = try gpalloc.create(Block);
            default.?.* = .{
                .wtext = try std.unicode.utf8ToUtf16LeWithNull(gpalloc, ""),
                .font = try FontRef.create("Arial", 40),
            };
            gpAssert(@src(), C.GdipCreateSolidFill(0xffffffff, &default.?.brush));
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
            _ = C.PostMessageA(wnd, BarWindow.WM_WBLOCKS_UPDATE, 0, 0);
        }
    }
};

const BarWindow = struct {
    const TITLE = "wblocks bar";
    const CLASS = "WBLOCKS_BAR_CLASS";
    const WM_WBLOCKS_UPDATE = C.WM_USER + 1;
    const WM_WBLOCKS_TRAY = C.WM_USER + 2;
    const TRAY_MENU_SHOW_LOG = 1;
    const TRAY_MENU_RELOAD = 2;
    const TRAY_MENU_EXIT = 3;

    var trayIcon: C.HICON = undefined;

    manager: *BarManager,

    taskbarWnd: C.HWND,
    trayWnd: C.HWND,
    drawSize: C.SIZE = std.mem.zeroes(C.SIZE),

    // Set once window has been created
    wnd: ?C.HWND = null,
    barBitmap: ?C.HBITMAP = null,
    pvBits: [*c]u8 = null,
    screenDC: C.HDC = undefined,
    barDC: C.HDC = undefined,
    gfx: ?*C.GpGraphics = undefined,

    fn init() !void {
        // Reg class
        var wc = std.mem.zeroes(C.WNDCLASSEXA);
        wc.cbSize = @sizeOf(@TypeOf(wc));
        wc.lpfnWndProc = wndProc;
        wc.lpszClassName = CLASS;
        wc.hCursor = C.LoadCursorA(null, C.MAKEINTRESOURCEA(32512)); // IDC_ARROW
        if (C.RegisterClassExA(&wc) == 0) {
            return error.RegisterClassFailed;
        }

        // Alloc resources
        // TODO: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-createicon
        trayIcon = C.LoadIconA(null, C.MAKEINTRESOURCEA(32512)) orelse return error.LoadIconFailed; // IDI_APPLICATION
        errdefer _ = C.DestroyIconA(trayIcon);
    }
    fn deinit() void {
        _ = C.UnregisterClassA(CLASS, null);
        _ = C.DestroyIcon(trayIcon);
    }

    fn create(manager: *BarManager) !*BarWindow {
        const taskbarWnd = C.FindWindowA("Shell_TrayWnd", null) orelse return error.TaskBarNotFound;
        const trayWnd = C.FindWindowExA(taskbarWnd, null, "TrayNotifyWnd", null) orelse return error.TaskBarNotFound;

        var self = try gpalloc.create(BarWindow);
        errdefer gpalloc.destroy(self);

        self.* = .{ .manager = manager, .taskbarWnd = taskbarWnd, .trayWnd = trayWnd };
        const wexstyle = 0x00080000 | 0x00000020; // translate-c bug (C.WS_EX_LAYERED | C.WS_EX_TRANSPARENT)
        const wstyle = @as(c_longlong, 0x80000000) & ~@as(c_longlong, 0x00800000); // translate-c bug (C.WS_POPUP & ~C.WS_BORDER)
        self.wnd = C.CreateWindowExA(wexstyle, CLASS, TITLE, wstyle, 0, 0, 0, 0, taskbarWnd, null, null, self) orelse return error.BarCreationFailed;
        return self;
    }
    fn initWindow(self: *BarWindow, wnd: C.HWND) void {
        // Set up *Bar reference
        self.wnd = wnd;
        _ = C.SetWindowLongPtrA(self.wnd.?, C.GWLP_USERDATA, @bitCast(isize, @ptrToInt(self)));
        _ = C.SetParent(self.wnd.?, self.taskbarWnd);

        // Alloc resources
        self.screenDC = C.GetDC(null) orelse @panic("GetDC failed");
        self.barDC = C.CreateCompatibleDC(self.screenDC);
        gpAssert(@src(), C.GdipCreateFromHDC(self.barDC, &self.gfx));

        // Create tray icon
        var notifData = std.mem.zeroes(C.NOTIFYICONDATAA);
        notifData.cbSize = @sizeOf(@TypeOf(notifData));
        notifData.hWnd = wnd.?;
        notifData.uFlags = C.NIF_MESSAGE | C.NIF_ICON | C.NIF_TIP;
        notifData.uCallbackMessage = WM_WBLOCKS_TRAY;
        notifData.hIcon = trayIcon;
        std.mem.copy(u8, &notifData.szTip, "wblocks\x00");
        _ = C.Shell_NotifyIconA(C.NIM_ADD, &notifData);

        // Show and update
        _ = C.ShowWindow(wnd, C.SW_SHOW);
        self.update() catch |err| {
            std.log.err("Failed to update bar on creation: {}, exiting", .{err});
            std.os.exit(1);
        };
    }
    fn destroy(self: *BarWindow) void {
        if (self.wnd) |wnd| {
            _ = C.DeleteDC(self.barDC);
            _ = C.ReleaseDC(null, self.screenDC);

            var notifData = std.mem.zeroes(C.NOTIFYICONDATAA);
            notifData.cbSize = @sizeOf(@TypeOf(notifData));
            notifData.hWnd = wnd;
            _ = C.Shell_NotifyIconA(C.NIM_DELETE, &notifData);

            _ = C.SetWindowLongPtrA(wnd, C.GWLP_USERDATA, 0); // Prevent accessing *Bar later
            _ = C.DestroyWindow(wnd);
            self.wnd = null;

            gpalloc.destroy(self);
        }
    }
    fn fromWnd(wnd: C.HWND) !*BarWindow {
        const value = C.GetWindowLongPtrA(wnd, C.GWLP_USERDATA);
        if (value == 0) {
            return error.NoBarWindow;
        }
        return @intToPtr(*BarWindow, @bitCast(usize, value));
    }
    fn wndProc(wnd: C.HWND, msg: u32, wParam: usize, lParam: isize) callconv(.C) isize {
        switch (msg) {
            C.WM_CREATE => {
                var createData = @intToPtr(*C.CREATESTRUCTA, @bitCast(usize, lParam));
                var bar = @ptrCast(*BarWindow, @alignCast(@alignOf(*BarWindow), createData.lpCreateParams));
                bar.initWindow(wnd);
            },
            C.WM_NCDESTROY => blk: {
                var bar = fromWnd(wnd) catch break :blk;
                std.log.warn("wblocks BarWindow died, probably due to explorer.exe crashing", .{});
                bar.manager.recreateBar();
                return 0;
            },
            C.WM_PAINT => std.log.debug("Paint?", .{}),
            WM_WBLOCKS_TRAY => blk: {
                var bar = fromWnd(wnd) catch {
                    std.log.err("Missing *BarWindow reference on window", .{});
                    break :blk;
                };
                _ = bar;
                if ((lParam & 0xffff) == C.WM_LBUTTONUP or (lParam & 0xffff) == C.WM_RBUTTONUP) {
                    var pt: C.POINT = undefined;
                    _ = C.GetCursorPos(&pt);
                    var hmenu: C.HMENU = C.CreatePopupMenu() orelse break :blk;
                    const MF_BYPOSITION = 0x00000400; // NOTE: translate-c bug
                    _ = C.InsertMenuA(hmenu, 0, MF_BYPOSITION, TRAY_MENU_SHOW_LOG, "Show Log");
                    _ = C.InsertMenuA(hmenu, 1, MF_BYPOSITION, TRAY_MENU_RELOAD, "Reload");
                    _ = C.InsertMenuA(hmenu, 2, MF_BYPOSITION, TRAY_MENU_EXIT, "Exit");
                    _ = C.SetForegroundWindow(wnd);
                    const tpmFlags = 0x0020 | 0x0080 | 0x0100; // translate-c bug (C.TPM_BOTTOMALIGN | C.TPM_NONOTIFY | C.TPM_RETURNCMD)
                    const cmd = C.TrackPopupMenu(hmenu, tpmFlags, pt.x, pt.y, 0, wnd, null);
                    _ = C.PostMessageA(wnd, 0, 0, 0);

                    if (cmd == TRAY_MENU_SHOW_LOG) {
                        // TODO
                    } else if (cmd == TRAY_MENU_RELOAD) {
                        // TODO
                    } else if (cmd == TRAY_MENU_EXIT) {
                        // TODO: bar.manager.deinit();
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
        return C.DefWindowProcA(wnd, msg, wParam, lParam);
    }

    fn getSupposedSize(self: *BarWindow) !C.SIZE {
        var taskbarRect: C.RECT = undefined;
        if (C.GetWindowRect(self.taskbarWnd, &taskbarRect) == 0) {
            return error.TaskBarSizeError;
        }
        var trayRect: C.RECT = undefined;
        if (C.GetWindowRect(self.trayWnd, &trayRect) == 0) {
            return error.TaskBarSizeError;
        }
        return C.SIZE{
            .cx = (taskbarRect.right - taskbarRect.left) - (trayRect.right - trayRect.left),
            .cy = taskbarRect.bottom - taskbarRect.top,
        };
    }

    // On error, recreate window
    fn checkUpdate(self: *BarWindow) !void {
        var sz = try self.getSupposedSize();
        if (sz.cx != self.drawSize.cx or sz.cy != self.drawSize.cy) {
            try self.update();
        }
    }
    // On error, recreate window
    fn update(self: *BarWindow) !void {
        var pt = C.POINT{ .x = 0, .y = 0 };
        var sz = try self.getSupposedSize();
        std.log.debug("Pt: {},{} - Sz: {},{}", .{ pt.x, pt.y, sz.cx, sz.cy });

        // Create bitmap
        if (self.barBitmap == null or sz.cx != self.drawSize.cx or sz.cy != self.drawSize.cy) {
            std.log.debug("Creating bitmap", .{});
            self.drawSize = sz;
            if (self.barBitmap) |bm| {
                _ = C.DeleteObject(bm);
            }
            self.barBitmap = C.CreateCompatibleBitmap(self.screenDC, sz.cx, sz.cy);
            _ = C.SelectObject(self.barDC, self.barBitmap.?);
        }

        // Draw blocks
        {
            std.log.debug("Drawing blocks", .{});
            self.manager.mutex.lock();
            defer self.manager.mutex.unlock();
            var rect = C.RectF{ .X = 1000, .Y = 0, .Width = @intToFloat(f32, sz.cx), .Height = @intToFloat(f32, sz.cy) + 100 };
            for (self.manager.blocks.items) |block| {
                if (block.visible) {
                    rect.Width -= @intToFloat(f32, block.padRight);
                    var format: ?*C.GpStringFormat = null;
                    gpAssert(@src(), C.GdipStringFormatGetGenericDefault(&format));
                    gpAssert(@src(), C.GdipDrawString(self.gfx, block.wtext, @intCast(c_int, block.wtext.len), block.font.handle, &rect, format, block.brush));

                    // TODO: Remove this
                    var orect = C.RECT{ .left = 0, .top = 0, .right = sz.cx, .bottom = sz.cy };
                    _ = C.DrawTextW(self.barDC, block.wtext, @intCast(i32, block.wtext.len), &orect, 0);

                    // var rectCalc = rect;
                    // _ = C.DrawTextW(self.barDC, block.wtext, @intCast(i32, block.wtext.len), &rectCalc, calcFlags);
                    // rect.right -= rectCalc.right + block.padLeft;
                }
            }
        }

        // Update window
        var blendfn = C.BLENDFUNCTION{
            .BlendOp = C.AC_SRC_OVER,
            .BlendFlags = 0,
            .SourceConstantAlpha = 255,
            .AlphaFormat = C.AC_SRC_ALPHA,
        };
        var ptSrc = std.mem.zeroes(C.POINT);
        _ = C.UpdateLayeredWindow(self.wnd.?, self.screenDC, &pt, &sz, self.barDC, &ptSrc, 0, &blendfn, C.ULW_ALPHA);
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
    std.log.debug("Init", .{});
    const GPA = std.heap.GeneralPurposeAllocator(.{});
    var gpa = GPA{};
    gpalloc = gpa.allocator();
    defer _ = gpa.deinit();

    var gdiplusToken: c_ulonglong = 0;
    var gdiplusStartup = C.GdiplusStartupInput{
        .GdiplusVersion = 1,
        .DebugEventCallback = null,
        .SuppressBackgroundThread = 0,
        .SuppressExternalCodecs = 0,
    };
    gpAssert(@src(), C.GdiplusStartup(&gdiplusToken, &gdiplusStartup, null));
    defer C.GdiplusShutdown(gdiplusToken);

    var manager = try BarManager.init();
    defer manager.deinit();

    while (true) {
        try manager.bar.checkUpdate(); // TODO: move elsewhere

        var msg: C.MSG = undefined;
        while (C.PeekMessageA(&msg, null, 0, 0, C.PM_REMOVE) != 0) {
            _ = C.TranslateMessage(&msg);
            _ = C.DispatchMessageA(&msg);
        }

        std.time.sleep(10_000_000); // 10 ms
    }
}
