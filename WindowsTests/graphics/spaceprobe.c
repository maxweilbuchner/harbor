/* Which screen-sized windows get a macOS fullscreen Space of their own (scripts/patches/wine/0011 and 0017).
 * Shows one borderless window of the primary screen's size for a while; WindowsTests/graphics/spaces.sh looks at
 * the Mac's Spaces meanwhile. Usage: spaceprobe.exe <kind> [seconds, default 8] [early's delay in ms, default 300]
 *   plain         opaque: a fullscreen program (gets a Space)
 *   topmost       opaque and WS_EX_TOPMOST, as Direct3D's exclusive fullscreen makes its window (gets a Space)
 *   dimmer        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW, half transparent
 *   alpha         WS_EX_LAYERED, half transparent
 *   colorkey      WS_EX_LAYERED with a colour key that makes its middle a hole
 *   perpixel      WS_EX_LAYERED drawn with UpdateLayeredWindow (per-pixel alpha)
 *   shaped        a window region (an ellipse)
 *   clickthrough  WS_EX_LAYERED | WS_EX_TRANSPARENT but opaque
 *   tool          WS_EX_TOOLWINDOW, opaque
 *   noactivate    WS_EX_NOACTIVATE, opaque
 *   early         like plain, but back to a small window a moment later, while macOS still animates it into
 *                 its Space
 *   small         a small ordinary window (never fullscreen) */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static HBRUSH hole;

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_TIMER && wp == 1) { KillTimer(hwnd, 1); SetWindowPos(hwnd, NULL, 120, 120, 640, 480, SWP_NOZORDER); return 0; }
    if (msg == WM_TIMER && wp == 2) { DestroyWindow(hwnd); return 0; }
    if (msg == WM_DESTROY) { PostQuitMessage(0); return 0; }
    if (msg == WM_ERASEBKGND && hole) {
        RECT rc, mid;
        GetClientRect(hwnd, &rc);
        FillRect((HDC)wp, &rc, (HBRUSH)GetClassLongPtrA(hwnd, GCLP_HBRBACKGROUND));
        SetRect(&mid, rc.right / 4, rc.bottom / 4, rc.right * 3 / 4, rc.bottom * 3 / 4);
        FillRect((HDC)wp, &mid, hole);
        return 1;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

static void draw_per_pixel(HWND hwnd, int w, int h)
{
    BITMAPINFO bmi = {{sizeof(BITMAPINFOHEADER), w, -h, 1, 32, BI_RGB}};
    BLENDFUNCTION blend = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    POINT zero = {0, 0};
    SIZE size = {w, h};
    DWORD *bits;
    HDC screen = GetDC(NULL), dc = CreateCompatibleDC(screen);
    HBITMAP bitmap = CreateDIBSection(dc, &bmi, DIB_RGB_COLORS, (void **)&bits, NULL, 0);
    if (bitmap) {
        for (int i = 0; i < w * h; i++) bits[i] = 0x60000030; /* premultiplied: mostly transparent dark blue */
        SelectObject(dc, bitmap);
        UpdateLayeredWindow(hwnd, screen, &zero, &size, dc, &zero, 0, &blend, ULW_ALPHA);
    }
    DeleteDC(dc);
    ReleaseDC(NULL, screen);
    if (bitmap) DeleteObject(bitmap);
}

int main(int argc, char **argv)
{
    const char *kind = argc > 1 ? argv[1] : "plain";
    int seconds = argc > 2 ? atoi(argv[2]) : 8;
    int w = GetSystemMetrics(SM_CXSCREEN), h = GetSystemMetrics(SM_CYSCREEN);
    DWORD style = WS_POPUP, ex = 0;
    WNDCLASSA wc = {0};
    HWND hwnd;
    MSG msg;

    if (!strcmp(kind, "topmost")) ex = WS_EX_TOPMOST;
    else if (!strcmp(kind, "dimmer")) ex = WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOPMOST | WS_EX_TOOLWINDOW;
    else if (!strcmp(kind, "alpha") || !strcmp(kind, "colorkey") || !strcmp(kind, "perpixel")) ex = WS_EX_LAYERED;
    else if (!strcmp(kind, "clickthrough")) ex = WS_EX_LAYERED | WS_EX_TRANSPARENT;
    else if (!strcmp(kind, "tool")) ex = WS_EX_TOOLWINDOW;
    else if (!strcmp(kind, "noactivate")) ex = WS_EX_NOACTIVATE;
    else if (!strcmp(kind, "small")) style = WS_OVERLAPPEDWINDOW;
    else if (strcmp(kind, "plain") && strcmp(kind, "shaped") && strcmp(kind, "early")) { printf("FAIL unknown kind %s\n", kind); return 2; }

    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "HarborSpaceProbe";
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    wc.hbrBackground = CreateSolidBrush(RGB(0, 0, 96));
    RegisterClassA(&wc);
    if (!strcmp(kind, "colorkey")) hole = CreateSolidBrush(RGB(255, 0, 255));
    if (!strcmp(kind, "small")) hwnd = CreateWindowExA(ex, wc.lpszClassName, kind, style, 160, 160, 400, 300, NULL, NULL, wc.hInstance, NULL);
    else hwnd = CreateWindowExA(ex, wc.lpszClassName, kind, style, 0, 0, w, h, NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) { printf("FAIL CreateWindowEx: %lu\n", GetLastError()); return 2; }

    if (!strcmp(kind, "dimmer") || !strcmp(kind, "alpha")) SetLayeredWindowAttributes(hwnd, 0, 128, LWA_ALPHA);
    else if (!strcmp(kind, "clickthrough")) SetLayeredWindowAttributes(hwnd, 0, 255, LWA_ALPHA);
    else if (!strcmp(kind, "colorkey")) SetLayeredWindowAttributes(hwnd, RGB(255, 0, 255), 0, LWA_COLORKEY);
    else if (!strcmp(kind, "shaped")) SetWindowRgn(hwnd, CreateEllipticRgn(0, 0, w, h), FALSE);
    ShowWindow(hwnd, strcmp(kind, "noactivate") ? SW_SHOW : SW_SHOWNOACTIVATE);
    if (!strcmp(kind, "perpixel")) draw_per_pixel(hwnd, w, h);
    else UpdateWindow(hwnd);
    if (!strcmp(kind, "early")) SetTimer(hwnd, 1, argc > 3 ? atoi(argv[3]) : 300, NULL);
    SetTimer(hwnd, 2, seconds * 1000, NULL);
    printf("READY %s %dx%d\n", kind, w, h);
    fflush(stdout);
    while (GetMessageA(&msg, NULL, 0, 0) > 0) DispatchMessageA(&msg);
    printf("EXIT\n");
    fflush(stdout);
    return 0;
}
