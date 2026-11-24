/* Regression test for the Mac's Quit (scripts/patches/wine/0015): a window that reports what it is asked.
 * Prints READY once its window is up, then one line per WM_CLOSE, WM_QUERYENDSESSION and WM_ENDSESSION, and
 * "EXIT clean" when its message loop ends by itself. WindowsTests/quit/run.sh sends the Quit.
 *   (no argument)  closes on WM_CLOSE, like a program without unsaved work
 *   keep           stays open on WM_CLOSE, like a program whose "save changes?" prompt was cancelled
 *   dialog         its main window is disabled behind a window it owns, like a program showing a modal dialog
 *   hidden         never shows its window */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static BOOL keep;

static void say(const char *what, HWND hwnd)
{
    char title[32] = "?";
    GetWindowTextA(hwnd, title, sizeof(title));
    printf("%s %s\n", what, title);
    fflush(stdout);
}

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    switch (msg) {
    case WM_CLOSE:
        say("WM_CLOSE", hwnd);
        if (keep) return 0;
        break; /* DefWindowProc destroys the window */
    case WM_QUERYENDSESSION:
        say("WM_QUERYENDSESSION", hwnd);
        break; /* DefWindowProc agrees, as in most programs */
    case WM_ENDSESSION:
        say("WM_ENDSESSION", hwnd);
        break;
    case WM_DESTROY:
        if (!GetWindow(hwnd, GW_OWNER)) PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

int main(int argc, char **argv)
{
    const char *mode = argc > 1 ? argv[1] : "";
    WNDCLASSA wc = {0};
    HWND main_window;
    MSG msg;

    keep = !strcmp(mode, "keep");
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "HarborQuitProbe";
    wc.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    RegisterClassA(&wc);
    main_window = CreateWindowA(wc.lpszClassName, "main", WS_OVERLAPPEDWINDOW, 200, 200, 320, 200,
                                NULL, NULL, wc.hInstance, NULL);
    if (!main_window) { printf("FAIL CreateWindow: %lu\n", GetLastError()); return 2; }
    if (strcmp(mode, "hidden")) ShowWindow(main_window, SW_SHOW);
    if (!strcmp(mode, "dialog")) {
        HWND dialog = CreateWindowA(wc.lpszClassName, "dialog", WS_POPUPWINDOW | WS_CAPTION | WS_VISIBLE,
                                    240, 240, 240, 120, main_window, NULL, wc.hInstance, NULL);
        if (!dialog) { printf("FAIL CreateWindow (dialog): %lu\n", GetLastError()); return 2; }
        EnableWindow(main_window, FALSE);
    }
    printf("READY %s\n", mode);
    fflush(stdout);
    while (GetMessageA(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageA(&msg);
    }
    printf("EXIT clean\n");
    fflush(stdout);
    return 0;
}
