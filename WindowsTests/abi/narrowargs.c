/* Regression test for byte-sized syscall arguments (scripts/patches/wine/0002): llvm-mingw's clang writes only
 * the low byte of a BOOLEAN argument while Wine's Unix side read all 32 bits, so e.g. NtQueryDirectoryObject's
 * "restart" was always TRUE and QueryDosDeviceW(NULL) / GetLogicalDrives never finished (Steam hung on it).
 * Each check runs on a thread with a timeout, so a regression reports FAIL instead of hanging.
 * Exit 0 = all pass. */
#include <windows.h>
#include <stdio.h>

/* Leaves 0xFF in the stack below us, like a real program's earlier calls leave junk. The bug only shows when the
 * argument slot's upper bytes are non-zero; a freshly started test thread has a clean stack and would pass. */
static __attribute__((noinline)) void dirty_stack(void)
{
    volatile unsigned char junk[128 * 1024];
    for (size_t i = 0; i < sizeof(junk); i++) junk[i] = 0xFF;
}

static DWORD WINAPI query_dos_devices(void *result)
{
    static WCHAR buf[65536];
    dirty_stack();
    DWORD len = QueryDosDeviceW(NULL, buf, ARRAYSIZE(buf));
    int count = 0;
    for (WCHAR *p = buf; len && *p; p += wcslen(p) + 1) count++;
    *(int *)result = len ? count : -(int)GetLastError();
    return 0;
}

static DWORD WINAPI logical_drives(void *result)
{
    dirty_stack();
    *(int *)result = (int)GetLogicalDrives();
    return 0;
}

static int check(const char *name, LPTHREAD_START_ROUTINE fn, int ok_min)
{
    int result = 0;
    HANDLE t = CreateThread(NULL, 1 << 20, fn, &result, 0, NULL);
    if (WaitForSingleObject(t, 10000) == WAIT_TIMEOUT) {
        printf("FAIL %s: still running after 10 s (narrow syscall argument misread?)\n", name);
        return 1;
    }
    int ok = result >= ok_min;
    printf("%s %s: %d\n", ok ? "PASS" : "FAIL", name, result);
    return !ok;
}

/* RTL_ATOM is 16 bits: pass it with garbage in the register's upper bits, as a compiler that only writes the low
 * word may leave it. Result 1 if both checks hold, 0 if not, -1 if the atom could not be created. */
static DWORD WINAPI delete_dirty_atom(void *arg)
{
    typedef LONG (WINAPI *add_fn)(const WCHAR *, ULONG, unsigned short *);
    typedef LONG (WINAPI *del_fn)(ULONG_PTR);
    HMODULE ntdll = GetModuleHandleA("ntdll.dll");
    add_fn add = (add_fn)(void *)GetProcAddress(ntdll, "NtAddAtom");
    del_fn del = (del_fn)(void *)GetProcAddress(ntdll, "NtDeleteAtom");
    static const WCHAR name[] = L"harbor_narrow_atom";
    unsigned short atom = 0;
    if (!add || !del || add(name, sizeof(name) - sizeof(WCHAR), &atom) || !atom) { *(int *)arg = -1; return 0; }
    /* An existing atom is deleted, and atom 0 is still refused (STATUS_INVALID_HANDLE): Apple clang tests all 32
     * bits of the register for zero, so with garbage above the atom, 0 passed as valid. */
    *(int *)arg = del((ULONG_PTR)0xdead0000 | atom) == 0 && del((ULONG_PTR)0xdead0000) == (LONG)0xC0000008;
    return 0;
}

int main(void)
{
    int failures = check("QueryDosDeviceW(NULL) entries", query_dos_devices, 1);
    failures += check("GetLogicalDrives mask", logical_drives, 1);
    failures += check("NtDeleteAtom with dirty upper bits", delete_dirty_atom, 1);
    fflush(stdout);
    ExitProcess(failures ? 1 : 0);
}
