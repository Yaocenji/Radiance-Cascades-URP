using Unity.VisualScripting;
using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

public class PipelineFeature : ScriptableRendererFeature
{
    private Material renderMaterial;
    
    GBufferRenderPass m_GBufferRenderPass;
    FinalBlitRenderPass m_FinalBlitPass;

    public Shader finalShader;

    /// <inheritdoc/>
    public override void Create()
    {
        renderMaterial = new Material(finalShader);

        m_GBufferRenderPass = new GBufferRenderPass();
        m_GBufferRenderPass.renderPassEvent = RenderPassEvent.AfterRenderingTransparents;
        m_FinalBlitPass = new FinalBlitRenderPass(renderMaterial);
        m_FinalBlitPass.renderPassEvent = RenderPassEvent.AfterRenderingTransparents;
    }

    // Here you can inject one or multiple render passes in the renderer.
    // This method is called when setting up the renderer once per-camera.
    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        var cameraType = renderingData.cameraData.cameraType;
        if (cameraType == CameraType.Preview || cameraType == CameraType.Reflection || cameraType == CameraType.SceneView)
        {
            return;
        }
        renderer.EnqueuePass(m_GBufferRenderPass);
        renderer.EnqueuePass(m_FinalBlitPass);
    }
    
    class FinalBlitRenderPass : ScriptableRenderPass
    {
        private int width;
        private int height;
        
        private Material renderMaterial;
        
        private RTHandle m_ResultHandle;
        private RTHandle m_HistoryHandle;

        // 缓存摄像机引用
        private Camera m_Camera;
        // 跨帧持久化
        private Matrix4x4 m_PrevViewProjMatrix;
        private bool m_FirstFrame = true; // 处理第一帧的标记

        public FinalBlitRenderPass(Material renderMaterial)
        {
            this.renderMaterial = renderMaterial;
        }
        
        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var cameraTargetDescriptor = renderingData.cameraData.cameraTargetDescriptor;
            
            m_Camera = renderingData.cameraData.camera;
            
            width = cameraTargetDescriptor.width;
            height = cameraTargetDescriptor.height;
            
            var normSpecDesc = new RenderTextureDescriptor(width, height, RenderTextureFormat.ARGB32, 0);
            normSpecDesc.msaaSamples = 1;
            normSpecDesc.sRGB = false;
            
            var resultDesc = new RenderTextureDescriptor(width, height, RenderTextureFormat.ARGBHalf, 0);
            resultDesc.msaaSamples = 1;
            resultDesc.sRGB = true;
             
            var historyDesc = new RenderTextureDescriptor(width, height, RenderTextureFormat.ARGBHalf, 0);
            historyDesc.msaaSamples = 1;
            historyDesc.sRGB = false;
            
            RenderingUtils.ReAllocateIfNeeded(ref m_ResultHandle, resultDesc, FilterMode.Bilinear, TextureWrapMode.Clamp, name: "_RenderResult");
            RenderingUtils.ReAllocateIfNeeded(ref m_HistoryHandle, historyDesc, FilterMode.Bilinear, TextureWrapMode.Clamp, name: "_RenderHistory");
            
            ConfigureInput(ScriptableRenderPassInput.Color);
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            CommandBuffer cmd = CommandBufferPool.Get("Pipeline After");

            RTHandle mainHandle = renderingData.cameraData.renderer.cameraColorTargetHandle;
            
            cmd.SetGlobalTexture("_AlbedoGBuffer", mainHandle);
            
            Blitter.BlitCameraTexture(cmd, mainHandle, m_ResultHandle, renderMaterial, 0);
            Blitter.BlitCameraTexture(cmd, m_ResultHandle, mainHandle);
            
            // 得到结果了，blit
            //Blitter.BlitCameraTexture(cmd, m_ResultHandle, m_HistoryHandle);
            cmd.CopyTexture(m_ResultHandle, m_HistoryHandle);
            cmd.SetGlobalTexture("_RC_HistoryTexture", m_HistoryHandle);
            
            // 将 m_HistoryHandle 的分辨率广播到下一帧
            cmd.SetGlobalVector("_RC_History_Param", new Vector4(width, height, 1.0f / width, 1.0f / height));
            
            
            // 计算当前帧的 VP 矩阵
            // 注意：必须使用 GL.GetGPUProjectionMatrix 处理不同平台的 Y 翻转问题
            Matrix4x4 view = m_Camera.worldToCameraMatrix;
            Matrix4x4 proj = GL.GetGPUProjectionMatrix(m_Camera.projectionMatrix, true);
            m_PrevViewProjMatrix = proj * view;
            
            // 将当前帧的矩阵给下一帧使用
            cmd.SetGlobalMatrix("_RC_PrevViewProjMatrix", m_PrevViewProjMatrix);
            
            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }
        public override void OnCameraCleanup(CommandBuffer cmd)
        {
        }

        public void Dispose()
        {
            m_ResultHandle?.Release();
            m_HistoryHandle?.Release();
        }
    }
    
    
    class GBufferRenderPass : ScriptableRenderPass
    {
        private int width;
        private int height;
        
        private RTHandle m_NormalSpecularGBufferHandle;

        public GBufferRenderPass()
        {
        }
        
        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            var cameraTargetDescriptor = renderingData.cameraData.cameraTargetDescriptor;
            
            width = cameraTargetDescriptor.width;
            height = cameraTargetDescriptor.height;
            
            var normSpecDesc = new RenderTextureDescriptor(width, height, RenderTextureFormat.ARGB32, 0);
            normSpecDesc.msaaSamples = 1;
            normSpecDesc.sRGB = false;
            
            RenderingUtils.ReAllocateIfNeeded(ref m_NormalSpecularGBufferHandle, normSpecDesc, FilterMode.Bilinear, TextureWrapMode.Clamp, name: "_NormSpecGBuffer");
            
            ConfigureInput(ScriptableRenderPassInput.Color);
            // 清除当前的源数据图
            ConfigureTarget(m_NormalSpecularGBufferHandle);
            // 清除颜色：背景设为黑色 (0,0,0,0)
            ConfigureClear(ClearFlag.Color, Color.clear);
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            CommandBuffer cmd = CommandBufferPool.Get("Pipeline Before");

            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
            
            // A. 定义我们要用哪些 Shader Pass 来画 (比如 UniversalForward, SRPDefaultUnlit)
            var shaderTagId = new ShaderTagId("GBuffer_NormSpec"); 
            var drawingSettings = CreateDrawingSettings(shaderTagId, ref renderingData, SortingCriteria.CommonOpaque);
            // B. 过滤：只画 Settings 里设置的层级 (Wall, Light)
            var filteringSettings = new FilteringSettings(RenderQueueRange.opaque);
            // C. 绘制！
            // 这一步会把符合 Layer 的物体画到 m_LightSrc_Occlusion 上
            context.DrawRenderers(renderingData.cullResults, ref drawingSettings, ref filteringSettings);
            
            cmd.SetGlobalTexture("_NormSpecGBuffer", m_NormalSpecularGBufferHandle);
            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }
        public override void OnCameraCleanup(CommandBuffer cmd)
        {
        }

        public void Dispose()
        {
            m_NormalSpecularGBufferHandle?.Release();
        }
    }
}


