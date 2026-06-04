#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d12.h>

#include <cmath>
#include <cstring>

#include "IUnityInterface.h"
#include "IUnityGraphics.h"
#include "IUnityGraphicsD3D12.h"

#include <wrl/client.h>
using Microsoft::WRL::ComPtr;

// ----------------------------------------------------------------------------
// State
// ----------------------------------------------------------------------------

static IUnityInterfaces*      s_Unity    = nullptr;
static IUnityGraphics*        s_Graphics = nullptr;
static IUnityGraphicsD3D12v8* s_D3D12    = nullptr;  
static ID3D12Device*          s_Device   = nullptr;

static const int    kBufferCount = 3;                 // triple-buffered
static const UINT64 kBufferSize  = sizeof(float) * 4; 

static ID3D12Resource* s_UnityBuffer = nullptr;       // Unity-owned default-heap buffer 

struct StagingBuffer
{
    ComPtr<ID3D12Resource>            upload;          // CPU-writable UPLOAD-heap staging buffer
    void*                             mapped = nullptr;
    ComPtr<ID3D12CommandAllocator>    alloc;
    ComPtr<ID3D12GraphicsCommandList> list;
    UINT64                            fenceValue = 0;  // frame-fence value to wait on before reuse
};
static StagingBuffer s_StagingBuffers[kBufferCount];
static unsigned int  s_Frame = 0;

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

static void CreateResources()
{
    D3D12_HEAP_PROPERTIES uploadHeap = {};
    uploadHeap.Type = D3D12_HEAP_TYPE_UPLOAD;

    D3D12_RESOURCE_DESC desc = {};
    desc.Dimension        = D3D12_RESOURCE_DIMENSION_BUFFER;
    desc.Width            = kBufferSize;
    desc.Height           = 1;
    desc.DepthOrArraySize = 1;
    desc.MipLevels        = 1;
    desc.SampleDesc.Count = 1;
    desc.Layout           = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;

    for (int i = 0; i < kBufferCount; ++i)
    {
        StagingBuffer& sb = s_StagingBuffers[i];

        s_Device->CreateCommittedResource(
            &uploadHeap, D3D12_HEAP_FLAG_NONE, &desc,
            D3D12_RESOURCE_STATE_GENERIC_READ, nullptr, IID_PPV_ARGS(&sb.upload));

        D3D12_RANGE noRead = { 0, 0 };            // we only write
        sb.upload->Map(0, &noRead, &sb.mapped);   // persistently mapped

        s_Device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&sb.alloc));
        s_Device->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, sb.alloc.Get(), nullptr, IID_PPV_ARGS(&sb.list));
        sb.list->Close();
        sb.fenceValue = 0;
    }
    s_Frame = 0;
}

static void ReleaseResources()
{
    for (int i = 0; i < kBufferCount; ++i)
    {
        StagingBuffer& sb = s_StagingBuffers[i];
        if (sb.upload && sb.mapped) { sb.upload->Unmap(0, nullptr); sb.mapped = nullptr; }
        sb.list.Reset();
        sb.alloc.Reset();
        sb.upload.Reset();
        sb.fenceValue = 0;
    }
}

// Smoothly cycle the float4 color R -> G -> B -> R.
static void ComputeColor(unsigned int frame, float outColor[4])
{
    const float period = 180.0f;                              
    float t   = fmodf((float)frame, period) / period * 3.0f;  // 0..3
    int   seg = (int)t;                                       // segment 0,1,2
    float f   = t - (float)seg;                               // 0..1 within segment

    float r = 0.0f, g = 0.0f, b = 0.0f;
    if (seg == 0)      { r = 1.0f - f; g = f; }   // R -> G
    else if (seg == 1) { g = 1.0f - f; b = f; }   // G -> B
    else               { b = 1.0f - f; r = f; }   // B -> R

    outColor[0] = r; outColor[1] = g; outColor[2] = b; outColor[3] = 1.0f;
}

// ----------------------------------------------------------------------------
// Device lifecycle
// ----------------------------------------------------------------------------

static void UNITY_INTERFACE_API OnGfxDeviceEvent(UnityGfxDeviceEventType eventType)
{
    if (eventType == kUnityGfxDeviceEventInitialize)
    {
        if (s_Graphics->GetRenderer() == kUnityGfxRendererD3D12)
        {
            s_D3D12 = s_Unity->Get<IUnityGraphicsD3D12v8>();
            if (s_D3D12)
            {
                s_Device = s_D3D12->GetDevice();
                CreateResources();
            }
        }
    }
    else if (eventType == kUnityGfxDeviceEventShutdown)
    {
        ReleaseResources();
        s_D3D12  = nullptr;
        s_Device = nullptr;
    }
}

// ----------------------------------------------------------------------------
// Exported entry points
// ----------------------------------------------------------------------------

extern "C" void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityPluginLoad(IUnityInterfaces* unityInterfaces)
{
    s_Unity    = unityInterfaces;
    s_Graphics = s_Unity->Get<IUnityGraphics>();
    s_Graphics->RegisterDeviceEventCallback(OnGfxDeviceEvent);
    // The device may already exist when the plugin loads, so run init once now.
    OnGfxDeviceEvent(kUnityGfxDeviceEventInitialize);
}

extern "C" void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
UnityPluginUnload()
{
    if (s_Graphics)
        s_Graphics->UnregisterDeviceEventCallback(OnGfxDeviceEvent);
}

// Called from C# with GraphicsBuffer.GetNativeBufferPtr()
extern "C" void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
SetUnityBuffer(void* nativeBufferPtr)
{
    s_UnityBuffer = static_cast<ID3D12Resource*>(nativeBufferPtr);
}

// ----------------------------------------------------------------------------
// Render-thread callback: write color -> upload slot -> copy into Unity buffer
// ----------------------------------------------------------------------------

static void UNITY_INTERFACE_API OnRenderEvent(int eventId)
{
    if (!s_D3D12 || !s_Device || s_UnityBuffer == nullptr)
        return;

    int   slot = s_Frame % kBufferCount;
    StagingBuffer& sb    = s_StagingBuffers[slot];

    // CPU<->GPU fence: wait until the GPU finished the last copy from this staging buffer
    ID3D12Fence* fence = s_D3D12->GetFrameFence();
    if (fence && fence->GetCompletedValue() < sb.fenceValue)
    {
        HANDLE e = CreateEvent(nullptr, FALSE, FALSE, nullptr);
        fence->SetEventOnCompletion(sb.fenceValue, e);
        WaitForSingleObject(e, INFINITE);
        CloseHandle(e);
    }

    // 1) CPU write this frame's color into the staging buffer.
    float color[4];
    ComputeColor(s_Frame, color);
    memcpy(sb.mapped, color, kBufferSize);

    // 2) Record the GPU copy: staging buffer -> Unity-owned buffer.
    sb.alloc->Reset();
    sb.list->Reset(sb.alloc.Get(), nullptr);
    sb.list->CopyBufferRegion(s_UnityBuffer, 0, sb.upload.Get(), 0, kBufferSize);
    sb.list->Close();

    // 3) Submit to graphics queue and set barriers.
    UnityGraphicsD3D12ResourceState state = {};
    state.resource = s_UnityBuffer;
    state.expected = D3D12_RESOURCE_STATE_COPY_DEST;
    state.current  = D3D12_RESOURCE_STATE_COPY_DEST;

    sb.fenceValue = s_D3D12->ExecuteCommandList(sb.list.Get(), 1, &state);

    s_Frame++;
}

extern "C" UnityRenderingEvent UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
GetRenderEventFunc()
{
    return OnRenderEvent;
}
