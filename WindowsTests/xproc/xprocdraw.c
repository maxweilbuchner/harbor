/* xprocdraw: checks drawing into another process's window (what Chromium's GPU process does to
 * present software frames). The parent shows a black window and starts a child, which fills a blue
 * rectangle at x=13..150 through GetDC( parent's window ). The parent then reads its own pixels: inside
 * the rectangle must be blue, the columns just outside it must still be black (not white).
 * Then a window shown late (#95): the parent has a hidden child window, a second process puts its own window
 * into that and draws once while nothing can be seen, the parent shows the hidden window, and the second
 * process draws again without having dispatched a message in between. That must show: nothing tells the
 * second process that the first one showed the window.
 * An Office add-in's dialog comes up like this, with a browser's window inside it.
 *   xprocdraw.exe      prints a PASS/FAIL line per check, exit code 0/1 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static void pump(DWORD ms)
{
    DWORD end = GetTickCount() + ms; MSG m;
    while (GetTickCount() < end) { while (PeekMessageW(&m, 0, 0, 0, PM_REMOVE)) DispatchMessageW(&m); Sleep(10); }
}

static int spawn(const char *role, HWND hwnd, PROCESS_INFORMATION *pi)
{
    char cmd[MAX_PATH + 64], self[MAX_PATH];
    STARTUPINFOA si = {sizeof(si)};
    GetModuleFileNameA(NULL, self, MAX_PATH);
    sprintf(cmd, "\"%s\" %s %llx", self, role, (unsigned long long)(ULONG_PTR)hwnd);
    return CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, pi);
}

/* Dispatches messages until the event is set; the two processes take turns through named events. */
static int pump_until(HANDLE event, DWORD ms)
{
    DWORD end = GetTickCount() + ms; MSG m;
    while (WaitForSingleObject(event, 10) != WAIT_OBJECT_0) {
        if (GetTickCount() > end) return 0;
        while (PeekMessageW(&m, 0, 0, 0, PM_REMOVE)) DispatchMessageW(&m);
    }
    return 1;
}

static void fill_red(HWND hwnd)
{
    RECT r = {0, 0, 100, 40};
    HBRUSH red = CreateSolidBrush(RGB(200, 0, 0));
    HDC dc = GetDC(hwnd);
    FillRect(dc, &r, red);
    ReleaseDC(hwnd, dc);
    DeleteObject(red);
}

int main(int argc, char **argv)
{
    if (argc > 2 && !strcmp(argv[1], "late")) {
        WNDCLASSW wc = {0};
        wc.lpfnWndProc = DefWindowProcW; wc.lpszClassName = L"HarborXProcLate";
        RegisterClassW(&wc);
        HWND hwnd = CreateWindowExW(0, L"HarborXProcLate", L"", WS_CHILD | WS_VISIBLE, 10, 10, 100, 40,
                                    (HWND)(ULONG_PTR)strtoull(argv[2], NULL, 16), 0, 0, 0);
        HANDLE first = OpenEventA(EVENT_ALL_ACCESS, FALSE, "HarborXProcFirst"), shown = OpenEventA(EVENT_ALL_ACCESS, FALSE, "HarborXProcShown"),
               drawn = OpenEventA(EVENT_ALL_ACCESS, FALSE, "HarborXProcDrawn");
        if (!hwnd || !first || !shown || !drawn) return 1;
        fill_red(hwnd);   /* into a window inside a hidden one: nothing to see, but the DC is kept for reuse */
        pump(300);
        SetEvent(first);
        /* No message is dispatched from here on, as in a browser's GPU process: handling the repaint that
         * showing the window asks for would refresh the DC, and a message loop would flush what is drawn. */
        if (WaitForSingleObject(shown, 20000) != WAIT_OBJECT_0) return 1;
        fill_red(hwnd);
        GdiFlush();
        SetEvent(drawn);
        Sleep(3000);
        return 0;
    }
    if (argc > 2 && !strcmp(argv[1], "child")) {
        HWND hwnd = (HWND)(ULONG_PTR)strtoull(argv[2], NULL, 16);
        RECT r = {13, 20, 150, 60};
        HBRUSH blue = CreateSolidBrush(RGB(0, 0, 200));
        HDC dc = GetDC(hwnd);
        FillRect(dc, &r, blue);
        ReleaseDC(hwnd, dc);
        return 0;
    }
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = DefWindowProcW; wc.lpszClassName = L"HarborXProc"; wc.hbrBackground = GetStockObject(BLACK_BRUSH);
    RegisterClassW(&wc);
    HWND hwnd = CreateWindowExW(0, L"HarborXProc", L"Harbor cross-process draw", WS_POPUP | WS_VISIBLE, 120, 120, 320, 120, 0, 0, 0, 0);
    pump(1500);
    PROCESS_INFORMATION pi;
    if (!spawn("child", hwnd, &pi)) { printf("FAIL: no child\n"); return 1; }
    pump(3000);   /* keep dispatching: the child's drawing arrives as a message to this thread */
    WaitForSingleObject(pi.hProcess, 10000);
    HDC dc = GetDC(hwnd);
    const int xs[] = {4, 9, 12, 13, 80, 149, 150, 153, 158}; int bad = 0;
    for (int i = 0; i < 9; i++) {
        COLORREF c = GetPixel(dc, xs[i], 40), want = (xs[i] >= 13 && xs[i] < 150) ? RGB(0, 0, 200) : RGB(0, 0, 0);
        printf("x=%3d: %06lx %s\n", xs[i], (unsigned long)c, c == want ? "ok" : "WRONG");
        bad += c != want;
    }
    ReleaseDC(hwnd, dc);
    printf(bad ? "FAIL: %d wrong pixels\n" : "PASS: another process draws into the window\n", bad);
    fflush(stdout);

    /* A window shown late. The red window ends up at (30,30)-(130,70) in this one. */
    HWND top = CreateWindowExW(0, L"HarborXProc", L"Harbor cross-process draw, late", WS_POPUP | WS_VISIBLE, 120, 280, 320, 120, 0, 0, 0, 0);
    HWND hidden = CreateWindowExW(0, L"HarborXProc", L"", WS_CHILD, 20, 20, 200, 80, top, 0, 0, 0);
    pump(1000);
    HANDLE first = CreateEventA(NULL, TRUE, FALSE, "HarborXProcFirst"), shown = CreateEventA(NULL, TRUE, FALSE, "HarborXProcShown"),
           drawn = CreateEventA(NULL, TRUE, FALSE, "HarborXProcDrawn");
    if (!spawn("late", hidden, &pi)) { printf("FAIL: no second process\n"); return 1; }
    if (!pump_until(first, 30000)) { printf("FAIL: the second process never drew\n"); return 1; }
    ShowWindow(hidden, SW_SHOW);
    pump(500);
    SetEvent(shown);
    if (!pump_until(drawn, 30000)) { printf("FAIL: the second process never drew again\n"); return 1; }
    pump(1000);
    dc = GetDC(top);
    COLORREF inside = GetPixel(dc, 80, 50), outside = GetPixel(dc, 280, 100);
    ReleaseDC(top, dc);
    int late = inside == RGB(200, 0, 0) && outside == RGB(0, 0, 0);
    printf("late: inside %06lx, outside %06lx\n", (unsigned long)inside, (unsigned long)outside);
    printf("%s: another process draws into a window that was shown after it first drew\n", late ? "PASS" : "FAIL");
    fflush(stdout);
    WaitForSingleObject(pi.hProcess, 10000);
    return bad != 0 || !late;
}
