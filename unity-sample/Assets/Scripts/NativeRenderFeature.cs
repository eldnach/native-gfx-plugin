using System;
using System.Runtime.InteropServices;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Rendering.RenderGraphModule;

public class NativeRenderFeature : ScriptableRendererFeature
{
    const string k_Dll = "NativeGfxPlugin";

    [DllImport(k_Dll)] static extern void SetUnityBuffer(IntPtr nativeBufferPtr);
    [DllImport(k_Dll)] static extern IntPtr GetRenderEventFunc();

    [Tooltip("Shader StructuredBuffer<float4> property the buffer is bound to.")]
    [SerializeField] string m_BufferProperty = "_ColorBuffer";

    NativeRenderSetupPass m_Pass;
    GraphicsBuffer m_Buffer;
    bool m_Initialized;

    public override void Create()
    {
        m_Pass = new NativeRenderSetupPass
        {
            renderPassEvent = RenderPassEvent.BeforeRenderingOpaques
        };
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        var cameraType = renderingData.cameraData.cameraType;
        if (cameraType == CameraType.Preview || cameraType == CameraType.Reflection)
            return;

        EnsureInitialized();
        if (!m_Initialized)
            return;

        m_Pass.Setup(GetRenderEventFunc());
        renderer.EnqueuePass(m_Pass);
    }

    void EnsureInitialized()
    {
        if (m_Initialized)
            return;

        m_Buffer = new GraphicsBuffer(GraphicsBuffer.Target.Structured, 1, sizeof(float) * 4);

        m_Buffer.SetData(new[] { Vector4.zero }); // Initialize to ensure the buffer is allocated

        // Pass the native buffer pointer to the plugin
        SetUnityBuffer(m_Buffer.GetNativeBufferPtr());

        // Bind buffer as shader property
        Shader.SetGlobalBuffer(m_BufferProperty, m_Buffer);

        m_Initialized = true;
    }

    protected override void Dispose(bool disposing)
    {
        m_Buffer?.Release();
        m_Buffer = null;
        m_Initialized = false;
    }

    // ------------------------------------------------------------------------

    class NativeRenderSetupPass : ScriptableRenderPass
    {
        class PassData
        {
            public IntPtr renderEventFunc;
        }

        IntPtr m_RenderEventFunc;

        public void Setup(IntPtr renderEventFunc) => m_RenderEventFunc = renderEventFunc;

        public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
        {
            if (m_RenderEventFunc == IntPtr.Zero)
                return;

            using (var builder = renderGraph.AddUnsafePass<PassData>("NativeRenderSetup", out var passData))
            {
                passData.renderEventFunc = m_RenderEventFunc;

                builder.AllowPassCulling(false);

                builder.SetRenderFunc(static (PassData data, UnsafeGraphContext context) =>
                {
                    // schedule the plugin execution on the render thread
                    context.cmd.IssuePluginEvent(data.renderEventFunc, 0);
                });
            }
        }
    }
}
