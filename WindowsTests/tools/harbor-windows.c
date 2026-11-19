/* harbor-windows: lists top-level windows in a Wine prefix and (with "fix") moves visible windows that lie on
 * no monitor to the centre of the primary monitor. Some programs (Steam's sign-in window) end up at
 * placeholder coordinates such as 0x2FFF0000 under Wine on macOS, which leaves them invisible.
 *   harbor-windows.exe list | fix [seconds]   ("fix 20" keeps fixing new windows for 20 s) */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static int fixing;

static BOOL CALLBACK visit(HWND hwnd, LPARAM unused)
{
    if (!IsWindowVisible(hwnd) || GetWindow(hwnd, GW_OWNER)) return TRUE;
    RECT r;
    GetWindowRect(hwnd, &r);
    WCHAR title[128] = L"";
    GetWindowTextW(hwnd, title, 128);
    BOOL offscreen = MonitorFromRect(&r, MONITOR_DEFAULTTONULL) == NULL;
    if (!fixing) {
        printf("%p %s pos=%ld,%ld size=%ldx%ld \"%ls\"\n", (void *)hwnd, offscreen ? "OFFSCREEN" : "onscreen",
               r.left, r.top, r.right - r.left, r.bottom - r.top, title);
    } else if (offscreen) {
        MONITORINFO mi = {sizeof(mi)};
        GetMonitorInfoW(MonitorFromPoint((POINT){0, 0}, MONITOR_DEFAULTTOPRIMARY), &mi);
        int w = r.right - r.left, h = r.bottom - r.top;
        int x = mi.rcWork.left + ((mi.rcWork.right - mi.rcWork.left) - w) / 2;
        int y = mi.rcWork.top + ((mi.rcWork.bottom - mi.rcWork.top) - h) / 2;
        SetWindowPos(hwnd, NULL, x, y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
        printf("moved \"%ls\" from %ld,%ld to %d,%d\n", title, r.left, r.top, x, y);

    }
    return TRUE;
}

int main(int argc, char **argv)
{
    fixing = argc > 1 && !strcmp(argv[1], "fix");
    int seconds = argc > 2 ? atoi(argv[2]) : 0;
    DWORD end = GetTickCount() + seconds * 1000;
    do {
        EnumWindows(visit, 0);
        if (GetTickCount() < end) Sleep(500);
    } while (GetTickCount() < end);
    fflush(stdout);
    return 0;
}
