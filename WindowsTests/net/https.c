/* HTTPS through WinHTTP, the way most Windows programs fetch from the web (it uses Wine's secur32 →
 * GnuTLS for TLS). Usage: https.exe [host]   (default example.com). Prints PASS with the HTTP status.
 * Exit 0 = TLS handshake, certificate validation and a 200 response all worked. */
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>

int main(int argc, char **argv)
{
    WCHAR host[256] = L"example.com";
    if (argc > 1) MultiByteToWideChar(CP_UTF8, 0, argv[1], -1, host, 256);

    HINTERNET session = WinHttpOpen(L"HarborTest/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, NULL, NULL, 0);
    HINTERNET conn = session ? WinHttpConnect(session, host, INTERNET_DEFAULT_HTTPS_PORT, 0) : NULL;
    HINTERNET req = conn ? WinHttpOpenRequest(conn, L"GET", L"/", NULL, NULL, NULL, WINHTTP_FLAG_SECURE) : NULL;
    if (!req) { printf("FAIL open: error %lu\n", GetLastError()); return 2; }
    if (!WinHttpSendRequest(req, NULL, 0, NULL, 0, 0, 0) || !WinHttpReceiveResponse(req, NULL)) {
        printf("FAIL request: error %lu\n", GetLastError());
        return 1;
    }
    DWORD status = 0, size = sizeof(status);
    WinHttpQueryHeaders(req, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER, NULL, &status, &size, NULL);
    DWORD total = 0, got;
    char buf[4096];
    while (WinHttpReadData(req, buf, sizeof(buf), &got) && got) total += got;
    printf("%s https://%ls/ status=%lu bytes=%lu\n", status == 200 ? "PASS" : "FAIL", host, status, total);
    WinHttpCloseHandle(req); WinHttpCloseHandle(conn); WinHttpCloseHandle(session);
    return status == 200 ? 0 : 1;
}
