/* mshtmltest: three things a page written for Internet Explorer 10/11 relies on, which Office's add-in Store
 * page tripped over in Wine's HTML and script engines (#100). Loads page.html (next to this program's source,
 * path given as the argument) into an HTML document object and reads the results from the page's title:
 *   - element.children holds elements only, no comments (IE9 standards mode and later);
 *   - Function.prototype.apply accepts undefined as "no arguments";
 *   - a <script defer src> runs after the page has been parsed.
 *   mshtmltest.exe <path to page.html>      prints one PASS/FAIL line per check, exit code 0/1 */
#define COBJMACROS
#include <windows.h>
#include <ole2.h>
#include <mshtml.h>
#include <urlmon.h>
#include <shlwapi.h>
#include <stdio.h>

#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))

/* not in the toolchain's uuid library */
static const GUID clsid_html_document = {0x25336920, 0x03f9, 0x11cf, {0x8f, 0xd0, 0x00, 0xaa, 0x00, 0x68, 0x6f, 0x13}};

static int failed;
static void check(int ok, const char *what) { printf("%s: %s\n", ok ? "PASS" : "FAIL", what); if (!ok) failed = 1; fflush(stdout); }

int wmain(int argc, WCHAR **argv)
{
    IHTMLDocument2 *doc = NULL; IPersistMoniker *persist = NULL; IMoniker *moniker = NULL; IBindCtx *bind_ctx = NULL;
    BSTR title = NULL; WCHAR path[MAX_PATH], url[2 * MAX_PATH]; DWORD len = ARRAY_SIZE(url), end; MSG msg; HRESULT hr;

    if (argc < 2 || !GetFullPathNameW(argv[1], MAX_PATH, path, NULL)) { printf("FAIL: no page given\n"); return 1; }
    OleInitialize(NULL);
    /* Loaded from its file address, so that the page's own script file is found beside it. */
    if (FAILED(hr = UrlCreateFromPathW(path, url, &len, 0)) ||
        FAILED(hr = CoCreateInstance(&clsid_html_document, NULL, CLSCTX_INPROC_SERVER, &IID_IHTMLDocument2, (void **)&doc)) ||
        FAILED(hr = IHTMLDocument2_QueryInterface(doc, &IID_IPersistMoniker, (void **)&persist)) ||
        FAILED(hr = CreateURLMoniker(NULL, url, &moniker)) || FAILED(hr = CreateBindCtx(0, &bind_ctx)) ||
        FAILED(hr = IPersistMoniker_Load(persist, FALSE, moniker, bind_ctx, STGM_READ)))
    { printf("FAIL: the page couldn't be loaded (0x%08lx)\n", (unsigned long)hr); return 1; }

    /* The page sets its title when it has loaded; until then it is "running". */
    for (end = GetTickCount() + 30000; GetTickCount() < end; )
    {
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
        SysFreeString(title); title = NULL;
        if (SUCCEEDED(IHTMLDocument2_get_title(doc, &title)) && title && wcsncmp(title, L"mode=", 5) == 0) break;
        Sleep(20);
    }
    printf("title: %ls\n", title ? title : L"(none)");
    if (!title || wcsncmp(title, L"mode=", 5)) { check(0, "the page's scripts ran to the end"); return 1; }
    check(wcsstr(title, L"mode=10 ") != NULL, "the page is in the document mode it asks for (IE 10)");
    check(wcsstr(title, L" children=1:SPAN ") != NULL, "element.children holds elements only");
    check(wcsstr(title, L" apply=0 ") != NULL, "apply(thisArg, undefined) calls with no arguments");
    check(wcsstr(title, L" defer=true") != NULL, "a deferred script runs after the page is parsed");
    return failed;
}
