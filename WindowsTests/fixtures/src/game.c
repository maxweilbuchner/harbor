/* Fixture: a minimal "game": imports D3D11, DXGI and XInput (controllers) like DirectX 11 games do. */
#define INITGUID
#include <windows.h>
#include <d3d11.h>
#ifndef NO_XINPUT
#include <xinput.h>
#endif
int WINAPI WinMain(HINSTANCE h, HINSTANCE p, LPSTR c, int n)
{
    ID3D11Device *dev = NULL;
    IDXGIFactory *f = NULL;
    D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &dev, NULL, NULL);
    CreateDXGIFactory(&IID_IDXGIFactory, (void **)&f);
#ifndef NO_XINPUT
    XINPUT_STATE pad;
    XInputGetState(0, &pad);
#endif
    return 0;
}
