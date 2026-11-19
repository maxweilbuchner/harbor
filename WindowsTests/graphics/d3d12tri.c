/* D3D12 rendering proof: a triangle into an offscreen render target, read back through a copy queue path,
 * then 30 presented frames into a window through a flip-model swap chain.
 * Usage: d3d12tri.exe <output-prefix>   → <prefix>-offscreen.bmp, <prefix>-window.bmp. Exit 0 = both pass. */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS /* struct-returning methods (GetDesc, GetCPUDescriptorHandleForHeapStart) */
#define INITGUID
#include <d3d12.h>
#include <dxgi1_4.h>
#include "common.h"

static ID3D12Device *dev;
static ID3D12CommandQueue *queue;
static ID3D12CommandAllocator *alloc;
static ID3D12GraphicsCommandList *list;
static ID3D12Fence *fence;
static UINT64 fence_value;
static HANDLE fence_event;
static ID3D12RootSignature *rootsig;
static ID3D12PipelineState *pso;

static void wait_gpu(void)
{
    CHECK(ID3D12CommandQueue_Signal(queue, fence, ++fence_value), "Signal");
    if (ID3D12Fence_GetCompletedValue(fence) < fence_value) {
        CHECK(ID3D12Fence_SetEventOnCompletion(fence, fence_value, fence_event), "SetEventOnCompletion");
        if (WaitForSingleObject(fence_event, 10000) != WAIT_OBJECT_0) { printf("FAIL GPU fence timeout\n"); ExitProcess(2); }
    }
}

static void submit(void)
{
    CHECK(ID3D12GraphicsCommandList_Close(list), "Close");
    ID3D12CommandList *lists[] = {(ID3D12CommandList *)list};
    ID3D12CommandQueue_ExecuteCommandLists(queue, 1, lists);
    wait_gpu();
    CHECK(ID3D12CommandAllocator_Reset(alloc), "Allocator Reset");
    CHECK(ID3D12GraphicsCommandList_Reset(list, alloc, NULL), "List Reset");
}

static void barrier(ID3D12Resource *res, D3D12_RESOURCE_STATES before, D3D12_RESOURCE_STATES after)
{
    D3D12_RESOURCE_BARRIER b = {0};
    b.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    b.Transition.pResource = res;
    b.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    b.Transition.StateBefore = before;
    b.Transition.StateAfter = after;
    ID3D12GraphicsCommandList_ResourceBarrier(list, 1, &b);
}

static void make_pipeline(void)
{
    D3D12_ROOT_SIGNATURE_DESC rd = {0};
    ID3DBlob *sig, *err;
    CHECK(D3D12SerializeRootSignature(&rd, D3D_ROOT_SIGNATURE_VERSION_1, &sig, &err), "D3D12SerializeRootSignature");
    CHECK(ID3D12Device_CreateRootSignature(dev, 0, ID3D10Blob_GetBufferPointer(sig), ID3D10Blob_GetBufferSize(sig),
                                           &IID_ID3D12RootSignature, (void **)&rootsig), "CreateRootSignature");
    ID3DBlob *vsb = compile("vs", "vs_5_0"), *psb = compile("ps", "ps_5_0");
    D3D12_GRAPHICS_PIPELINE_STATE_DESC pd = {0};
    pd.pRootSignature = rootsig;
    pd.VS.pShaderBytecode = ID3D10Blob_GetBufferPointer(vsb); pd.VS.BytecodeLength = ID3D10Blob_GetBufferSize(vsb);
    pd.PS.pShaderBytecode = ID3D10Blob_GetBufferPointer(psb); pd.PS.BytecodeLength = ID3D10Blob_GetBufferSize(psb);
    pd.BlendState.RenderTarget[0].RenderTargetWriteMask = D3D12_COLOR_WRITE_ENABLE_ALL;
    pd.SampleMask = UINT_MAX;
    pd.RasterizerState.FillMode = D3D12_FILL_MODE_SOLID;
    pd.RasterizerState.CullMode = D3D12_CULL_MODE_NONE;
    pd.RasterizerState.DepthClipEnable = TRUE;
    pd.PrimitiveTopologyType = D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
    pd.NumRenderTargets = 1;
    pd.RTVFormats[0] = DXGI_FORMAT_R8G8B8A8_UNORM;
    pd.SampleDesc.Count = 1;
    CHECK(ID3D12Device_CreateGraphicsPipelineState(dev, &pd, &IID_ID3D12PipelineState, (void **)&pso), "CreateGraphicsPipelineState");
}

static void record_draw(D3D12_CPU_DESCRIPTOR_HANDLE rtv)
{
    D3D12_VIEWPORT vp = {0, 0, W, H, 0, 1};
    D3D12_RECT sc = {0, 0, W, H};
    ID3D12GraphicsCommandList_OMSetRenderTargets(list, 1, &rtv, FALSE, NULL);
    ID3D12GraphicsCommandList_ClearRenderTargetView(list, rtv, CLEAR, 0, NULL);
    ID3D12GraphicsCommandList_SetGraphicsRootSignature(list, rootsig);
    ID3D12GraphicsCommandList_SetPipelineState(list, pso);
    ID3D12GraphicsCommandList_RSSetViewports(list, 1, &vp);
    ID3D12GraphicsCommandList_RSSetScissorRects(list, 1, &sc);
    ID3D12GraphicsCommandList_IASetPrimitiveTopology(list, D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D12GraphicsCommandList_DrawInstanced(list, 3, 1, 0, 0);
}

static int read_back(ID3D12Resource *tex, D3D12_RESOURCE_STATES state, const char *path, const char *label)
{
    D3D12_RESOURCE_DESC td = ID3D12Resource_GetDesc(tex);
    D3D12_PLACED_SUBRESOURCE_FOOTPRINT fp;
    UINT64 total;
    ID3D12Device_GetCopyableFootprints(dev, &td, 0, 1, 0, &fp, NULL, NULL, &total);

    D3D12_HEAP_PROPERTIES hp = {D3D12_HEAP_TYPE_READBACK};
    D3D12_RESOURCE_DESC bd = {D3D12_RESOURCE_DIMENSION_BUFFER, 0, total, 1, 1, 1, DXGI_FORMAT_UNKNOWN, {1, 0},
                              D3D12_TEXTURE_LAYOUT_ROW_MAJOR, D3D12_RESOURCE_FLAG_NONE};
    ID3D12Resource *buf;
    CHECK(ID3D12Device_CreateCommittedResource(dev, &hp, D3D12_HEAP_FLAG_NONE, &bd, D3D12_RESOURCE_STATE_COPY_DEST, NULL,
                                               &IID_ID3D12Resource, (void **)&buf), "CreateCommittedResource(readback)");
    barrier(tex, state, D3D12_RESOURCE_STATE_COPY_SOURCE);
    D3D12_TEXTURE_COPY_LOCATION dst = {buf, D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT};
    dst.PlacedFootprint = fp;
    D3D12_TEXTURE_COPY_LOCATION src = {tex, D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX};
    ID3D12GraphicsCommandList_CopyTextureRegion(list, &dst, 0, 0, 0, &src, NULL);
    barrier(tex, D3D12_RESOURCE_STATE_COPY_SOURCE, state);
    submit();
    void *data;
    D3D12_RANGE range = {0, (SIZE_T)total};
    CHECK(ID3D12Resource_Map(buf, 0, &range, &data), "Map(readback)");
    int r = verify_and_save(data, fp.Footprint.RowPitch, path, label);
    ID3D12Resource_Unmap(buf, 0, NULL);
    ID3D12Resource_Release(buf);
    return r;
}

int main(int argc, char **argv)
{
    const char *prefix = argc > 1 ? argv[1] : "d3d12";
    char path[MAX_PATH];
    int failures = 0;

    CHECK(D3D12CreateDevice(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev), "D3D12CreateDevice");
    D3D12_COMMAND_QUEUE_DESC qd = {D3D12_COMMAND_LIST_TYPE_DIRECT};
    CHECK(ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&queue), "CreateCommandQueue");
    CHECK(ID3D12Device_CreateCommandAllocator(dev, D3D12_COMMAND_LIST_TYPE_DIRECT, &IID_ID3D12CommandAllocator, (void **)&alloc), "CreateCommandAllocator");
    CHECK(ID3D12Device_CreateCommandList(dev, 0, D3D12_COMMAND_LIST_TYPE_DIRECT, alloc, NULL, &IID_ID3D12GraphicsCommandList, (void **)&list), "CreateCommandList");
    CHECK(ID3D12Device_CreateFence(dev, 0, D3D12_FENCE_FLAG_NONE, &IID_ID3D12Fence, (void **)&fence), "CreateFence");
    fence_event = CreateEventA(NULL, FALSE, FALSE, NULL);
    make_pipeline();

    D3D12_DESCRIPTOR_HEAP_DESC hd = {D3D12_DESCRIPTOR_HEAP_TYPE_RTV, 3, D3D12_DESCRIPTOR_HEAP_FLAG_NONE, 0};
    ID3D12DescriptorHeap *heap;
    CHECK(ID3D12Device_CreateDescriptorHeap(dev, &hd, &IID_ID3D12DescriptorHeap, (void **)&heap), "CreateDescriptorHeap");
    UINT step = ID3D12Device_GetDescriptorHandleIncrementSize(dev, D3D12_DESCRIPTOR_HEAP_TYPE_RTV);
    D3D12_CPU_DESCRIPTOR_HANDLE base = ID3D12DescriptorHeap_GetCPUDescriptorHandleForHeapStart(heap);

    /* 1. Offscreen render target. */
    D3D12_HEAP_PROPERTIES hp = {D3D12_HEAP_TYPE_DEFAULT};
    D3D12_RESOURCE_DESC td = {D3D12_RESOURCE_DIMENSION_TEXTURE2D, 0, W, H, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, {1, 0},
                              D3D12_TEXTURE_LAYOUT_UNKNOWN, D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET};
    D3D12_CLEAR_VALUE cv = {DXGI_FORMAT_R8G8B8A8_UNORM, {{CLEAR[0], CLEAR[1], CLEAR[2], CLEAR[3]}}};
    ID3D12Resource *tex;
    CHECK(ID3D12Device_CreateCommittedResource(dev, &hp, D3D12_HEAP_FLAG_NONE, &td, D3D12_RESOURCE_STATE_RENDER_TARGET, &cv,
                                               &IID_ID3D12Resource, (void **)&tex), "CreateCommittedResource(rt)");
    ID3D12Device_CreateRenderTargetView(dev, tex, NULL, base);
    record_draw(base);
    submit();
    snprintf(path, sizeof(path), "%s-offscreen.bmp", prefix);
    failures += read_back(tex, D3D12_RESOURCE_STATE_RENDER_TARGET, path, "d3d12 offscreen");

    /* 2. Window + flip-model swap chain: exercises the Mac display driver path. */
    HWND hwnd = make_window("Harbor D3D12 test");
    IDXGIFactory4 *factory;
    CHECK(CreateDXGIFactory1(&IID_IDXGIFactory4, (void **)&factory), "CreateDXGIFactory1");
    DXGI_SWAP_CHAIN_DESC1 sd = {0};
    sd.Width = W; sd.Height = H; sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.BufferCount = 2; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    IDXGISwapChain1 *swap1; IDXGISwapChain3 *swap;
    CHECK(IDXGIFactory4_CreateSwapChainForHwnd(factory, (IUnknown *)queue, hwnd, &sd, NULL, NULL, &swap1), "CreateSwapChainForHwnd");
    CHECK(IDXGISwapChain1_QueryInterface(swap1, &IID_IDXGISwapChain3, (void **)&swap), "QueryInterface(IDXGISwapChain3)");
    ID3D12Resource *back[2];
    for (UINT i = 0; i < 2; i++) {
        D3D12_CPU_DESCRIPTOR_HANDLE h = {base.ptr + (i + 1) * step};
        CHECK(IDXGISwapChain3_GetBuffer(swap, i, &IID_ID3D12Resource, (void **)&back[i]), "GetBuffer");
        ID3D12Device_CreateRenderTargetView(dev, back[i], NULL, h);
    }
    for (int frame = 0; frame < 30; frame++) {
        UINT i = IDXGISwapChain3_GetCurrentBackBufferIndex(swap);
        D3D12_CPU_DESCRIPTOR_HANDLE h = {base.ptr + (i + 1) * step};
        barrier(back[i], D3D12_RESOURCE_STATE_PRESENT, D3D12_RESOURCE_STATE_RENDER_TARGET);
        record_draw(h);
        barrier(back[i], D3D12_RESOURCE_STATE_RENDER_TARGET, D3D12_RESOURCE_STATE_PRESENT);
        submit();
        if (frame == 29) {
            snprintf(path, sizeof(path), "%s-window.bmp", prefix);
            failures += read_back(back[i], D3D12_RESOURCE_STATE_PRESENT, path, "d3d12 window");
        }
        CHECK(IDXGISwapChain3_Present(swap, 1, 0), "Present");
        pump(16);
    }
    wait_gpu();
    printf("INFO presented 30 frames\n");
    pump(500);
    return failures ? 1 : 0;
}
