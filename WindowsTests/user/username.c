/* Regression test for the Windows user's name (scripts/patches/wine/0014): prints what GetUserNameW, GetUserNameA,
 * the profile folder and %USERPROFILE% say, as "user=<name> ansi=<name> profile=<path> env=<path>". */
#include <windows.h>
#include <shlobj.h>
#include <stdio.h>

int main(void)
{
    WCHAR name[256] = L"?", profile[MAX_PATH] = L"?", env[MAX_PATH] = L"?";
    char ansi[256] = "?";
    DWORD size = ARRAYSIZE(name);
    GetUserNameW(name, &size);
    size = sizeof(ansi);
    GetUserNameA(ansi, &size);
    SHGetFolderPathW(NULL, CSIDL_PROFILE, NULL, SHGFP_TYPE_CURRENT, profile);
    GetEnvironmentVariableW(L"USERPROFILE", env, ARRAYSIZE(env));
    printf("user=%ls ansi=%s profile=%ls env=%ls\n", name, ansi, profile, env);
    return 0;
}
