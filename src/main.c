// Require Windows 10
#define WINVER 0x0A00
#define _WIN32_WINNT 0x0A00

#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdbool.h>
#include <assert.h>

#include <quickjs/quickjs.h>
#include <quickjs/quickjs-libc.h>

#define INCBIN_PREFIX
#define INCBIN_STYLE INCBIN_STYLE_SNAKE
#include "incbin.h"
INCTXT(wblocksLibMJS, "src/lib.mjs");

#define WBLOCKS_BAR_CLASS "wblocks2_bar"

JSClassID jsBlockClassId;
UINT_PTR createWindowTimer;
HINSTANCE hInst;

#define WBLOCKS_MAX_LEN 1024

typedef struct {
	HFONT handle;
	size_t refCount;
} fontref_t;

typedef struct _wblock {
	struct _wblock *tail, *head;
	bool visible;
	wchar_t text[WBLOCKS_MAX_LEN];
	uint16_t textLen;
	fontref_t *font;
	COLORREF color;
	size_t padLeft, padRight;
} wblock_t;

struct {
	bool needsUpdate;
	HWND bar, wnd;
	HDC screenHDC, hdc;
	HBITMAP lastBitmap;
	SIZE lastSize;
	RECT barRect;
} wb;

wblock_t *headBlock = NULL;
wblock_t defaultBlock = {
	.visible = true,
	.text = L"",
	.textLen = 0,
	.color = RGB(255, 255, 255),
	.padLeft = 5,
	.padRight = 5,
};

typedef struct _main_queue_item {
	struct _main_queue_item *next;
	void (*fn)(void*);
	void *data;
} main_queue_item_t;
main_queue_item_t *mainQueueHead = NULL;
HANDLE mainQueueMutex;

typedef struct {
	HANDLE thread;
	JSValue resolve, reject;
	JSContext *ctx;
	char *cmd;

	bool success;
	char *result;
} js_shell_thread_data_t;
const char *jsShellTempCmd;

void err(const char *err)
{
	fprintf(stderr, "wblocks error: %s\n", err);
}

void *xmalloc(size_t sz)
{
	void *ptr = malloc(sz);
	assert(ptr);
	return ptr;
}

void xrealloc(void **ptr, size_t sz)
{
	*ptr = realloc(*ptr, sz);
	assert(*ptr);
}

void mainQueueAppend(void (*fn)(void*), void *data)
{
	main_queue_item_t *new = xmalloc(sizeof(main_queue_item_t));
	new->fn = fn;
	new->data = data;
	WaitForSingleObject(mainQueueMutex, INFINITE);
	new->next = mainQueueHead;
	mainQueueHead = new;
	ReleaseMutex(mainQueueMutex);
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
	wblock_t *block = headBlock;
	while (block) {
		if (block->visible) {
			// Draw text
			SetTextColor(wb.hdc, block->color),
			SelectObject(wb.hdc, block->font->handle);
			rect.right -= block->padRight;
			DrawTextW(wb.hdc, block->text, block->textLen, &rect,
					DT_NOCLIP | DT_NOPREFIX | DT_SINGLELINE | DT_RIGHT | DT_VCENTER);
			RECT rectCalc = { .right = sz.cx, .bottom = sz.cy };
			DrawTextW(wb.hdc, block->text, block->textLen, &rectCalc,
					DT_NOCLIP | DT_NOPREFIX | DT_SINGLELINE | DT_RIGHT | DT_VCENTER | DT_CALCRECT);
			rect.right -= rectCalc.right + block->padLeft;
		}

		block = block->tail; // Next
	}

	// Update
	POINT ptSrc = {0, 0};
	BLENDFUNCTION blendfn = {
		.BlendOp = AC_SRC_OVER,
		.SourceConstantAlpha = 255,
		.AlphaFormat = AC_SRC_ALPHA,
	};
	UpdateLayeredWindow(wnd, wb.screenHDC, &pt, &sz, wb.hdc, &ptSrc, 0, &blendfn, ULW_ALPHA);
}

JSValue jsCheckBarSize(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
	if (wb.wnd) {
		RECT cmpRect;
		if (!GetWindowRect(wb.bar, &cmpRect)) {
			err("failed to get tray size");
			DestroyWindow(wb.wnd);
			return JS_UNDEFINED;
		}
		if (memcmp(&cmpRect, &wb.barRect, sizeof(RECT))) {
			updateBlocks(wb.wnd);
		}
	}
	return JS_UNDEFINED;
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
		.hIcon = LoadIcon(hInst, MAKEINTRESOURCE(100)),
		.uFlags = NIF_ICON | NIF_TIP,
		.szTip = "wblocks",
	};
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
	memset(&wb, 0, sizeof(wb));
	createWindowTimer = SetTimer(NULL, 0, 3000, (TIMERPROC)retryCreateWindow);
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
	}

	return DefWindowProc(wnd, msg, wParam, lParam);
}

JSValue jsYieldToC(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
	if (wb.wnd && wb.needsUpdate) {
		updateBlocks(wb.wnd);
		wb.needsUpdate = false;
	}

	WaitForSingleObject(mainQueueMutex, INFINITE);
	while (mainQueueHead) {
		mainQueueHead->fn(mainQueueHead->data);
		main_queue_item_t *next = mainQueueHead->next;
		free(mainQueueHead);
		mainQueueHead = next;
	}
	ReleaseMutex(mainQueueMutex);

	MSG msg;
	while (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE)) {
		TranslateMessage(&msg);
		DispatchMessage(&msg);
	}
	return JS_UNDEFINED;
}

JSValue jsCreateBlock(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
	wblock_t *block = xmalloc(sizeof(wblock_t));
	memcpy(block, &defaultBlock, sizeof(wblock_t));
	block->font->refCount++;
	block->head = NULL;
	block->tail = headBlock;
	if (headBlock) {
		headBlock->head = block;
	}
	headBlock = block;
	wb.needsUpdate = true;

	JSValue obj = JS_NewObjectClass(ctx, jsBlockClassId);
	JS_SetOpaque(obj, block);
	return obj;
}

static inline wblock_t *getBlockThis(JSValueConst this)
{
	return JS_GetOpaque(this, jsBlockClassId);
}

JSValue jsBlockSetFont(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
	// TODO: allow name only, using default size
	if (argc != 2 || !JS_IsString(argv[0]) || !JS_IsNumber(argv[1])) {
		return JS_ThrowTypeError(ctx, "Invalid argument");
	}
	const char *str = JS_ToCString(ctx, argv[0]);
	fontref_t *fr = xmalloc(sizeof(fontref_t));
	fr->handle = CreateFont(JS_VALUE_GET_INT(argv[1]), 0, 0, 0, FW_NORMAL, 0, 0, 0, 0, 0, 0, 0, 0, str);
	fr->refCount++;
	JS_FreeCString(ctx, str);
	if (!fr->handle) {
		return JS_ThrowInternalError(ctx, "Failed to load font");
	}
	wblock_t *block = getBlockThis(this);
	if (--block->font->refCount == 0) {
		DeleteObject(block->font->handle);
		free(block->font);
	}
	block->font = fr;
	wb.needsUpdate = true;
	return JS_UNDEFINED;
}

JSValue jsBlockSetText(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
	if (argc != 1 || !JS_IsString(argv[0])) {
		return JS_ThrowTypeError(ctx, "Invalid argument");
	}
	size_t len;
	const char *str = JS_ToCStringLen(ctx, &len, argv[0]);
	wblock_t *block = getBlockThis(this);
	block->textLen = MultiByteToWideChar(CP_UTF8, MB_PRECOMPOSED, str, len, block->text, WBLOCKS_MAX_LEN);
	JS_FreeCString(ctx, str);
	wb.needsUpdate = true;
	return JS_UNDEFINED;
}

JSValue jsBlockSetColor(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
	if (argc != 3 || !JS_IsNumber(argv[0]) || !JS_IsNumber(argv[1]) || !JS_IsNumber(argv[2])) {
		return JS_ThrowTypeError(ctx, "Invalid argument");
	}
	getBlockThis(this)->color = JS_VALUE_GET_INT(argv[0])
		| (JS_VALUE_GET_INT(argv[1]) << 8)
		| (JS_VALUE_GET_INT(argv[2]) << 16);
	wb.needsUpdate = true;
	return JS_UNDEFINED;
}

JSValue jsBlockSetPadding(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
	if (argc != 2 || !JS_IsNumber(argv[0]) || !JS_IsNumber(argv[1])) {
		return JS_ThrowTypeError(ctx, "Invalid argument");
	}
	wblock_t *block = getBlockThis(this);
	block->padLeft = JS_VALUE_GET_INT(argv[0]);
	block->padRight = JS_VALUE_GET_INT(argv[1]);
	wb.needsUpdate = true;
	return JS_UNDEFINED;
}

JSValue jsBlockSetVisible(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
	if (argc != 1 || !JS_IsBool(argv[0])) {
		return JS_ThrowTypeError(ctx, "Invalid argument");
	}
	getBlockThis(this)->visible = JS_VALUE_GET_BOOL(argv[0]);
	wb.needsUpdate = true;
	return JS_UNDEFINED;
}

JSValue jsBlockRemove(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
	wblock_t *block = getBlockThis(this);
	if (block == &defaultBlock) {
		return JS_ThrowInternalError(ctx, "Cannot remove default block");
	} else if (!block->head && headBlock != block) {
		return JS_ThrowReferenceError(ctx, "Non-existent block");
	}
	if (--block->font->refCount == 0) {
		DeleteObject(block->font->handle);
		free(block->font);
	}
	if (block->head) {
		block->head->tail = block->tail;
	} else {
		headBlock = block->tail;
	}
	if (block->tail) {
		block->tail->head = block->head;
	}
	block->head = block->tail = NULL;
	wb.needsUpdate = true;
	return JS_UNDEFINED;
}

// The resolver for `jsShell` which resolves the Promise, ran on the main thread
void jsShellResolve(void *data)
{
	js_shell_thread_data_t *td = data;
	JSValue str = JS_NewString(td->ctx, td->result);
	JS_FreeValue(td->ctx, JS_Call(td->ctx, td->success ? td->resolve : td->reject, JS_UNDEFINED, 1, &str));
	JS_FreeValue(td->ctx, str);
	JS_FreeValue(td->ctx, td->resolve);
	JS_FreeValue(td->ctx, td->reject);
	CloseHandle(td->thread);
	free(td->cmd);
	free(td->result);
	free(td);
}

char *runProcess(char *cmd)
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
		.hStdOutput = stdoutW,
		.hStdError = stdoutW,
		.dwFlags = STARTF_USESTDHANDLES,
	};
	if (!CreateProcessA(NULL, cmd, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
		CloseHandle(stdoutR);
		CloseHandle(stdoutW);
		return NULL;
	}
	CloseHandle(stdoutW);

	// Read output
	char *buf = xmalloc(4096);
	size_t len = 0;
	DWORD bread;
	while (ReadFile(stdoutR, buf + len, 4096, &bread, NULL)) {
		len += bread;
		xrealloc((void**)&buf, len + 4096);
	}
	buf[len] = 0;

	// Clean up
	CloseHandle(stdoutR);
	CloseHandle(pi.hProcess);
	CloseHandle(pi.hThread);

	return buf;
}

// The command runner for `jsShell`, ran on a different thread
DWORD CALLBACK jsShellThread(LPVOID param)
{
	js_shell_thread_data_t *td = param;
	char *res = runProcess(td->cmd);
	if (res) {
		td->success = true;
		td->result = res;
	} else {
		td->success = false;
		td->result = strdup("failed to run command");
	}
	mainQueueAppend(jsShellResolve, td);
	return 0;
}

// The "lambda" put into the Promise constructor returned from `jsShell`, ran on the main thread
JSValue jsShellPromiseCb(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
	if (argc != 2 || !JS_IsFunction(ctx, argv[0]) || !JS_IsFunction(ctx, argv[1]) || !jsShellTempCmd) {
		return JS_ThrowTypeError(ctx, "Invalid argument");
	}
	js_shell_thread_data_t *td = xmalloc(sizeof(js_shell_thread_data_t));
	td->resolve = JS_DupValue(ctx, argv[0]);
	td->reject = JS_DupValue(ctx, argv[1]);
	td->ctx = ctx;
	td->cmd = strdup(jsShellTempCmd);
	JS_FreeCString(ctx, jsShellTempCmd);
	jsShellTempCmd = NULL;
	td->thread = CreateThread(NULL, 0, jsShellThread, td, CREATE_SUSPENDED, 0);
	ResumeThread(td->thread);
	return JS_UNDEFINED;
}

// Function the user calls from `$`
JSValue jsShell(JSContext *ctx, JSValueConst this, int argc, JSValueConst *argv)
{
	// TODO: make this a tag template function instead
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

int CALLBACK WinMain(HINSTANCE inst, HINSTANCE prevInst, LPSTR cmdLine, int cmdShow)
{
	hInst = inst;

	// Load default font
	defaultBlock.font = xmalloc(sizeof(fontref_t));
	defaultBlock.font->handle = CreateFont(22, 0, 0, 0, FW_NORMAL, 0, 0, 0, 0, 0, 0, 0, 0, "Courier New");
	defaultBlock.font->refCount = 1;
	assert(defaultBlock.font->handle);

	// Create mutex
	mainQueueMutex = CreateMutex(NULL, false, NULL);

	// Reg class
	WNDCLASSEX wc = {0};
	wc.cbSize = sizeof(WNDCLASSEX);
	wc.lpfnWndProc = wndProc;
	wc.lpszClassName = WBLOCKS_BAR_CLASS;
	wc.hCursor = LoadCursor(NULL, IDC_ARROW);
	assert(RegisterClassEx(&wc));

	// Create bar
	createWindow();

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
		static const JSCFunctionListEntry protoFuncs[] = {
			JS_CFUNC_DEF("setFont", 2, jsBlockSetFont ),
			JS_CFUNC_DEF("setText", 1, jsBlockSetText ),
			JS_CFUNC_DEF("setColor", 3, jsBlockSetColor ),
			JS_CFUNC_DEF("setPadding", 2, jsBlockSetPadding ),
			JS_CFUNC_DEF("setVisible", 1, jsBlockSetVisible ),
			JS_CFUNC_DEF("remove", 0, jsBlockRemove ),
		};
		JS_SetPropertyFunctionList(ctx, proto, protoFuncs, 6);
		JS_SetClassProto(ctx, jsBlockClassId, proto);
	}

	// Create default block
	JSValue jsDefaultBlock = JS_NewObjectClass(ctx, jsBlockClassId);
	JS_SetOpaque(jsDefaultBlock, &defaultBlock);

	// Add C API
	{
		JSValue global = JS_GetGlobalObject(ctx);
		JS_SetPropertyStr(ctx, global, "createBlock", JS_NewCFunction(ctx, jsCreateBlock, "createBlock", 0));
		JS_SetPropertyStr(ctx, global, "defaultBlock", jsDefaultBlock);
		JS_SetPropertyStr(ctx, global, "$", JS_NewCFunction(ctx, jsShell, "$", 1));
		JSValue wbc = JS_NewObject(ctx);
		JS_SetPropertyStr(ctx, global, "__wbc", wbc);
		JS_FreeValue(ctx, global);

		JS_SetPropertyStr(ctx, wbc, "yieldToC", JS_NewCFunction(ctx, jsYieldToC, "yieldToC", 0));
		JS_SetPropertyStr(ctx, wbc, "checkBarSize", JS_NewCFunction(ctx, jsCheckBarSize, "checkBarSize", 0));
	}

	// Run lib (loads file)
	JSValue val = JS_Eval(ctx, wblocksLibMJS_data, wblocksLibMJS_size - 1, "<eval>", JS_EVAL_TYPE_MODULE);
	if (JS_IsException(val)) {
		fprintf(stderr, "JS Error: ");
		js_std_dump_error(ctx);
	}

	// Main loop
	js_std_loop(ctx);

	return 0;
}
