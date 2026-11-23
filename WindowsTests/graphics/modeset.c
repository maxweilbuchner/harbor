/* What a program's display mode change leaves behind (Wine's mode emulation, Harbor's patch 0013: the mode exists
 * only inside Wine). WindowsTests/graphics/modeset.sh runs these one after another in one bottle:
 *   get      prints the current mode and the largest one offered
 *   set-fs   changes to 640x480 the way fullscreen programs do (CDS_FULLSCREEN: temporary, Windows undoes it when
 *            the program ends) and exits without restoring
 *   set      changes to 640x480 for good (no flag: Windows keeps it after the program ends) and exits
 *   reset    back to the registry mode (ChangeDisplaySettings(NULL, 0))
 *   all      runs set-fs, set and reset as child processes, one after another, and prints the mode it sees after
 *            each has ended (one Windows session throughout) */
#include <windows.h>
#include <stdio.h>
#include <string.h>

static void print_current(const char *label)
{
    DEVMODEW cur = {0}, m = {0};
    DWORD i, best_w = 0, best_h = 0, count = 0;
    cur.dmSize = m.dmSize = sizeof(cur);
    EnumDisplaySettingsW(NULL, ENUM_CURRENT_SETTINGS, &cur);
    for (i = 0; EnumDisplaySettingsW(NULL, i, &m); i++, count++)
        if (m.dmPelsWidth * m.dmPelsHeight > best_w * best_h) { best_w = m.dmPelsWidth; best_h = m.dmPelsHeight; }
    printf("MODE %s current=%lux%lu largest=%lux%lu modes=%lu screen=%dx%d\n", label,
           (unsigned long)cur.dmPelsWidth, (unsigned long)cur.dmPelsHeight, (unsigned long)best_w, (unsigned long)best_h,
           (unsigned long)count, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
    fflush(stdout);
}

int main(int argc, char **argv)
{
    const char *cmd = argc > 1 ? argv[1] : "get";
    if (!strcmp(cmd, "all")) {
        static const char *steps[] = {"set-fs", "set", "reset"};
        char self[MAX_PATH], line[MAX_PATH + 32], label[32];
        GetModuleFileNameA(NULL, self, sizeof(self));
        print_current("start");
        for (int i = 0; i < 3; i++) {
            STARTUPINFOA si = {sizeof(si)};
            PROCESS_INFORMATION pi;
            snprintf(line, sizeof(line), "\"%s\" %s", self, steps[i]);
            if (!CreateProcessA(NULL, line, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) { printf("FAIL CreateProcess\n"); return 2; }
            WaitForSingleObject(pi.hProcess, 30000);
            Sleep(1000); /* the session notices the exit */
            snprintf(label, sizeof(label), "after-%s", steps[i]);
            print_current(label);
        }
        return 0;
    }
    if (!strcmp(cmd, "set") || !strcmp(cmd, "set-fs")) {
        DEVMODEW m = {0};
        m.dmSize = sizeof(m);
        m.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
        m.dmPelsWidth = 640; m.dmPelsHeight = 480;
        LONG r = ChangeDisplaySettingsExW(NULL, &m, NULL, !strcmp(cmd, "set-fs") ? CDS_FULLSCREEN : 0, NULL);
        printf("INFO %s ChangeDisplaySettingsEx=%ld\n", cmd, r);
    } else if (!strcmp(cmd, "reset")) {
        printf("INFO reset ChangeDisplaySettings=%ld\n", ChangeDisplaySettingsW(NULL, 0));
    }
    print_current(cmd);
    return 0;
}
