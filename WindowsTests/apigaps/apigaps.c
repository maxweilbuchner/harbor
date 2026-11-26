/* Regression test for six small gaps in Wine that each stopped Microsoft 365 Excel (#92; scripts/patches/wine/
 * 0019 to 0024). Every function is looked up at run time: two of them don't exist without the patches, and a
 * program that imports a missing function doesn't start, which would hide the other results.
 * Exit 0 = all pass. */
#include <windows.h>
#include <wininet.h>
#include <rpc.h>
#include <stdio.h>
#include <string.h>

static int failed;

static void check(int ok, const char *what, const char *detail)
{
    if (ok) printf("PASS: %s\n", what);
    else { printf("FAIL: %s: %s\n", what, detail); failed = 1; }
}

static void *find(const char *dll, const char *name)
{
    HMODULE module = LoadLibraryA(dll);
    return module ? (void *)GetProcAddress(module, name) : NULL;
}

/* 0019: asked about an ordinary volume, the call must not succeed with nothing filled in. Excel reads the first
 * entry after a success whatever the count says. */
static void storage_dependency(void)
{
    DWORD (WINAPI *get)(HANDLE, DWORD, ULONG, void *, ULONG *) = find("virtdisk.dll", "GetStorageDependencyInformation");
    DWORD buffer[256], ret;
    ULONG used = 0;
    char detail[64];
    HANDLE root = CreateFileW(L"C:\\", 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                              FILE_FLAG_BACKUP_SEMANTICS, NULL);

    if (!get || root == INVALID_HANDLE_VALUE) { check(0, "GetStorageDependencyInformation on an ordinary volume fails", "no function or no handle"); return; }
    memset(buffer, 0xAA, sizeof(buffer));
    buffer[0] = 2;   /* STORAGE_DEPENDENCY_INFO_VERSION_2 */
    ret = get(root, 1 /* GET_STORAGE_DEPENDENCY_FLAG_HOST_VOLUMES */, sizeof(buffer), buffer, &used);
    sprintf(detail, "returned %lu", ret);
    check(ret != ERROR_SUCCESS, "GetStorageDependencyInformation on an ordinary volume fails", detail);
    CloseHandle(root);
}

/* 0020: Office sets this before its account requests and gives up when it can't. */
static void listen_timeout(void)
{
    HINTERNET session = InternetOpenW(L"apigaps", INTERNET_OPEN_TYPE_DIRECT, NULL, NULL, 0);
    DWORD value = 30000;
    char detail[64];
    BOOL ok = session && InternetSetOptionW(session, 11 /* INTERNET_OPTION_LISTEN_TIMEOUT */, &value, sizeof(value));

    sprintf(detail, "error %lu", GetLastError());
    check(ok, "InternetSetOption accepts INTERNET_OPTION_LISTEN_TIMEOUT", detail);
    if (session) InternetCloseHandle(session);
}

/* 0021: alignment as for TrackPopupMenu, and the result stays on the anchor's monitor. */
static void popup_position(void)
{
    BOOL (WINAPI *calc)(const POINT *, const SIZE *, UINT, RECT *, RECT *) = find("user32.dll", "CalculatePopupWindowPosition");
    MONITORINFO info = { sizeof(info) };
    POINT anchor;
    SIZE size = { 50, 40 };
    RECT pos;
    char detail[96];
    int ok;

    if (!calc) { check(0, "CalculatePopupWindowPosition places a popup", "no such function"); return; }
    GetMonitorInfoW(MonitorFromPoint((POINT){ 0, 0 }, MONITOR_DEFAULTTOPRIMARY), &info);
    anchor.x = info.rcMonitor.left + 200; anchor.y = info.rcMonitor.top + 200;

    ok = calc(&anchor, &size, TPM_LEFTALIGN | TPM_TOPALIGN, NULL, &pos) &&
         pos.left == anchor.x && pos.top == anchor.y && pos.right == anchor.x + 50 && pos.bottom == anchor.y + 40;
    sprintf(detail, "left/top: (%ld,%ld)-(%ld,%ld)", pos.left, pos.top, pos.right, pos.bottom);
    if (ok)
    {
        ok = calc(&anchor, &size, TPM_RIGHTALIGN | TPM_BOTTOMALIGN, NULL, &pos) &&
             pos.right == anchor.x && pos.bottom == anchor.y && pos.left == anchor.x - 50 && pos.top == anchor.y - 40;
        sprintf(detail, "right/bottom: (%ld,%ld)-(%ld,%ld)", pos.left, pos.top, pos.right, pos.bottom);
    }
    if (ok)
    {
        anchor.x = info.rcMonitor.right - 10; anchor.y = info.rcMonitor.bottom - 10;
        ok = calc(&anchor, &size, TPM_LEFTALIGN | TPM_TOPALIGN, NULL, &pos) &&
             pos.right <= info.rcMonitor.right && pos.bottom <= info.rcMonitor.bottom &&
             pos.right - pos.left == 50 && pos.bottom - pos.top == 40;
        sprintf(detail, "at the monitor's corner: (%ld,%ld)-(%ld,%ld)", pos.left, pos.top, pos.right, pos.bottom);
    }
    check(ok, "CalculatePopupWindowPosition places a popup", detail);
}

/* 0022: exists, and fails as it does on Windows for a program without SeRestorePrivilege. */
static void short_name(void)
{
    BOOL (WINAPI *set)(HANDLE, const WCHAR *) = find("kernel32.dll", "SetFileShortNameW");
    WCHAR dir[MAX_PATH], path[MAX_PATH];
    char detail[64];
    HANDLE file;
    BOOL ret;
    DWORD err;

    if (!set) { check(0, "SetFileShortNameW exists and reports the missing privilege", "no such function"); return; }
    GetTempPathW(MAX_PATH, dir);
    GetTempFileNameW(dir, L"gap", 0, path);
    file = CreateFileW(path, GENERIC_WRITE | DELETE, 0, NULL, OPEN_EXISTING, FILE_FLAG_DELETE_ON_CLOSE, NULL);
    SetLastError(0xdeadbeef);
    ret = set(file, L"GAPTEST.TMP");
    err = GetLastError();
    sprintf(detail, "returned %d, error %lu", ret, err);
    check(!ret && err == ERROR_PRIVILEGE_NOT_HELD, "SetFileShortNameW exists and reports the missing privilege", detail);
    CloseHandle(file);
}

/* 0023: Excel imports it from ole32. */
static void activation_filter(void)
{
    HRESULT (WINAPI *reg)(void *) = find("ole32.dll", "CoRegisterActivationFilter");
    char detail[64];
    HRESULT hr;

    if (!reg) { check(0, "ole32 has CoRegisterActivationFilter", "no such function"); return; }
    hr = reg(NULL);
    sprintf(detail, "returned 0x%08lx", hr);
    check(hr == S_OK, "ole32 has CoRegisterActivationFilter", detail);
}

/* 0024: a server that offers Kerberos beside other services must still start on a build without Kerberos. */
static void kerberos_registration(void)
{
    RPC_STATUS status = RpcServerRegisterAuthInfoW(NULL, RPC_C_AUTHN_GSS_KERBEROS, NULL, NULL);
    char detail[64];

    sprintf(detail, "status %ld", status);
    check(status == RPC_S_OK, "RpcServerRegisterAuthInfo accepts Kerberos", detail);
}

int main(void)
{
    storage_dependency();
    listen_timeout();
    popup_position();
    short_name();
    activation_filter();
    kerberos_registration();
    return failed;
}
