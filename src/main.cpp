// TODO:
// - click handlers for blocks

// Require Windows 10
#define WINVER 0x0A00
#define _WIN32_WINNT 0x0A00

extern "C" {
#include <windows.h>
#include <assert.h>
#include <io.h>

#include <quickjs/quickjs.h>
#include <quickjs/quickjs-libc.h>

#define INCBIN_PREFIX
#define INCBIN_STYLE INCBIN_STYLE_SNAKE
#include "incbin.h"
INCTXT(wblocksLibMJS, "src/lib.mjs");
}

#include <vector>
#include <memory>
#include <algorithm>
#include <optional>
#include <thread>
#include <mutex>
#include <functional>

#define WBLOCKS_BAR_CLASS "wblocks2_bar"
#define WM_WBLOCKS_TRAY (WM_USER + 1)

#define TRAY_MENU_SHOW_LOG 1
#define TRAY_MENU_RESTART 2
#define TRAY_MENU_EXIT 3

#define WBLOCKS_MAX_LEN 1024

#define WBLOCKS_LOGFILE "wblocks.log"

#define QJS_SET_PROP_FN(ctx, obj, name, fn, len) \
	JS_SetPropertyStr(ctx, obj, name, JS_NewCFunction(ctx, fn, name, len))

JSClassID jsBlockClassId;
UINT_PTR createWindowTimer;
HINSTANCE hInst;

std::vector<std::pair<std::function<void(std::vector<void*>&)>, std::vector<void*>>> jsThreadQueue;
std::mutex jsThreadQueueMutex;

struct FontRef {
	HFONT handle;
	FontRef(HFONT handle) : handle(handle) {};
	~FontRef() {
		DeleteObject(handle);
	}
};

struct Block {
private:
	std::wstring text;
	std::shared_ptr<FontRef> font;

public:
	bool visible = true;
	COLORREF color = RGB(255, 255, 255);
	size_t padLeft = 5, padRight = 5;

	void setText(const std::string txt) {
		int required = MultiByteToWideChar(CP_UTF8, MB_PRECOMPOSED, txt.c_str(), txt.length(), nullptr, 0);
		assert(required >= 0);
		text.resize(required);
		assert(MultiByteToWideChar(CP_UTF8, MB_PRECOMPOSED, txt.c_str(), txt.length(), text.data(), required) == required);
	}

	// Returns true on success
	bool setFont(const std::string& fontName, int fontSize) {
		HFONT handle = CreateFont(fontSize, 0, 0, 0, FW_NORMAL, 0, 0, 0, 0, 0, 0, 0, 0, fontName.c_str());
		if (!handle) {
			return false;
		}
		font = std::make_shared<FontRef>(handle);;
		return true;
	}

	void drawBlock(HDC hdc, RECT *rect) const {
		if (visible) {
#ifdef DEBUG
			wprintf(L"Block, pos: %d, %d, text: %ls (%d)\n", rect->top, rect->right, text.c_str(), text.length());
#endif
			rect->right -= padRight;
			SetTextColor(hdc, color),
			SelectObject(hdc, font->handle);
			DrawTextW(hdc, text.c_str(), text.length(), rect,
					DT_NOCLIP | DT_NOPREFIX | DT_SINGLELINE | DT_RIGHT | DT_VCENTER);
			RECT rectCalc = { .right = rect->right, .bottom = rect->bottom };
			DrawTextW(hdc, text.c_str(), text.length(), &rectCalc,
					DT_NOCLIP | DT_NOPREFIX | DT_SINGLELINE | DT_RIGHT | DT_VCENTER | DT_CALCRECT);
			rect->right -= rectCalc.right + padLeft;
		}
	}
};

struct {
	HWND bar, wnd;
	HDC screenHDC, hdc;
	HBITMAP lastBitmap;
	SIZE lastSize;
	RECT barRect;
} wb;

struct BarBlocksState {
	std::vector<Block*> blocks;
	Block defaultBlock;
	bool needsUpdate;
	std::mutex mutex;
};
BarBlocksState barBlocks;

struct js_shell_thread_data {
	std::thread thread;
	JSValue resolveFn, rejectFn;
	JSContext *ctx;
	std::string cmd;

	bool success;
	std::string result;
};
const char *jsShellTempCmd;

void err(const char *err)
{
	fprintf(stderr, "wblocks error: %s\n", err);
}

void updateBlocks(HWND wnd)
{
	// Get taskbar size
	GetWindowRect(wb.bar, &wb.barRect);
	POINT pt = {
		.x = (wb.barRect.right - wb.barRect.left) / 2,
		.y = 0,
	};
	SIZE sz = {
		.cx = (wb.barRect.right - wb.barRect.left) / 2,
		.cy = wb.barRect.bottom - wb.barRect.top,
	};
#ifdef DEBUG
	printf("Redraw - Pos: %ld, %ld, Size: %ld, %ld\n", pt.x, pt.y, sz.cx, sz.cy);
#endif

	// Begin paint
	if (memcmp(&wb.lastSize, &sz, sizeof(sz))) {
		if (wb.lastBitmap) {
			DeleteObject(wb.lastBitmap);
		}
		wb.lastBitmap = CreateCompatibleBitmap(wb.screenHDC, sz.cx, sz.cy);
		SelectObject(wb.hdc, wb.lastBitmap);
	}
	RECT rect = { .right = sz.cx, .bottom = sz.cy };

	// Draw blocks
	SetBkMode(wb.hdc, TRANSPARENT);
	std::for_each(barBlocks.blocks.rbegin(), barBlocks.blocks.rend(), [&rect, &sz](const Block *block) {
		block->drawBlock(wb.hdc, &rect);
	});

	// Update
	POINT ptSrc = {0, 0};
	BLENDFUNCTION blendfn = {
		.BlendOp = AC_SRC_OVER,
		.SourceConstantAlpha = 255,
		.AlphaFormat = AC_SRC_ALPHA,
	};
	UpdateLayeredWindow(wnd, wb.screenHDC, &pt, &sz, wb.hdc, &ptSrc, 0, &blendfn, ULW_ALPHA);
}

void checkBarSize()
{
	if (wb.wnd) {
		RECT cmpRect;
		if (!GetWindowRect(wb.bar, &cmpRect)) {
			err("failed to get tray size");
			DestroyWindow(wb.wnd);
			return;
		}
		if (memcmp(&cmpRect, &wb.barRect, sizeof(RECT))) {
			updateBlocks(wb.wnd);
		}
	}
}

void createWindow()
{
	// Find bar
	const HWND tray = FindWindow("Shell_TrayWnd", NULL);
	if (!tray) {
		err("failed to find tray");
		return;
	}
	wb.bar = FindWindowEx(tray, NULL, "ReBarWindow32", NULL);
	if (!wb.bar) {
		err("failed to find taskbar");
		return;
	}

	// Create window
	assert(CreateWindowEx(
			WS_EX_LAYERED, WBLOCKS_BAR_CLASS, "wblocks2_bar",
			0, 0, 0, 0, 0, wb.bar, 0, 0, 0));
}

void CALLBACK retryCreateWindow(HWND _a, UINT _b, UINT _c, DWORD _d)
{
	createWindow();
	if (wb.wnd) {
		KillTimer(NULL, createWindowTimer);
	}
}

void initWnd(HWND wnd)
{
	wb.wnd = wnd;
	wb.screenHDC = GetDC(NULL);
	wb.hdc = CreateCompatibleDC(wb.screenHDC);
	SetParent(wnd, wb.bar);
	updateBlocks(wnd);

	// Show tray icon
	NOTIFYICONDATA notifData = {
		.cbSize = sizeof(notifData),
		.hWnd = wnd,
		.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP,
		.uCallbackMessage = WM_WBLOCKS_TRAY,
		.hIcon = LoadIcon(hInst, MAKEINTRESOURCE(100)),
	};
	memcpy(notifData.szTip, "wblocks\0", sizeof("wblocks") + 1);
	Shell_NotifyIcon(NIM_ADD, &notifData);
}

void cleanupWnd()
{
	if (wb.lastBitmap) {
		DeleteObject(wb.lastBitmap);
	}
	DeleteDC(wb.hdc);
	ReleaseDC(NULL, wb.screenHDC);
	NOTIFYICONDATA notifData = { .cbSize = sizeof(notifData), .hWnd = wb.wnd };
	Shell_NotifyIcon(NIM_DELETE, &notifData);
	wb = {};
	createWindowTimer = SetTimer(NULL, 0, 3000, (TIMERPROC)retryCreateWindow);
}

void restartProgram()
{
	STARTUPINFO si;
	GetStartupInfo(&si);
	TCHAR szPath[MAX_PATH + 1];
	GetModuleFileName(NULL, szPath, MAX_PATH);
	PROCESS_INFORMATION pi;
	assert(CreateProcess(szPath, GetCommandLine(), NULL, NULL, FALSE, DETACHED_PROCESS, NULL, NULL, &si, &pi));
	exit(0);
}

LRESULT CALLBACK wndProc(HWND wnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
#ifdef DEBUG
	printf("wmsg %d\n", msg);
#endif

	switch (msg) {
	case WM_CREATE:
		initWnd(wnd);
		break;
	case WM_NCDESTROY:
		cleanupWnd();
		err("wblocks window died, probably due to explorer.exe crashing");
		break;
	case WM_WBLOCKS_TRAY:
		if (LOWORD(lParam) == WM_LBUTTONUP || LOWORD(lParam) == WM_RBUTTONUP) {
			POINT pt;
			GetCursorPos(&pt);
			HMENU hmenu = CreatePopupMenu();
			InsertMenu(hmenu, 0, MF_BYPOSITION | MF_STRING, TRAY_MENU_SHOW_LOG, "Show Log");
			InsertMenu(hmenu, 1, MF_BYPOSITION | MF_STRING, TRAY_MENU_RESTART, "Restart");
			InsertMenu(hmenu, 2, MF_BYPOSITION | MF_STRING, TRAY_MENU_EXIT, "Exit");
			SetForegroundWindow(wnd);
			int cmd = TrackPopupMenu(hmenu,
					TPM_LEFTALIGN | TPM_LEFTBUTTON | TPM_BOTTOMALIGN | TPM_NONOTIFY | TPM_RETURNCMD,
					pt.x, pt.y, 0, wnd, NULL);
			PostMessage(wnd, WM_NULL, 0, 0);
			if (cmd == TRAY_MENU_SHOW_LOG) {
				ShellExecute(NULL, NULL, WBLOCKS_LOGFILE, NULL, NULL, SW_SHOWNORMAL);
			} else if (cmd == TRAY_MENU_RESTART) {
				cleanupWnd();
				restartProgram(); // TODO: opt for proper reload instead
			} else if (cmd == TRAY_MENU_EXIT) {
				cleanupWnd();
				exit(0);
			}
		}
	}

	return DefWindowProc(wnd, msg, wParam, lParam);
}

template<JSCFunction *fn>
JSValue jsWrapBlockFn(JSContext *ctx, JSValueConst thiz, int argc, JSValueConst *argv)
{
#ifdef DEBUG
	printf("FN %lld\n", (size_t)fn);
#endif
	barBlocks.mutex.lock();
	JSValue ret = fn(ctx, thiz, argc, argv);
	barBlocks.needsUpdate = true;
	barBlocks.mutex.unlock();
	return ret;
}

// Used to run events that need to be ran on the JS thread
JSValue jsYieldToC(JSContext *ctx, JSValueConst thiz, int argc, JSValueConst *argv)
{
	jsThreadQueueMutex.lock();
	for (auto& item : jsThreadQueue) {
		item.first(item.second);
	}
	jsThreadQueue.clear();
	jsThreadQueueMutex.unlock();
	return JS_UNDEFINED;
}

JSValue createJSBlockFromSrc(JSContext *ctx, Block *srcBlock)
{
	Block *block = new Block(*srcBlock);
	JSValue obj = JS_NewObjectClass(ctx, jsBlockClassId);
	JS_SetOpaque(obj, block);
	barBlocks.blocks.push_back(block);
	return obj;
}

JSValue jsCreateBlock(JSContext *ctx, JSValueConst thiz, int argc, JSValueConst *argv)
{
	return createJSBlockFromSrc(ctx, &barBlocks.defaultBlock);
}

static inline Block *getBlockThis(JSValueConst thiz)
{
	return (Block*)JS_GetOpaque(thiz, jsBlockClassId);
}

JSValue jsBlockSetFont(JSContext *ctx, JSValueConst thiz, int argc, JSValueConst *argv)
{
	// TODO: make size an optional parameter, retaining size if not given
	if (argc != 2 || !JS_IsString(argv[0]) || !JS_IsNumber(argv[1])) {
		return JS_ThrowTypeError(ctx, "Invalid argument");
	}
	const char *fontName = JS_ToCString(ctx, argv[0]);
	bool ok = getBlockThis(thiz)->setFont(fontName, JS_VALUE_GET_INT(argv[1]));
	JS_FreeCString(ctx, fontName);
	return ok ? JS_UNDEFINED : JS_ThrowInternalError(ctx, "Failed to load font");
}

JSValue jsBlockSetText(JSContext *ctx, JSValueConst thiz, int argc, JSValueConst *argv)
{
	if (argc != 1 || !JS_IsString(argv[0])) {
		return JS_ThrowTypeError(ctx, "Invalid argument");
	}
	size_t len;
	const char *str = JS_ToCStringLen(ctx, &len, argv[0]);
	getBlockThis(thiz)->setText(std::string(str, len));
	JS_FreeCString(ctx, str);
	return JS_UNDEFINED;
}

JSValue jsBlockSetColor(JSContext *ctx, JSValueConst thiz, int argc, JSValueConst *argv)
{
	if (argc != 3 || !JS_IsNumber(argv[0]) || !JS_IsNumber(argv[1]) || !JS_IsNumber(argv[2])) {
		return JS_ThrowTypeError(ctx, "Invalid argument");
	}
	getBlockThis(thiz)->color = JS_VALUE_GET_INT(argv[0])
		| (JS_VALUE_GET_INT(argv[1]) << 8)
		| (JS_VALUE_GET_INT(argv[2]) << 16);
	return JS_UNDEFINED;
}

JSValue jsBlockSetPadding(JSContext *ctx, JSValueConst thiz, int argc, JSValueConst *argv)
{
	if (argc != 2 || !JS_IsNumber(argv[0]) || !JS_IsNumber(argv[1])) {
		return JS_ThrowTypeError(ctx, "Invalid argument");
	}
	auto block = getBlockThis(thiz);
	block->padLeft = JS_VALUE_GET_INT(argv[0]);
	block->padRight = JS_VALUE_GET_INT(argv[1]);
	return JS_UNDEFINED;
}

JSValue jsBlockSetVisible(JSContext *ctx, JSValueConst thiz, int argc, JSValueConst *argv)
{
	if (argc != 1 || !JS_IsBool(argv[0])) {
		return JS_ThrowTypeError(ctx, "Invalid argument");
	}
	getBlockThis(thiz)->visible = JS_VALUE_GET_BOOL(argv[0]);
	return JS_UNDEFINED;
}

JSValue jsBlockClone(JSContext *ctx, JSValueConst thiz, int argc, JSValueConst *argv)
{
	bool keepVisibility = false;
	if (argc >= 1) {
		if (!JS_IsBool(argv[0])) {
			return JS_ThrowTypeError(ctx, "Invalid argument");
		}
		keepVisibility = JS_VALUE_GET_BOOL(argv[0]);
	}
	JSValue jsBlock = createJSBlockFromSrc(ctx, getBlockThis(thiz));
	if (!keepVisibility) {
		getBlockThis(jsBlock)->visible = true;
	}
	return jsBlock;
}

JSValue jsBlockRemove(JSContext *ctx, JSValueConst thiz, int argc, JSValueConst *argv)
{
	auto block = getBlockThis(thiz);
	if (!std::count(barBlocks.blocks.begin(), barBlocks.blocks.end(), block)) {
		return JS_ThrowReferenceError(ctx, "Non-existent block");
	}
	barBlocks.blocks.erase(std::remove(barBlocks.blocks.begin(), barBlocks.blocks.end(), block), barBlocks.blocks.end());
	return JS_UNDEFINED;
}

// The resolver for `jsShell` which resolves the Promise, ran on the JS thread
void jsShellResolve(std::vector<void*>& args)
{
#ifdef DEBUG
	printf("jsShellResolve\n");
#endif
	assert(args.size() == 1);
	auto *td = (js_shell_thread_data*)args[0];
	JSValue str = JS_NewString(td->ctx, td->result.c_str());
	JSValue resp = JS_Call(td->ctx, td->success ? td->resolveFn : td->rejectFn, JS_UNDEFINED, 1, &str);
	JS_FreeValue(td->ctx, resp);
	JS_FreeValue(td->ctx, str);
	JS_FreeValue(td->ctx, td->resolveFn);
	JS_FreeValue(td->ctx, td->rejectFn);
	td->thread.detach();
	delete td;
}

std::optional<std::string> runProcess(std::string& cmd)
{
	// Create pipes for menu
	SECURITY_ATTRIBUTES sa = {
		.nLength = sizeof(SECURITY_ATTRIBUTES),
		.bInheritHandle = TRUE,
	};
	HANDLE stdoutR, stdoutW;
	CreatePipe(&stdoutR, &stdoutW, &sa, 0);
	assert(SetHandleInformation(stdoutR, HANDLE_FLAG_INHERIT, 0));

	// Open menu
	PROCESS_INFORMATION pi;
	STARTUPINFO si = {
		.cb = sizeof(STARTUPINFO),
		.dwFlags = STARTF_USESTDHANDLES,
		.hStdOutput = stdoutW,
		.hStdError = stdoutW,
	};
	if (!CreateProcessA(NULL, (LPSTR)cmd.c_str(), NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
		CloseHandle(stdoutR);
		CloseHandle(stdoutW);
		return {};
	}
	CloseHandle(stdoutW);

	// Read output
	std::string output;
	char buf[4096];
	DWORD bread;
	while (ReadFile(stdoutR, buf, 4096, &bread, NULL)) {
		output.append(buf, buf + bread);
	}

	// Clean up
	CloseHandle(stdoutR);
	CloseHandle(pi.hProcess);
	CloseHandle(pi.hThread);

	return std::make_optional<std::string>(output);
}

// The command runner for `jsShell`, ran on a different thread
void jsShellThread(js_shell_thread_data *td)
{
#ifdef DEBUG
	printf("jsShellThread\n");
#endif
	auto res = runProcess(td->cmd);
	if (res.has_value()) {
		td->success = true;
		td->result = res.value();
	} else {
		td->success = false;
		td->result = "failed to run command";
	}
	jsThreadQueueMutex.lock();
	jsThreadQueue.push_back(std::make_pair(jsShellResolve, std::vector({(void*)td})));
	jsThreadQueueMutex.unlock();
}

// The "lambda" put into the Promise constructor returned from `jsShell`, ran on the JS thread
JSValue jsShellPromiseCb(JSContext *ctx, JSValueConst thiz, int argc, JSValueConst *argv)
{
	if (argc != 2 || !JS_IsFunction(ctx, argv[0]) || !JS_IsFunction(ctx, argv[1]) || !jsShellTempCmd) {
		return JS_ThrowTypeError(ctx, "Invalid argument");
	}
	auto td = new js_shell_thread_data();
	td->resolveFn = JS_DupValue(ctx, argv[0]);
	td->rejectFn = JS_DupValue(ctx, argv[1]);
	td->ctx = ctx;
	td->cmd = std::string(jsShellTempCmd);
	JS_FreeCString(ctx, jsShellTempCmd);
	jsShellTempCmd = NULL;
	td->thread = std::thread(jsShellThread, td);
	return JS_UNDEFINED;
}

// Function the user calls from `$`
JSValue jsShell(JSContext *ctx, JSValueConst thiz, int argc, JSValueConst *argv)
{
	// TODO: make this a tag template function instead...?
	if (argc != 1 || !JS_IsString(argv[0])) {
		return JS_ThrowTypeError(ctx, "Invalid argument");
	}
	JSValue global = JS_GetGlobalObject(ctx);
	JSValue promiseClass = JS_GetPropertyStr(ctx, global, "Promise");
	JSValue fn = JS_NewCFunction(ctx, jsShellPromiseCb, "$__callback", 2);
	jsShellTempCmd = JS_ToCString(ctx, argv[0]);
	JSValue promise = JS_CallConstructor(ctx, promiseClass, 1, &fn);
	JS_FreeValue(ctx, fn);
	assert(!jsShellTempCmd);
	JS_FreeValue(ctx, promiseClass);
	JS_FreeValue(ctx, global);
	return promise;
}

void jsThreadFn()
{
	// Init runtime
	JSRuntime *rt = JS_NewRuntime();
	assert(rt);
	js_std_set_worker_new_context_func(JS_NewContext);
	js_std_init_handlers(rt);
	JS_SetModuleLoaderFunc(rt, NULL, js_module_loader, NULL);

	// Init context
	JSContext *ctx = JS_NewContext(rt);
	assert(ctx);
	js_init_module_std(ctx, "std");
	js_init_module_os(ctx, "os");
	js_std_add_helpers(ctx, 0, NULL);

	// Reg block class
	{
		JS_NewClassID(&jsBlockClassId);
		static const JSClassDef jsBlockClass = { "Block" };
		JS_NewClass(rt, jsBlockClassId, &jsBlockClass);

		JSValue proto = JS_NewObject(ctx);
		QJS_SET_PROP_FN(ctx, proto, "setFont", jsWrapBlockFn<jsBlockSetFont>, 2);
		QJS_SET_PROP_FN(ctx, proto, "setText", jsWrapBlockFn<jsBlockSetText>, 1);
		QJS_SET_PROP_FN(ctx, proto, "setColor", jsWrapBlockFn<jsBlockSetColor>, 3);
		QJS_SET_PROP_FN(ctx, proto, "setPadding", jsWrapBlockFn<jsBlockSetPadding>, 2);
		QJS_SET_PROP_FN(ctx, proto, "setVisible", jsWrapBlockFn<jsBlockSetVisible>, 1);
		QJS_SET_PROP_FN(ctx, proto, "clone", jsWrapBlockFn<jsBlockClone>, 1);
		QJS_SET_PROP_FN(ctx, proto, "remove", jsWrapBlockFn<jsBlockRemove>, 0);
		JS_SetClassProto(ctx, jsBlockClassId, proto);
	}

	// Create default block
	JSValue jsDefaultBlock = JS_NewObjectClass(ctx, jsBlockClassId);
	JS_SetOpaque(jsDefaultBlock, &barBlocks.defaultBlock);

	// Add C API
	{
		JSValue global = JS_GetGlobalObject(ctx);
		QJS_SET_PROP_FN(ctx, global, "createBlock", jsWrapBlockFn<jsCreateBlock>, 0);
		QJS_SET_PROP_FN(ctx, global, "$", jsShell, 1);
		JS_SetPropertyStr(ctx, global, "defaultBlock", jsDefaultBlock);

		JSValue wbc = JS_NewObject(ctx);
		JS_SetPropertyStr(ctx, global, "__wbc", wbc);
		QJS_SET_PROP_FN(ctx, wbc, "yieldToC", jsYieldToC, 0);
		JS_FreeValue(ctx, global);
	}

	// Run lib (loads file)
	JSValue val = JS_Eval(ctx, wblocksLibMJS_data, wblocksLibMJS_size - 1, "<eval>", JS_EVAL_TYPE_MODULE);
	if (JS_IsException(val)) {
		fprintf(stderr, "JS Error: ");
		js_std_dump_error(ctx);
	}

	// Main loop
	js_std_loop(ctx);
}

int CALLBACK WinMain(HINSTANCE inst, HINSTANCE prevInst, LPSTR cmdLine, int cmdShow)
{
	hInst = inst;

	// Create console and redirect output
	assert(AllocConsole());
#ifdef DEBUG
	assert(freopen("CONOUT$", "w", stdout));
	assert(freopen("CONOUT$", "w", stderr));
#else
	ShowWindow(GetConsoleWindow(), 0);
	assert(freopen(WBLOCKS_LOGFILE, "w", stdout));
	assert(freopen("NUL", "w", stderr));
	assert(!_dup2(_fileno(stdout), _fileno(stderr)));
#endif
	setvbuf(stdout, NULL, _IONBF, 0);
	setvbuf(stderr, NULL, _IONBF, 0);

	// Reg class
	WNDCLASSEX wc = {0};
	wc.cbSize = sizeof(WNDCLASSEX);
	wc.lpfnWndProc = wndProc;
	wc.lpszClassName = WBLOCKS_BAR_CLASS;
	wc.hCursor = LoadCursor(NULL, IDC_ARROW);
	assert(RegisterClassEx(&wc));

	// Create bar
	createWindow();

	// Create JS state
	auto jsThread = std::thread(jsThreadFn);

	// Main loop
	while (true) {
		checkBarSize(); // TODO: timer instead

		barBlocks.mutex.lock();
		if (wb.wnd && barBlocks.needsUpdate) {
			updateBlocks(wb.wnd);
			barBlocks.needsUpdate = false; // TODO: window message instead
		}
		barBlocks.mutex.unlock();

		MSG msg;
		while (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
			TranslateMessage(&msg);
			DispatchMessage(&msg);
		}

		Sleep(10);
	}

	jsThread.join();

	return 0;
}
