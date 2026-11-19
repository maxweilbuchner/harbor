/* harbor-wintree: dumps the full window tree of a Wine prefix (class, styles, owning pid, rects) and, with
 * "grab <hwnd-hex> <out.bmp>", saves what GDI sees in that window (GetDC + BitBlt) to a BMP.
 *   harbor-wintree.exe [tree] | all | grab <hwnd> <file.bmp>   ("all" also lists hidden top-level windows) */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int show_hidden;

static void describe(HWND hwnd, int depth)
{
    WCHAR title[96] = L"", cls[96] = L"";
    RECT r, c;
    DWORD pid = 0, tid = GetWindowThreadProcessId(hwnd, &pid);
    GetWindowTextW(hwnd, title, 96);
    GetClassNameW(hwnd, cls, 96);
    GetWindowRect(hwnd, &r);
    GetClientRect(hwnd, &c);
    printf("%*s%p pid=%04lx tid=%04lx %s cls=\"%ls\" style=%08lx ex=%08lx rect=%ld,%ld %ldx%ld client=%ldx%ld owner=%p \"%ls\"\n",
           depth * 2, "", (void *)hwnd, pid, tid, IsWindowVisible(hwnd) ? "VIS" : "hid", cls,
           (long)GetWindowLongW(hwnd, GWL_STYLE), (long)GetWindowLongW(hwnd, GWL_EXSTYLE),
           r.left, r.top, r.right - r.left, r.bottom - r.top, c.right, c.bottom,
           (void *)GetWindow(hwnd, GW_OWNER), title);
}

static void walk(HWND parent, int depth)
{
    for (HWND h = GetWindow(parent, GW_CHILD); h; h = GetWindow(h, GW_HWNDNEXT)) {
        if (depth == 0 && !show_hidden && !IsWindowVisible(h)) continue;
        describe(h, depth);
        walk(h, depth + 1);
    }
}

static int grab(HWND hwnd, const char *path)
{
    RECT c;
    GetClientRect(hwnd, &c);
    int w = c.right, h = c.bottom;
    HDC src = GetDC(hwnd), mem = CreateCompatibleDC(src);
    BITMAPINFO bi = {{sizeof(BITMAPINFOHEADER), w, -h, 1, 32, BI_RGB}};
    void *bits;
    HBITMAP bmp = CreateDIBSection(mem, &bi, DIB_RGB_COLORS, &bits, NULL, 0);
    SelectObject(mem, bmp);
    BitBlt(mem, 0, 0, w, h, src, 0, 0, SRCCOPY);
    GdiFlush();
    unsigned lit = 0, total = (unsigned)(w * h);
    for (unsigned i = 0; i < total; i++) {
        unsigned p = ((unsigned *)bits)[i];
        lit += ((p & 0xff) + ((p >> 8) & 0xff) + ((p >> 16) & 0xff)) > 60;
    }
    printf("grab %p %dx%d: %u%% non-black\n", (void *)hwnd, w, h, total ? lit * 100 / total : 0);
    BITMAPFILEHEADER fh = {0x4d42, sizeof(fh) + sizeof(BITMAPINFOHEADER) + total * 4, 0, 0, sizeof(fh) + sizeof(BITMAPINFOHEADER)};
    FILE *f = fopen(path, "wb");
    if (!f) return 1;
    fwrite(&fh, sizeof(fh), 1, f); fwrite(&bi.bmiHeader, sizeof(BITMAPINFOHEADER), 1, f); fwrite(bits, 4, total, f);
    fclose(f);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc > 3 && !strcmp(argv[1], "grab"))
        return grab((HWND)(ULONG_PTR)strtoull(argv[2], NULL, 16), argv[3]);
    show_hidden = argc > 1 && !strcmp(argv[1], "all");
    walk(GetDesktopWindow(), 0);
    fflush(stdout);
    return 0;
}
