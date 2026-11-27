/* A swap chain in a child window, as Office builds its window from (#94): what must reach the screen.
 * Usage: childswap.exe blt|alpha|flip|none|stack|still
 *   blt:  bit-block model, one buffer; every frame is cleared to blue and presented.
 *   alpha: as blt, but the blue has alpha 0. The swap chain's alpha mode is "ignore": it must be as opaque.
 *   flip: flip model, two buffers. Frame 1 is all red. Frame 2 draws only the left half green and presents with
 *         that half as its dirty rectangle: the right half must still be red, although the buffer being drawn
 *         to is not the one frame 1 was drawn to.
 *   none: flip model with DXGI_SCALING_NONE and buffers of 500x400, larger than the 400x300 child, as Office
 *         makes them. All red with a 200x150 green block in the top left corner: the block must be 200x150 on
 *         screen, not scaled down with the buffer.
 *   stack: two swap chains, one in the child (red) and one in a 200x150 window inside that child at (100,75)
 *         (green), each presented several times in turn. The inner window must stay green and the rest red:
 *         the outer one's picture must not cover the window inside it.
 *   still: as blt, but one frame only, and no message is dispatched after it: the frame must reach the screen
 *         without the program's message loop running (a browser's GPU process presents like this, #95).
 * Prints "READY" when the last frame is presented, then keeps the window for 12 seconds so the runner
 * (childswap.sh) can look at the screen. The top-level window is white; the child is at (120,80), 400x300. */
#define COBJMACROS
#include "common.h"
#include <d3d11.h>
#include <dxgi1_2.h>

#define CLIENT_W 640
#define CLIENT_H 480
#define CHILD_X 120
#define CHILD_Y 80
#define CHILD_W 400
#define CHILD_H 300

int main(int argc, char **argv)
{
    int none = argc > 1 && !strcmp(argv[1], "none");
    int flip = none || (argc > 1 && !strcmp(argv[1], "flip"));
    int still = argc > 1 && !strcmp(argv[1], "still");
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = DefWindowProcA;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "HarborChildSwap";
    wc.hbrBackground = (HBRUSH)GetStockObject(WHITE_BRUSH);
    RegisterClassA(&wc);
    RECT r = {0, 0, CLIENT_W, CLIENT_H};
    AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);
    HWND top = CreateWindowA("HarborChildSwap", "Harbor child swap test", WS_OVERLAPPEDWINDOW | WS_VISIBLE | WS_CLIPCHILDREN,
                             100, 100, r.right - r.left, r.bottom - r.top, NULL, NULL, wc.hInstance, NULL);
    HWND child = CreateWindowA("HarborChildSwap", "", WS_CHILD | WS_VISIBLE | WS_CLIPCHILDREN, CHILD_X, CHILD_Y, CHILD_W, CHILD_H,
                               top, NULL, wc.hInstance, NULL);
    pump(300);

    ID3D11Device *dev; ID3D11DeviceContext *ctx;
    CHECK(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, D3D11_CREATE_DEVICE_BGRA_SUPPORT, NULL, 0,
                            D3D11_SDK_VERSION, &dev, NULL, &ctx), "D3D11CreateDevice");
    IDXGIDevice *dxgi_dev; IDXGIAdapter *adapter; IDXGIFactory2 *factory;
    CHECK(ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxgi_dev), "IDXGIDevice");
    CHECK(IDXGIDevice_GetAdapter(dxgi_dev, &adapter), "GetAdapter");
    CHECK(IDXGIAdapter_GetParent(adapter, &IID_IDXGIFactory2, (void **)&factory), "IDXGIFactory2");

    DXGI_SWAP_CHAIN_DESC1 sd = {0};
    sd.Width = none ? 500 : CHILD_W; sd.Height = none ? 400 : CHILD_H; sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sd.Scaling = none ? DXGI_SCALING_NONE : DXGI_SCALING_STRETCH;
    sd.SampleDesc.Count = 1; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = flip ? 2 : 1;
    sd.SwapEffect = flip ? DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL : DXGI_SWAP_EFFECT_DISCARD;
    IDXGISwapChain1 *swap;
    CHECK(IDXGIFactory2_CreateSwapChainForHwnd(factory, (IUnknown *)dev, child, &sd, NULL, NULL, &swap), "CreateSwapChainForHwnd");

    static const float red[4] = {1, 0, 0, 1}, green[4] = {0, 1, 0, 1};
    float blue[4] = {0, 0, 1, 1};
    ID3D11Texture2D *back; ID3D11RenderTargetView *rtv;
    if (argc > 1 && !strcmp(argv[1], "alpha")) blue[3] = 0;
    if (argc > 1 && !strcmp(argv[1], "stack"))
    {
        /* The outer one alone first: a window that was presented to before it got company must behave too. */
        for (int frame = 0; frame < 3; frame++)
        {
            CHECK(IDXGISwapChain1_GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&back), "GetBuffer");
            CHECK(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &rtv), "CreateRenderTargetView");
            ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, red);
            ID3D11RenderTargetView_Release(rtv); ID3D11Texture2D_Release(back);
            CHECK(IDXGISwapChain1_Present(swap, 0, 0), "Present");
            pump(60);
        }
        HWND inner = CreateWindowA("HarborChildSwap", "", WS_CHILD | WS_VISIBLE, 100, 75, 200, 150, child, NULL, wc.hInstance, NULL);
        IDXGISwapChain1 *inner_swap;
        sd.Width = 200; sd.Height = 150;
        CHECK(IDXGIFactory2_CreateSwapChainForHwnd(factory, (IUnknown *)dev, inner, &sd, NULL, NULL, &inner_swap), "CreateSwapChainForHwnd (inner)");
        for (int frame = 0; frame < 8; frame++)
        {
            IDXGISwapChain1 *which = frame % 2 ? inner_swap : swap;
            CHECK(IDXGISwapChain1_GetBuffer(which, 0, &IID_ID3D11Texture2D, (void **)&back), "GetBuffer");
            CHECK(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &rtv), "CreateRenderTargetView");
            ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, frame % 2 ? green : red);
            ID3D11RenderTargetView_Release(rtv); ID3D11Texture2D_Release(back);
            CHECK(IDXGISwapChain1_Present(which, 0, 0), "Present");
            pump(60);
        }
        /* The outer one last, so its picture is the newest. */
        CHECK(IDXGISwapChain1_GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&back), "GetBuffer");
        CHECK(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &rtv), "CreateRenderTargetView");
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, red);
        ID3D11RenderTargetView_Release(rtv); ID3D11Texture2D_Release(back);
        CHECK(IDXGISwapChain1_Present(swap, 0, 0), "Present");
    }
    else if (!flip)
    {
        for (int frame = 0; frame < (still ? 1 : 10); frame++)
        {
            CHECK(IDXGISwapChain1_GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&back), "GetBuffer");
            CHECK(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &rtv), "CreateRenderTargetView");
            ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, blue);
            ID3D11RenderTargetView_Release(rtv); ID3D11Texture2D_Release(back);
            CHECK(IDXGISwapChain1_Present(swap, 0, 0), "Present");
            if (!still) pump(30);
        }
    }
    else if (none)
    {
        D3D11_TEXTURE2D_DESC td = {200, 150, 1, 1, DXGI_FORMAT_B8G8R8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT,
                                   D3D11_BIND_RENDER_TARGET, 0, 0};
        ID3D11Texture2D *block;
        CHECK(ID3D11Device_CreateTexture2D(dev, &td, NULL, &block), "CreateTexture2D");
        CHECK(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)block, NULL, &rtv), "CreateRenderTargetView");
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, green);
        ID3D11RenderTargetView_Release(rtv);
        for (int frame = 0; frame < 4; frame++)
        {
            CHECK(IDXGISwapChain1_GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&back), "GetBuffer");
            CHECK(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &rtv), "CreateRenderTargetView");
            ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, red);
            ID3D11DeviceContext_CopySubresourceRegion(ctx, (ID3D11Resource *)back, 0, 0, 0, 0, (ID3D11Resource *)block, 0, NULL);
            ID3D11RenderTargetView_Release(rtv); ID3D11Texture2D_Release(back);
            CHECK(IDXGISwapChain1_Present(swap, 0, 0), "Present");
            pump(30);
        }
    }
    else
    {
        /* Frame 1: all red. */
        CHECK(IDXGISwapChain1_GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&back), "GetBuffer");
        CHECK(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &rtv), "CreateRenderTargetView");
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, red);
        ID3D11RenderTargetView_Release(rtv); ID3D11Texture2D_Release(back);
        CHECK(IDXGISwapChain1_Present(swap, 0, 0), "Present");
        pump(100);

        /* Frame 2: only the left half, copied in from a green texture, and declared as the dirty rectangle. */
        D3D11_TEXTURE2D_DESC td = {CHILD_W / 2, CHILD_H, 1, 1, DXGI_FORMAT_B8G8R8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT,
                                   D3D11_BIND_RENDER_TARGET, 0, 0};
        ID3D11Texture2D *half;
        CHECK(ID3D11Device_CreateTexture2D(dev, &td, NULL, &half), "CreateTexture2D");
        CHECK(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)half, NULL, &rtv), "CreateRenderTargetView");
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, green);
        ID3D11RenderTargetView_Release(rtv);
        CHECK(IDXGISwapChain1_GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&back), "GetBuffer");
        ID3D11DeviceContext_CopySubresourceRegion(ctx, (ID3D11Resource *)back, 0, 0, 0, 0, (ID3D11Resource *)half, 0, NULL);
        ID3D11Texture2D_Release(back);
        RECT dirty = {0, 0, CHILD_W / 2, CHILD_H};
        DXGI_PRESENT_PARAMETERS params = {1, &dirty, NULL, NULL};
        CHECK(IDXGISwapChain1_Present1(swap, 0, 0, &params), "Present1");
    }
    printf("READY\n"); fflush(stdout);
    if (still) Sleep(12000); else pump(12000);
    return 0;
}
