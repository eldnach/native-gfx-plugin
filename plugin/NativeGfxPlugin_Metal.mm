#import <Metal/Metal.h>

#include "IUnityInterface.h"
#include "IUnityGraphics.h"
#include "IUnityGraphicsMetal.h"

#include <math.h>
#include <string.h>

static IUnityInterfaces*      s_Unity    = NULL;
static IUnityGraphics*        s_Graphics = NULL;
static IUnityGraphicsMetalV2* s_Metal    = NULL;  

static const int    kBufferID       = 3;                  // triple-buffered 
static const size_t kBufferSize = sizeof(float) * 4;

static id<MTLBuffer>        s_UnityBuffer = nil;          // destination (Unity-owned, Private)
static id<MTLBuffer>        s_Staging[kBufferID] = { nil };   // CPU-writable staging buffer
static dispatch_semaphore_t s_Sem = nil;                 
static unsigned int         s_Frame = 0;

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

static void CreateStagingBuffers(id<MTLDevice> device)
{
    for (int i = 0; i < kBufferID; ++i)
        s_Staging[i] = [device newBufferWithLength:kBufferSize
                                           options:MTLResourceStorageModeShared];
    s_Sem = dispatch_semaphore_create(kBufferID);
}

static void ReleaseStagingBuffers()
{
    for (int i = 0; i < kBufferID; ++i)
        s_Staging[i] = nil;    
    s_Sem = nil;
    s_Frame = 0;
}

// Cycle the buffer's contents (R -> G -> B -> R)
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
        if (s_Graphics->GetRenderer() == kUnityGfxRendererMetal)
        {
            s_Metal = s_Unity->Get<IUnityGraphicsMetalV2>();
            if (s_Metal)
                CreateStagingBuffers(s_Metal->MetalDevice());
        }
    }
    else if (eventType == kUnityGfxDeviceEventShutdown)
    {
        ReleaseStagingBuffers();
        s_Metal = NULL;
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

// Called once from C# to pass GraphicsBuffer.GetNativeBufferPtr().
extern "C" void UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
SetUnityBuffer(void* nativeBufferPtr)
{
    s_UnityBuffer = (__bridge id<MTLBuffer>)nativeBufferPtr;
}

// ----------------------------------------------------------------------------
// Render-thread callback: write color -> staging -> blit into Unity buffer
// ----------------------------------------------------------------------------

static void UNITY_INTERFACE_API OnRenderEvent(int eventId)
{
    if (!s_Metal || s_UnityBuffer == nil)
        return;

    id<MTLCommandBuffer> cmd = s_Metal->CurrentCommandBuffer();
    if (cmd == nil)
        return;

    // CPU<->GPU fence: wait until a staging buffer is available  (the GPU finished
    // the blit that last read it)
    dispatch_semaphore_wait(s_Sem, DISPATCH_TIME_FOREVER);
    int bufferID = s_Frame % kBufferID;

    // 1) CPU write this frame's color into staging buffer.
    float color[4];
    ComputeColor(s_Frame, color);
    memcpy([s_Staging[bufferID] contents], color, kBufferSize);

    // 2) GPU copy: staging buffer -> Unity-owned buffer on the active command buffer.
    //    End Unity's current encoder before opening our own blit encoder,
    //    and end ours before returning control to Unity.
    s_Metal->EndCurrentCommandEncoder();
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    
    [blit copyFromBuffer:s_Staging[bufferID] 
                sourceOffset:0
                toBuffer:s_UnityBuffer   
                destinationOffset:0
                size:kBufferSize];

    [blit endEncoding];
    // No explicit barrier: both buffers are hazard-tracked, Metal orders the
    // subsequent shader read of s_UnityBuffer after this blit automatically.

    // 3) Free the slot once the GPU has consumed it.
    dispatch_semaphore_t sem = s_Sem;
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull) {
        dispatch_semaphore_signal(sem);
    }];

    s_Frame++;
}

extern "C" UnityRenderingEvent UNITY_INTERFACE_EXPORT UNITY_INTERFACE_API
GetRenderEventFunc()
{
    return OnRenderEvent;
}
