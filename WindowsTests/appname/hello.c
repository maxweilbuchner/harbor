/* Regression test for program file names that collide with the loader link directory's own entries
 * (scripts/patches/wine/0016, on 0006/0008): the program's Mac process is started through a link named after
 * its file, and "ntdll.so.exe" or "..exe" named a link that is already something else there.
 *   hello.exe               prints HELLO
 *   hello.exe spawn <file>  starts <file> from its own folder (CreateProcess) and prints SPAWNED <exit code> */
#include <windows.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char **argv)
{
    char path[MAX_PATH], *slash;
    STARTUPINFOA si = { sizeof(si) };
    PROCESS_INFORMATION pi;
    DWORD code = 99;

    if (argc < 3 || strcmp(argv[1], "spawn")) { printf("HELLO\n"); fflush(stdout); return 0; }
    GetModuleFileNameA(NULL, path, sizeof(path));
    if (!(slash = strrchr(path, '\\')) || (slash - path) + strlen(argv[2]) + 2 > sizeof(path)) return 2;
    strcpy(slash + 1, argv[2]);
    if (!CreateProcessA(path, NULL, NULL, NULL, TRUE, 0, NULL, NULL, &si, &pi)) {
        printf("FAIL CreateProcess %s: error %lu\n", argv[2], GetLastError());
        fflush(stdout);
        return 1;
    }
    WaitForSingleObject(pi.hProcess, 20000);
    GetExitCodeProcess(pi.hProcess, &code);
    printf("SPAWNED %lu\n", code);
    fflush(stdout);
    return code ? 1 : 0;
}
