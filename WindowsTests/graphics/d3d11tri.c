/* D3D11 rendering proof: a triangle offscreen, then into a window through a swap chain (Present).
 * Usage: d3d11tri.exe <output-prefix>   → <prefix>-offscreen.bmp, <prefix>-window.bmp. Exit 0 = both pass. */
#define COBJMACROS
#define INITGUID
#include <d3d11.h>
#include "common.h"

static void draw(ID3D11Device *dev, ID3D11DeviceContext *ctx, ID3D11Texture2D *target)
{
    ID3DBlob *vsb = compile("vs", "vs_5_0"), *psb = compile("ps", "ps_5_0");
    ID3D11VertexShader *vs; ID3D11PixelShader *ps; ID3D11RenderTargetView *rtv;
    CHECK(ID3D11Device_CreateVertexShader(dev, ID3D10Blob_GetBufferPointer(vsb), ID3D10Blob_GetBufferSize(vsb), NULL, &vs), "CreateVertexShader");
    CHECK(ID3D11Device_CreatePixelShader(dev, ID3D10Blob_GetBufferPointer(psb), ID3D10Blob_GetBufferSize(psb), NULL, &ps), "CreatePixelShader");
    CHECK(ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)target, NULL, &rtv), "CreateRenderTargetView");
    D3D11_VIEWPORT vp = {0, 0, W, H, 0, 1};
    ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
    ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
    ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, CLEAR);
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
    ID3D11DeviceContext_Draw(ctx, 3, 0);
}

static int read_back(ID3D11Device *dev, ID3D11DeviceContext *ctx, ID3D11Texture2D *src, const char *path, const char *label)
{
    D3D11_TEXTURE2D_DESC d;
    ID3D11Texture2D_GetDesc(src, &d);
    d.Usage = D3D11_USAGE_STAGING; d.BindFlags = 0; d.CPUAccessFlags = D3D11_CPU_ACCESS_READ; d.MiscFlags = 0;
    ID3D11Texture2D *staging;
    CHECK(ID3D11Device_CreateTexture2D(dev, &d, NULL, &staging), "CreateTexture2D(staging)");
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)src);
    D3D11_MAPPED_SUBRESOURCE m;
    CHECK(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &m), "Map");
    int r = verify_and_save(m.pData, m.RowPitch, path, label);
    ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
    return r;
}

int main(int argc, char **argv)
{
    const char *prefix = argc > 1 ? argv[1] : "d3d11";
    char path[MAX_PATH];
    int failures = 0;

    /* 1. Offscreen. */
    ID3D11Device *dev; ID3D11DeviceContext *ctx; D3D_FEATURE_LEVEL fl;
    CHECK(D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &dev, &fl, &ctx), "D3D11CreateDevice");
    printf("INFO feature level 0x%x\n", fl);
    D3D11_TEXTURE2D_DESC td = {W, H, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0}, D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET, 0, 0};
    ID3D11Texture2D *tex;
    CHECK(ID3D11Device_CreateTexture2D(dev, &td, NULL, &tex), "CreateTexture2D");
    draw(dev, ctx, tex);
    snprintf(path, sizeof(path), "%s-offscreen.bmp", prefix);
    failures += read_back(dev, ctx, tex, path, "d3d11 offscreen");

    /* 2. Window + swap chain: exercises the Mac display driver path. */
    HWND hwnd = make_window("Harbor D3D11 test");
    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferDesc.Width = W; sd.BufferDesc.Height = H; sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.SampleDesc.Count = 1; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.BufferCount = 2;
    sd.OutputWindow = hwnd; sd.Windowed = TRUE; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    IDXGISwapChain *swap; ID3D11Device *dev2; ID3D11DeviceContext *ctx2;
    CHECK(D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &sd, &swap, &dev2, NULL, &ctx2), "D3D11CreateDeviceAndSwapChain");
    ID3D11Texture2D *back;
    CHECK(IDXGISwapChain_GetBuffer(swap, 0, &IID_ID3D11Texture2D, (void **)&back), "GetBuffer");
    for (int frame = 0; frame < 30; frame++) {
        draw(dev2, ctx2, back);
        if (frame == 29) {
            snprintf(path, sizeof(path), "%s-window.bmp", prefix);
            failures += read_back(dev2, ctx2, back, path, "d3d11 window");
        }
        CHECK(IDXGISwapChain_Present(swap, 1, 0), "Present");
        pump(16);
    }
    printf("INFO presented 30 frames\n");
    pump(500);
    return failures ? 1 : 0;
}
