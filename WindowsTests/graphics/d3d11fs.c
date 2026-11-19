/* Fullscreen transitions with D3D11/DXGI, the way games handle them. Each phase presents a solid colour
 * continuously; WindowsTests/graphics/fullscreen.sh samples the real screen centre to see what actually reached it.
 *   PHASE 1 green   fullscreen
 *   PHASE 2 yellow  after SetFullscreenState(FALSE) then TRUE again (leave + re-enter fullscreen)
 *   PHASE 3 cyan    after the host switches to another app and back (focus loss); we re-enter fullscreen on
 *                   WM_ACTIVATEAPP like well-behaved games do (argument "passive": we don't, like some
 *                   older engines; then the window should at least show its content windowed)
 *   PHASE 4 white   after the host switches Spaces away and back (three-finger swipe), then opens and
 *                   closes Mission Control (three-finger swipe up)
 * Uses the legacy DISCARD swap effect, as many DX11-era engines do. */
#define COBJMACROS
#define INITGUID
#include <d3d11.h>
#include "common.h"

static IDXGISwapChain *swap;
static ID3D11Device *dev;
static ID3D11DeviceContext *ctx;
static ID3D11RenderTargetView *rtv;
static volatile LONG resize_pending, reactivated;
static BOOL reenter_on_activate = TRUE; /* "passive" argument: behave like engines that ignore WM_ACTIVATEAPP */

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    if (msg == WM_SIZE) InterlockedExchange(&resize_pending, 1);
    if (msg == WM_ACTIVATEAPP && wp) InterlockedExchange(&reactivated, 1);
    return DefWindowProcA(hwnd, msg, wp, lp);
}

static void make_rtv(void)
{
    ID3D11Texture2D *back;
    CHECK(IDXGISwapChain_GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&back), "GetBuffer");
    CHECK(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &rtv), "CreateRenderTargetView");
    ID3D11Texture2D_Release(back);
}

static void resize(void)
{
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 0, NULL, NULL);
    if (rtv) { ID3D11RenderTargetView_Release(rtv); rtv = NULL; }
    CHECK(IDXGISwapChain_ResizeBuffers(swap, 0, 0, 0, DXGI_FORMAT_UNKNOWN, 0), "ResizeBuffers");
    make_rtv();
}

static void set_fullscreen(BOOL on)
{
    HRESULT hr = IDXGISwapChain_SetFullscreenState(swap, on, NULL);
    printf("INFO SetFullscreenState(%d) hr=0x%08lx\n", on, (unsigned long)hr);
    fflush(stdout);
    resize();
}

/* Presents `rgb` for `ms`, handling resizes, occlusion and reactivation like a game loop. */
static void present_for(const float rgb[3], DWORD ms)
{
    DWORD end = GetTickCount() + ms;
    float c[4] = {rgb[0], rgb[1], rgb[2], 1};
    while (GetTickCount() < end) {
        MSG m;
        while (PeekMessageA(&m, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&m); DispatchMessageA(&m); }
        if (InterlockedExchange(&reactivated, 0)) {
            BOOL fs = FALSE;
            IDXGISwapChain_GetFullscreenState(swap, &fs, NULL);
            printf("INFO reactivated, fullscreen=%d\n", fs);
            fflush(stdout);
            if (!fs && reenter_on_activate) set_fullscreen(TRUE);
        }
        if (InterlockedExchange(&resize_pending, 0)) resize();
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, c);
        HRESULT hr = IDXGISwapChain_Present(swap, 1, 0);
        if (hr != S_OK && hr != DXGI_STATUS_OCCLUDED) { printf("FAIL Present hr=0x%08lx\n", (unsigned long)hr); ExitProcess(2); }
        if (hr == DXGI_STATUS_OCCLUDED) Sleep(16);
    }
}

static void phase(int n, const char *name)
{
    printf("PHASE %d %s\n", n, name);
    fflush(stdout);
}

int main(int argc, char **argv)
{
    if (argc > 1 && !strcmp(argv[1], "passive")) reenter_on_activate = FALSE;
    static const float green[3] = {0, 1, 0}, yellow[3] = {1, 1, 0}, cyan[3] = {0, 1, 1}, magenta[3] = {1, 0, 1},
                       white[3] = {1, 1, 1};
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "HarborFullscreenTest";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA(wc.lpszClassName, "Harbor fullscreen test", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                              100, 100, 640, 400, NULL, NULL, wc.hInstance, NULL);

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.SampleDesc.Count = 1; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.BufferCount = 1;
    sd.OutputWindow = hwnd; sd.Windowed = TRUE; sd.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    sd.Flags = DXGI_SWAP_CHAIN_FLAG_ALLOW_MODE_SWITCH;
    CHECK(D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION,
                                        &sd, &swap, &dev, NULL, &ctx), "D3D11CreateDeviceAndSwapChain");
    make_rtv();

    set_fullscreen(TRUE);
    phase(1, "fullscreen");
    present_for(green, 4000);

    set_fullscreen(FALSE);
    present_for(magenta, 1500);
    set_fullscreen(TRUE);
    phase(2, "re-entered-fullscreen");
    present_for(yellow, 4000);

    phase(3, "await-focus-switch");
    present_for(cyan, 9000);

    phase(4, "await-space-switch");
    present_for(white, 25000);
    phase(5, "done");

    set_fullscreen(FALSE);
    present_for(magenta, 500);
    return 0;
}
