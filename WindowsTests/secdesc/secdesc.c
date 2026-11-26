/* Regression test for RtlValidRelativeSecurityDescriptor (scripts/patches/wine/0018): Wine compared a BOOLEAN with
 * STATUS_SUCCESS and so answered the wrong way round. Microsoft's offreg.dll refuses every registry hive when a
 * valid descriptor is reported invalid, which left Office's Click-to-Run registry empty (#91).
 * Exit 0 = all pass. */
#include <windows.h>
#include <sddl.h>
#include <stdio.h>
#include <string.h>

BOOLEAN WINAPI RtlValidRelativeSecurityDescriptor(PSECURITY_DESCRIPTOR descriptor, ULONG length, SECURITY_INFORMATION info);

static int failed;

static void check(const char *what, BOOLEAN got, BOOLEAN expected)
{
    if (got == expected) printf("PASS: %s\n", what);
    else { printf("FAIL: %s: got %d, expected %d\n", what, got, expected); failed = 1; }
}

int main(void)
{
    static const SECURITY_INFORMATION all = OWNER_SECURITY_INFORMATION | GROUP_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION;
    PSECURITY_DESCRIPTOR sd;
    BYTE copy[256];
    ULONG len;

    /* Owner and group Administrators, everyone full access: comes back self-relative. */
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(L"O:BAG:BAD:(A;;GA;;;WD)", SDDL_REVISION_1, &sd, &len) ||
        len > sizeof(copy))
    {
        printf("FAIL: no descriptor to test with (error %lu, %lu bytes)\n", GetLastError(), len);
        return 1;
    }
    check("a valid self-relative descriptor is valid", RtlValidRelativeSecurityDescriptor(sd, len, all), TRUE);

    memcpy(copy, sd, len);
    ((SECURITY_DESCRIPTOR_RELATIVE *)copy)->Revision = 0;
    check("a descriptor with revision 0 is invalid", RtlValidRelativeSecurityDescriptor(copy, len, all), FALSE);

    check("no descriptor is invalid", RtlValidRelativeSecurityDescriptor(NULL, 0, all), FALSE);

    LocalFree(sd);
    return failed;
}
