// Regression test for Direct2D gaps that left Microsoft 365 Excel's window blank or black (#93; scripts/patches/
// wine/0025 to 0028). C++ because the Direct2D headers are; linked statically so the bottle needs no runtime DLL.
// The check that crashes without its patch comes last, so the others still report. Exit 0 = all pass.
#include <initguid.h>
#include <windows.h>
#include <wincodec.h>
#include <d2d1_1.h>
#include <d2d1effects.h>
#include <d2d1effectauthor.h>
#include <stdio.h>

static int failed;

static void check(bool ok, const char *what, const char *detail)
{
    if (ok) printf("PASS: %s\n", what);
    else { printf("FAIL: %s: %s\n", what, detail); failed = 1; }
    fflush(stdout);
}

// An effect of the program's own whose graph is one node that is not a draw transform, as Office registers them.
// {3f6a1b52-9c1e-4d0b-8a57-484152424f52}
DEFINE_GUID(CLSID_OffsetOnly, 0x3f6a1b52, 0x9c1e, 0x4d0b, 0x8a, 0x57, 0x48, 0x41, 0x52, 0x42, 0x4f, 0x52);

struct OffsetOnly final : ID2D1EffectImpl
{
    LONG refs = 1;
    STDMETHODIMP QueryInterface(REFIID iid, void **out) override
    {
        if (iid == IID_IUnknown || iid == IID_ID2D1EffectImpl) { *out = this; AddRef(); return S_OK; }
        *out = nullptr; return E_NOINTERFACE;
    }
    STDMETHODIMP_(ULONG) AddRef() override { return InterlockedIncrement(&refs); }
    STDMETHODIMP_(ULONG) Release() override { LONG r = InterlockedDecrement(&refs); if (!r) delete this; return r; }
    STDMETHODIMP Initialize(ID2D1EffectContext *context, ID2D1TransformGraph *graph) noexcept override
    {
        ID2D1OffsetTransform *offset;
        HRESULT hr = context->CreateOffsetTransform(D2D1::Point2L(0, 0), &offset);
        if (FAILED(hr)) return hr;
        hr = graph->SetSingleTransformNode(offset);
        offset->Release();
        return hr;
    }
    STDMETHODIMP PrepareForRender(D2D1_CHANGE_TYPE) noexcept override { return S_OK; }
    STDMETHODIMP SetGraph(ID2D1TransformGraph *) noexcept override { return E_NOTIMPL; }
    static HRESULT __stdcall create(IUnknown **out) { *out = new OffsetOnly; return S_OK; }
};

int main()
{
    char detail[128];
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    IWICImagingFactory *wic = nullptr;
    IWICBitmap *surface = nullptr;
    ID2D1Factory1 *factory = nullptr;
    ID2D1RenderTarget *rt = nullptr;
    ID2D1DeviceContext *dc = nullptr;
    ID2D1Bitmap *source = nullptr, *shared = nullptr;

    const char *step = "COM";
    if (SUCCEEDED(hr)) { step = "WIC factory"; hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic)); }
    if (SUCCEEDED(hr)) { step = "WIC bitmap"; hr = wic->CreateBitmap(16, 16, GUID_WICPixelFormat32bppPBGRA, WICBitmapCacheOnLoad, &surface); }
    if (SUCCEEDED(hr)) { step = "Direct2D factory"; hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, __uuidof(ID2D1Factory1), nullptr, (void **)&factory); }
    if (SUCCEEDED(hr)) { step = "render target"; hr = factory->CreateWicBitmapRenderTarget(surface, D2D1::RenderTargetProperties(D2D1_RENDER_TARGET_TYPE_DEFAULT,
            D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED)), &rt); }
    if (SUCCEEDED(hr)) { step = "device context"; hr = rt->QueryInterface(__uuidof(ID2D1DeviceContext), (void **)&dc); }
    if (FAILED(hr)) { printf("FAIL: nothing to test with: %s failed (0x%08lx)\n", step, hr); return 1; }

    // 0025: a bitmap shared from another bitmap draws that bitmap's pixels.
    static DWORD red[8 * 8];
    for (DWORD &pixel : red) pixel = 0xffff0000;
    hr = rt->CreateBitmap(D2D1::SizeU(8, 8), red, 8 * 4,
            D2D1::BitmapProperties(D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED)), &source);
    // With properties given, as Excel does: without them the source's options were used and it worked.
    D2D1_BITMAP_PROPERTIES like_source = D2D1::BitmapProperties();
    if (SUCCEEDED(hr)) hr = rt->CreateSharedBitmap(__uuidof(ID2D1Bitmap), source, &like_source, &shared);
    DWORD pixel = 0;
    if (SUCCEEDED(hr))
    {
        rt->BeginDraw();
        rt->Clear(D2D1::ColorF(D2D1::ColorF::White));
        rt->DrawBitmap(shared, D2D1::RectF(0, 0, 16, 16), 1.0f, D2D1_BITMAP_INTERPOLATION_MODE_NEAREST_NEIGHBOR);
        hr = rt->EndDraw();
        IWICBitmapLock *lock;
        WICRect whole = { 0, 0, 16, 16 };
        if (SUCCEEDED(surface->Lock(&whole, WICBitmapLockRead, &lock)))
        {
            UINT size, stride; BYTE *data;
            lock->GetStride(&stride); lock->GetDataPointer(&size, &data);
            pixel = *(DWORD *)(data + 8 * stride + 8 * 4);
            lock->Release();
        }
    }
    sprintf(detail, "hr 0x%08lx, pixel %08lx, expected ffff0000", hr, pixel);
    check(SUCCEEDED(hr) && pixel == 0xffff0000, "a bitmap shared from a bitmap draws its pixels", detail);

    // 0026: the three built-in effects Excel creates that were missing.
    static const struct { const CLSID *id; const char *name; } effects[] =
    {
        { &CLSID_D2D13DTransform, "3D transform" }, { &CLSID_D2D1Atlas, "atlas" }, { &CLSID_D2D1Tile, "tile" },
    };
    bool all = true; detail[0] = 0;
    for (const auto &e : effects)
    {
        ID2D1Effect *effect = nullptr;
        hr = dc->CreateEffect(*e.id, &effect);
        if (FAILED(hr)) { all = false; sprintf(detail + strlen(detail), "%s 0x%08lx ", e.name, hr); }
        if (effect) effect->Release();
    }
    check(all, "the 3D transform, atlas and tile effects exist", detail);

    // 0027: an effect whose graph holds a node that is not a draw transform can be created.
    static const WCHAR description[] =
        L"<?xml version='1.0'?><Effect><Property name='DisplayName' type='string' value='OffsetOnly'/>"
        L"<Property name='Author' type='string' value='Harbor'/><Property name='Category' type='string' value='Test'/>"
        L"<Property name='Description' type='string' value='One offset node'/><Inputs><Input name='Source'/></Inputs></Effect>";
    ID2D1Effect *own = nullptr;
    hr = factory->RegisterEffectFromString(CLSID_OffsetOnly, description, nullptr, 0, OffsetOnly::create);
    if (SUCCEEDED(hr)) hr = dc->CreateEffect(CLSID_OffsetOnly, &own);
    sprintf(detail, "hr 0x%08lx", hr);
    check(SUCCEEDED(hr), "an effect with a node that is not a draw transform can be created", detail);
    if (own) own->Release();

    // 0028: taking an effect's input away again. Crashed (AddRef on NULL), so this is the last check.
    ID2D1Effect *tile = nullptr;
    hr = dc->CreateEffect(CLSID_D2D1Tile, &tile);
    if (FAILED(hr)) hr = dc->CreateEffect(CLSID_D2D1Crop, &tile);   // exists without 0026
    ID2D1Image *input = (ID2D1Image *)1;
    if (SUCCEEDED(hr))
    {
        tile->SetInput(0, source);
        tile->SetInput(0, nullptr);
        tile->GetInput(0, &input);
    }
    sprintf(detail, "hr 0x%08lx, input %p", hr, (void *)input);
    check(SUCCEEDED(hr) && !input, "an effect's input can be cleared", detail);
    return failed;
}
