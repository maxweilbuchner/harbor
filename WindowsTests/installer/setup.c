/* Fixture: an installer in several files, without a window. Beside it: target.txt (the folder to install into),
 * data-01.bin (the program) and Redist\marker. Installs data-01.bin as "<target>\Fixture App.exe" and notes the
 * folder it ran from in "<target>\installed-from.txt"; exits 1 if any of its files is missing, which is what
 * happens when only setup.exe reaches the bottle. */
#include <windows.h>
#include <stdio.h>
#include <string.h>

int WINAPI WinMain(HINSTANCE h, HINSTANCE p, LPSTR c, int n) {
    char dir[MAX_PATH], path[MAX_PATH * 2], target[MAX_PATH] = "", out[MAX_PATH * 2];
    GetModuleFileNameA(NULL, dir, sizeof dir);
    *strrchr(dir, '\\') = 0;

    snprintf(path, sizeof path, "%s\\target.txt", dir);
    FILE *f = fopen(path, "r");
    if (!f || !fgets(target, sizeof target, f)) return 1;
    fclose(f);
    target[strcspn(target, "\r\n")] = 0;

    snprintf(path, sizeof path, "%s\\Redist\\marker", dir);
    if (GetFileAttributesA(path) == INVALID_FILE_ATTRIBUTES) return 1;

    for (char *s = strchr(target + 3, '\\'); ; s = strchr(s + 1, '\\')) {      /* every level of the target */
        if (s) *s = 0;
        CreateDirectoryA(target, NULL);
        if (!s) break;
        *s = '\\';
    }
    /* Which test run this was (run.txt beside the installer, if any), before anything can fail: run.sh removes
     * only the bottle that carries its own number. */
    snprintf(path, sizeof path, "%s\\run.txt", dir);
    snprintf(out, sizeof out, "%s\\installed-by.txt", target);
    CopyFileA(path, out, FALSE);
    snprintf(path, sizeof path, "%s\\data-01.bin", dir);
    snprintf(out, sizeof out, "%s\\Fixture App.exe", target);
    if (!CopyFileA(path, out, FALSE)) return 1;
    snprintf(out, sizeof out, "%s\\installed-from.txt", target);            /* where the installer ran from */
    if ((f = fopen(out, "w"))) { fputs(dir, f); fclose(f); }
    return 0;
}
