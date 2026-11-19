/* xprocdraw: checks drawing into another process's window (what Chromium's GPU process does to
 * present software frames). The parent shows a black window and starts a child, which fills a blue
 * rectangle at x=13..150 through GetDC( parent's window ). The parent then reads its own pixels: inside
 * the rectangle must be blue, the columns just outside it must still be black (not white).
 *   xprocdraw.exe      prints PASS/FAIL, exit code 0/1 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

static void pump(DWORD ms)
{
    DWORD end = GetTickCount() + ms; MSG m;
    while (GetTickCount() < end) { while (PeekMessageW(&m, 0, 0, 0, PM_REMOVE)) DispatchMessageW(&m); Sleep(10); }
}

int main(int argc, char **argv)
{
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
    char cmd[MAX_PATH + 64], self[MAX_PATH];
    GetModuleFileNameA(NULL, self, MAX_PATH);
    sprintf(cmd, "\"%s\" child %llx", self, (unsigned long long)(ULONG_PTR)hwnd);
    STARTUPINFOA si = {sizeof(si)}; PROCESS_INFORMATION pi;
    if (!CreateProcessA(NULL, cmd, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi)) { printf("FAIL: no child\n"); return 1; }
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
    printf(bad ? "FAIL: %d wrong pixels\n" : "PASS\n", bad);
    fflush(stdout);
    return bad != 0;
}
