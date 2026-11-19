/* Shared helpers for Harbor's graphics test programs (Windows side, built with llvm-mingw). */
#pragma once
#pragma clang diagnostic ignored "-Wunused-function" /* each test uses a subset of these helpers */
#include <windows.h>
#include <stdio.h>
#include <d3dcompiler.h>

#define W 256
#define H 256
/* Clear colour (0.1, 0.2, 0.4) → bytes (26, 51, 102). */
static const float CLEAR[4] = {0.1f, 0.2f, 0.4f, 1.0f};

/* A triangle generated from SV_VertexID: no vertex buffers or input layout, red/green/blue corners. */
static const char SHADER[] =
    "struct V { float4 pos : SV_Position; float4 col : COLOR; };\n"
    "V vs(uint id : SV_VertexID) {\n"
    "  float2 p[3] = { float2(0.0, 0.8), float2(0.8, -0.8), float2(-0.8, -0.8) };\n"
    "  float4 c[3] = { float4(1,0,0,1), float4(0,1,0,1), float4(0,0,1,1) };\n"
    "  V v; v.pos = float4(p[id], 0, 1); v.col = c[id]; return v;\n"
    "}\n"
    "float4 ps(V v) : SV_Target { return v.col; }\n";

#define CHECK(hr, what) do { HRESULT _hr = (hr); if (FAILED(_hr)) { \
    printf("FAIL %s: hr=0x%08lx\n", what, (unsigned long)_hr); fflush(stdout); ExitProcess(2); } } while (0)

typedef HRESULT (WINAPI *compile_fn)(const void *, SIZE_T, const char *, const D3D_SHADER_MACRO *, ID3DInclude *,
                                     const char *, const char *, UINT, UINT, ID3DBlob **, ID3DBlob **);

static ID3DBlob *compile(const char *entry, const char *target)
{
    static compile_fn fn;
    ID3DBlob *code = NULL, *errors = NULL;
    if (!fn) {
        HMODULE m = LoadLibraryA("d3dcompiler_47.dll");
        fn = m ? (compile_fn)GetProcAddress(m, "D3DCompile") : NULL;
        if (!fn) { printf("FAIL d3dcompiler_47 not available\n"); ExitProcess(2); }
    }
    HRESULT hr = fn(SHADER, sizeof(SHADER) - 1, "harbor", NULL, NULL, entry, target, 0, 0, &code, &errors);
    if (FAILED(hr)) {
        printf("FAIL compile %s: %s\n", entry, errors ? (const char *)ID3D10Blob_GetBufferPointer(errors) : "?");
        ExitProcess(2);
    }
    return code;
}

/* Checks the readback (RGBA8 rows of `pitch` bytes) and writes it as a 24-bit BMP. Returns 0 on pass. */
static int verify_and_save(const unsigned char *px, UINT pitch, const char *path, const char *label)
{
    const unsigned char *corner = px + 2 * pitch + 2 * 4;
    const unsigned char *centre = px + (H / 2) * pitch + (W / 2) * 4;
    int corner_ok = abs(corner[0] - 26) <= 2 && abs(corner[1] - 51) <= 2 && abs(corner[2] - 102) <= 2;
    int centre_ok = !(abs(centre[0] - 26) <= 2 && abs(centre[1] - 51) <= 2 && abs(centre[2] - 102) <= 2)
                    && centre[0] + centre[1] + centre[2] > 150;

    FILE *f = fopen(path, "wb");
    if (f) {
        UINT row = W * 3, size = 54 + row * H;
        unsigned char hdr[54] = {'B', 'M'};
        *(UINT *)(hdr + 2) = size; *(UINT *)(hdr + 10) = 54; *(UINT *)(hdr + 14) = 40;
        *(INT *)(hdr + 18) = W; *(INT *)(hdr + 22) = -H; *(WORD *)(hdr + 26) = 1; *(WORD *)(hdr + 28) = 24;
        fwrite(hdr, 1, 54, f);
        for (UINT y = 0; y < H; y++)
            for (UINT x = 0; x < W; x++) {
                const unsigned char *p = px + y * pitch + x * 4;
                unsigned char bgr[3] = {p[2], p[1], p[0]};
                fwrite(bgr, 1, 3, f);
            }
        fclose(f);
    }
    printf("%s %s: corner=(%d,%d,%d) centre=(%d,%d,%d) -> %s\n", corner_ok && centre_ok ? "PASS" : "FAIL", label,
           corner[0], corner[1], corner[2], centre[0], centre[1], centre[2], path);
    fflush(stdout);
    return corner_ok && centre_ok ? 0 : 1;
}

static HWND make_window(const char *title)
{
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "HarborTest";
    RegisterClassA(&wc);
    RECT r = {0, 0, W, H};
    AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);
    HWND hwnd = CreateWindowA("HarborTest", title, WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100,
                              r.right - r.left, r.bottom - r.top, NULL, NULL, wc.hInstance, NULL);
    return hwnd;
}

static void pump(DWORD ms)
{
    DWORD end = GetTickCount() + ms;
    MSG msg;
    while (GetTickCount() < end) {
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        Sleep(10);
    }
}
