using UnityEngine;
using UnityEngine.Experimental.Rendering;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;


public class RadianceCascadesFeature : ScriptableRendererFeature
{
    private const int MAX_CASCADE_COUNT = 10;
    
    [System.Serializable]
    public class Settings
    {
        [Range(0.1f, 4.0f)] public float renderScale = 1.0f; // 动态画质调整
        [Range(0.1f, 1.0f)] public float rayRange = 1.0f; // 射线长度
        [Range(1, MAX_CASCADE_COUNT)] public int cascadeCount = 1; // 级联数
        public LayerMask targetLayerMask; // 在Inspector里勾选 Wall 和 Light 层
        [Header("Interior Lighting")]
        [Tooltip("开启=使用真实体光照（SDF非正部分步进计算，应用occ系数）。关闭=使用偷光法（从边缘向外偷光，不应用occ系数）。")]
        public bool useVolumetricLighting = true;
        
        [Range(0.0f, 5.0f)]
        [Tooltip("偷光强度 (仅在useVolumetricLighting=false时生效, 0=不使用偷光, 值越大偷光效果越强)")]
        public float trickLightIntensity = 1.0f;
        
        [Range(1.0f, 100.0f)]
        [Tooltip("偷光距离 (仅在useVolumetricLighting=false时生效, 从边缘向外偷光的最大距离)")]
        public float trickLightDistance = 35.0f;
        
        [Header("Shaders")]
        public Shader screenUVShader;
        public Shader jfaShader;
        public Shader sdfShader;
        public Shader rcShader;
    }

    public Settings settings = new Settings();
    
    // 屏幕UV材质，JFA前置
    private Material screenUVMat;
    // JFA算法
    private Material jfaMat;
    // SDF算法
    private Material sdfMat;
    // 核心：radiance cascades
    private Material rcMat;
    
    RC_RenderPass m_ScriptablePass;

    public override void Create()
    {
        if (settings.rcShader == null) return; // 还没拖进去，先不创建
        
        screenUVMat = new Material(settings.screenUVShader);
        jfaMat = new Material(settings.jfaShader);
        sdfMat = new Material(settings.sdfShader);
        rcMat = new Material(settings.rcShader);
        
        // 这里只负责创建 Pass 实例，不分配显存
        m_ScriptablePass = new RC_RenderPass(settings, screenUVMat, jfaMat, sdfMat, rcMat);
        m_ScriptablePass.renderPassEvent = RenderPassEvent.AfterRenderingTransparents;
    }

    public override void AddRenderPasses(ScriptableRenderer renderer, ref RenderingData renderingData)
    {
        var cameraType = renderingData.cameraData.cameraType;
        if (cameraType == CameraType.Preview || cameraType == CameraType.Reflection || cameraType == CameraType.SceneView)
        {
            return;
        }
        renderer.EnqueuePass(m_ScriptablePass);
    }

    protected override void Dispose(bool disposing)
    {
        m_ScriptablePass.Dispose();
    }

    // =========================================================
    // 核心 Pass 类
    // =========================================================
    class RC_RenderPass : ScriptableRenderPass
    {
        Settings m_DefaultSettings;
        // 缓存当前的参数 (可能是默认的，也可能是 Volume 覆盖的)
        private float currentRenderScale;
        private int currentCascadeCount;
        private float currentRayRange;
        private float currentBounceIntensity;
        private Color currentSkyColor;
        private float currentSkyIntensity;
        private Color currentSunColor;
        private float currentSunAngle;
        private float currentSunIntensity;
        private float currentSunHardness;
        
        // Interior Lighting 参数
        private bool currentUseVolumetricLighting;
        private float currentTrickLightIntensity;
        private float currentTrickLightDistance;
        
        // 缓存摄像机引用
        private Camera m_Camera;
        
        // 每层射线的长度
        private Vector4[] m_CascadeRanges;
        
        // 屏幕UV材质
        private Material screenUVMat;
        // JFA算法
        private Material jfaMat;
        // SDF算法
        private Material sdfMat;
        // 核心：radiance cascades
        private Material rcMat;
        
        // 使用 RTHandle 而不是 RenderTexture
        private RTHandle m_LightSrc_Occlusion;
        private RTHandle m_JFA_Handle_0;
        private RTHandle m_JFA_Handle_1;
        private RTHandle m_SDF_Handle;
        private RTHandle m_RadianceHandle_0;
        private RTHandle m_RadianceHandle_1; // 用于 Cascade Merge Ping-Pong
        
        private bool jumpFlood1IsFinal = false;
        private bool gi1IsFinal = false;

        private int width;
        private int height;
        private int rcWidth;
        private int rcHeight;

        public RC_RenderPass(Settings defaultSettings, Material screenUVMat, Material jfaMat, Material sdfMat, Material rcMat)
        {
            m_DefaultSettings = defaultSettings;
            
            this.screenUVMat = screenUVMat;
            this.jfaMat = jfaMat;
            this.sdfMat = sdfMat;
            this.rcMat = rcMat;
            
            m_CascadeRanges = new Vector4[MAX_CASCADE_COUNT];
        }

        // 1. 在这里进行动态管理 (Resize, Format change)
        public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
        {
            // 1. 获取 Volume Stack
            var stack = VolumeManager.instance.stack;
            var volume = stack.GetComponent<RadianceCascadesVolume>();

            // 2. 决定使用哪套参数
            // 如果 Volume 有效，就用 Volume 的；否则用 Feature Settings 的默认值
            bool useVolume = volume != null && volume.IsActive();

            currentRenderScale = useVolume ? volume.renderScale.value : m_DefaultSettings.renderScale;
            currentCascadeCount = useVolume ? volume.cascadeCount.value : m_DefaultSettings.cascadeCount;
            currentRayRange = useVolume ? volume.rayRange.value : m_DefaultSettings.rayRange;
            currentBounceIntensity = useVolume ? volume.bounceIntensity.value : 0.9f; // 默认反弹值
            currentSkyColor = useVolume ? volume.skyColor.value : Color.white;
            currentSkyIntensity = useVolume ? volume.skyIntensity.value : 0;
            currentSunColor = useVolume ? volume.sunColor.value : Color.white;
            currentSunAngle = useVolume ? volume.sunAngle.value : volume.sunAngle.min;
            currentSunIntensity = useVolume ? volume.sunIntensity.value : volume.sunIntensity.min;
            currentSunHardness = useVolume ? volume.sunHardness.value : volume.sunHardness.min;
            
            // Interior Lighting 参数
            currentUseVolumetricLighting = useVolume ? volume.useVolumetricLighting.value : m_DefaultSettings.useVolumetricLighting;
            currentTrickLightIntensity = useVolume ? volume.trickLightIntensity.value : m_DefaultSettings.trickLightIntensity;
            currentTrickLightDistance = useVolume ? volume.trickLightDistance.value : m_DefaultSettings.trickLightDistance;
            
            var cameraTargetDescriptor = renderingData.cameraData.cameraTargetDescriptor;
            
            m_Camera = renderingData.cameraData.camera;
            
            // 计算目标分辨率（支持动态画质调整）
            width = (int)(cameraTargetDescriptor.width * currentRenderScale);
            height = (int)(cameraTargetDescriptor.height * currentRenderScale);
            
            // 计算rc分辨率
            int blockSize = (int)Mathf.Pow(2, currentCascadeCount);
            rcWidth = Mathf.CeilToInt((float)width / blockSize) * blockSize;
            rcHeight = Mathf.CeilToInt((float)height / blockSize) * blockSize;
            
            // 对角线长度 * 系数 = 射线总长度
            float radianceMaxLength =
                Mathf.Sqrt(width * width + height * height) * currentRayRange;
            // 动态计算每层的射线长度。
            // 公式: d0 = L * 3 / (4^N - 1)
            float denominator = Mathf.Pow(4, currentCascadeCount) - 1.0f;
            // 防止除以0 (虽然后面max限制了N>=1，4^1-1=3，不会为0)
            float baseLength = (radianceMaxLength * 3.0f) / denominator;
            // 循环填充每一层
            float currentStart = 0.0f;
            for (int i = 0; i < currentCascadeCount; i++)
            {
                // 当前层的长度 = 基准 * 4^i
                float currentLength = baseLength * Mathf.Pow(4, i);
                float currentEnd = currentStart + currentLength;

                // 填充数据
                m_CascadeRanges[i] = new Vector4(
                    currentStart,   // x: 起点
                    currentEnd,     // y: 终点 (也是下一层的起点)
                    currentLength,  // z: 长度
                    currentLength   // w: 备用，或者存 1/Length 用于归一化
                );

                // 更新下一层的起点
                currentStart = currentEnd;

                // Debug.Log($"Layer {i}: Range [{m_CascadeRanges[i].x:F1}, {m_CascadeRanges[i].y:F1}] Len: {m_CascadeRanges[i].z:F1}");
            }
            
            // --- 配置 LightSrc + Occlusion 描述符 ---
            var lsoDesc = new RenderTextureDescriptor(width, height, RenderTextureFormat.ARGBHalf, 0);
            lsoDesc.msaaSamples = 1;
            lsoDesc.sRGB = false;

            // --- 配置 SDF Buffer 描述符 ---
            // JFA 也就是距离场，通常 RGHalf (16位浮点) 足够，精度高用 RGFloat
            var jfaDesc = new RenderTextureDescriptor(width, height, RenderTextureFormat.RGHalf, 0);
            jfaDesc.msaaSamples = 1;
            jfaDesc.sRGB = false;
            var sdfDesc = new RenderTextureDescriptor(width, height, RenderTextureFormat.RHalf, 0);
            sdfDesc.msaaSamples = 1;
            sdfDesc.sRGB = false;

            // --- 配置 Radiance Buffer 描述符 ---
            // 存储光照结果，需要 Alpha 通道存透光率/SDF混合，所以用 ARGBHalf
            var radianceDesc = new RenderTextureDescriptor(rcWidth, rcHeight, RenderTextureFormat.ARGBHalf, 0);
            radianceDesc.msaaSamples = 1;
            radianceDesc.sRGB = false;
            radianceDesc.useMipMap = true;
            radianceDesc.autoGenerateMips = false;

            // ReAllocateIfNeeded 会自动判断：如果 width/height/format 变了，它会释放旧的，分配新的。
            RenderingUtils.ReAllocateIfNeeded(ref m_LightSrc_Occlusion, lsoDesc, FilterMode.Bilinear, TextureWrapMode.Clamp, name: "_LightSrc_Occlusion");
            
            RenderingUtils.ReAllocateIfNeeded(ref m_JFA_Handle_0, jfaDesc, FilterMode.Point, TextureWrapMode.Clamp, name: "_JFA_0");
            RenderingUtils.ReAllocateIfNeeded(ref m_JFA_Handle_1, jfaDesc, FilterMode.Point, TextureWrapMode.Clamp, name: "_JFA_1");
            RenderingUtils.ReAllocateIfNeeded(ref m_SDF_Handle, sdfDesc, FilterMode.Bilinear, TextureWrapMode.Clamp, name: "_SDF");
            
            // Radiance 需要双线性插值 (Bilinear)，这是 RC Merge 的关键！
            RenderingUtils.ReAllocateIfNeeded(ref m_RadianceHandle_0, radianceDesc, FilterMode.Bilinear, TextureWrapMode.Clamp, name: "_RC_0");
            RenderingUtils.ReAllocateIfNeeded(ref m_RadianceHandle_1, radianceDesc, FilterMode.Bilinear, TextureWrapMode.Clamp, name: "_RC_1");

            // 清除当前的源数据图
            ConfigureTarget(m_LightSrc_Occlusion);
            // 清除颜色：背景设为黑色 (0,0,0,0)
            ConfigureClear(ClearFlag.Color, Color.clear);
        }

        public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
        {
            CommandBuffer cmd = CommandBufferPool.Get("Radiance Cascades");

            // 计算当前帧的 VP 矩阵
            // 注意：必须使用 GL.GetGPUProjectionMatrix 处理不同平台的 Y 翻转问题
            Matrix4x4 view = m_Camera.worldToCameraMatrix;
            Matrix4x4 proj = GL.GetGPUProjectionMatrix(m_Camera.projectionMatrix, true);
            
            // 传递当前帧的 VP 矩阵
            cmd.SetGlobalMatrix("_RC_CurrViewProjMatrix", proj * view);
            // 传递分辨率
            cmd.SetGlobalVector("_RC_Param", new Vector4(width, height, 0.0f, 0.0f));
            // 传递bounce intensity
            cmd.SetGlobalFloat("_RC_BounceIntensity", currentBounceIntensity);
            
            cmd.BeginSample("Render Light Source And Occlusion.");
            // 渲染 光源和遮蔽
            // 必须执行一次 CommandBuffer 来应用 OnCameraSetup 里的 ConfigureTarget 和 Clear
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
            
            // A. 定义我们要用哪些 Shader Pass 来画 (比如 UniversalForward, SRPDefaultUnlit)
            var shaderTagId = new ShaderTagId("RC_GBuffer_LightOcc"); 
            var drawingSettings = CreateDrawingSettings(shaderTagId, ref renderingData, SortingCriteria.CommonOpaque);
            // B. 过滤：只画 Settings 里设置的层级 (Wall, Light)
            var filteringSettings = new FilteringSettings(RenderQueueRange.opaque, m_DefaultSettings.targetLayerMask);
            // C. 绘制！
            // 这一步会把符合 Layer 的物体画到 m_LightSrc_Occlusion 上
            context.DrawRenderers(renderingData.cullResults, ref drawingSettings, ref filteringSettings);
            
            cmd.EndSample("Render Light Source And Occlusion.");
            
            cmd.BeginSample("Jump Flood SDF");
            
            Blitter.BlitCameraTexture(cmd, m_LightSrc_Occlusion, m_JFA_Handle_0, screenUVMat, 0);
            
            jumpFlood1IsFinal = true;
            int max = Mathf.Max(width, height);
            int steps = Mathf.CeilToInt(Mathf.Log(max, 2));
            float stepSize = 2;
            for (var n = 0; n < steps; n++)
            {
                stepSize *= 0.5f;
                cmd.SetGlobalFloat("_StepSize", stepSize);
                BlitJumpFloodRT(cmd);
            }
            
            if (jumpFlood1IsFinal)
            {
                Blitter.BlitCameraTexture(cmd, m_JFA_Handle_1, m_SDF_Handle, sdfMat, 0);
            }
            else
            {
                Blitter.BlitCameraTexture(cmd, m_JFA_Handle_0, m_SDF_Handle, sdfMat, 0);
            }
            
            cmd.EndSample("Jump Flood SDF");
            
            context.ExecuteCommandBuffer(cmd);
            cmd.Clear();
            
            cmd.BeginSample("Radiance Cascade Core");
            
            cmd.SetGlobalVector("_RC_Param", new Vector4(width, height, 0.0f, 0.0f));
            //Passing values to the GI Shader
            cmd.SetGlobalTexture("_LightSrc_Occlusion", m_LightSrc_Occlusion);
            cmd.SetGlobalTexture("_SDF", m_SDF_Handle);
            cmd.SetGlobalFloat("_RC_SkyRadiance", currentSkyIntensity/*volume.skyRadiance.value ? 1 : 0*/);
            cmd.SetGlobalColor("_RC_SkyColor", currentSkyColor/*volume.skyColor.value*/);
            cmd.SetGlobalColor("_RC_SunColor", currentSunColor /*volume.sunColor.value*/);
            cmd.SetGlobalFloat("_RC_SunAngle", currentSunAngle /*volume.sunAngle.value*/);
            cmd.SetGlobalFloat("_RC_SunIntensity", currentSunIntensity /*volume.sunAngle.value*/);
            cmd.SetGlobalFloat("_RC_SunHardness", currentSunHardness /*volume.sunAngle.value*/);
            
            cmd.SetGlobalVector("_RC_CascadeResolution", new Vector4(rcWidth, rcHeight, 0.0f, 0.0f));
            cmd.SetGlobalInt("_RC_CascadeCount", currentCascadeCount);
            cmd.SetGlobalVectorArray("_RC_CascadeRanges", m_CascadeRanges);
            cmd.SetGlobalFloat("_RC_RayRange", (new Vector2(width, height) /*/ Mathf.Min(width, height)*/).magnitude * currentRayRange);

            gi1IsFinal = false;//Same as "jumpFlood1IsFinal"
            for (int i = currentCascadeCount - 1; i > 0; i--)   // 这里少算了一次，所以最后得到的其实是4向图
            {
                cmd.SetGlobalInt("_RC_CascadeLevel", i);//Again setting it as global cause I can't pass it directly to the material from a for loop
                BlitGiRT(cmd);//the shader handles the computation of the cascades and the merging at the same time
            }
            
            // 补充：生成mipmap，之后会用
            cmd.GenerateMips(m_RadianceHandle_0);
            cmd.GenerateMips(m_RadianceHandle_1);
            
            cmd.EndSample("Radiance Cascade Core");
            
            
            cmd.BeginSample("Other Process");
            
            // 设置 Interior Lighting 相关的 shader 关键字（互斥：体光照或偷光法）
            if (currentUseVolumetricLighting)
            {
                cmd.EnableShaderKeyword("RC_USE_VOLUMETRIC_LIGHTING");
                cmd.DisableShaderKeyword("RC_USE_TRICK_LIGHT");
            }
            else
            {
                cmd.DisableShaderKeyword("RC_USE_VOLUMETRIC_LIGHTING");
                cmd.EnableShaderKeyword("RC_USE_TRICK_LIGHT");
            }
            
            // 设置全局参数
            cmd.SetGlobalFloat("_RC_TrickLightIntensity", currentTrickLightIntensity);
            cmd.SetGlobalFloat("_RC_TrickLightDistance", currentTrickLightDistance);
            
            // 将要用的图广播出去：
            // *算好的GI结果
            // *SDF
            var finalResultHandle = gi1IsFinal ? m_RadianceHandle_0 : m_RadianceHandle_1;
            var finalForDirResultHandle = gi1IsFinal ? m_RadianceHandle_1 : m_RadianceHandle_0;
            var finalSDF = m_SDF_Handle;
            var finalJFA = jumpFlood1IsFinal ? m_JFA_Handle_0 : m_JFA_Handle_1;
            /*cmd.SetGlobalTexture("_RC_GlobalGI", finalResultHandle);
            cmd.SetGlobalTexture("_RC_FourDirGI", finalForDirResultHandle);*/
            cmd.SetGlobalTexture("_RC_GlobalGI", finalResultHandle);
            cmd.SetGlobalTexture("_RC_FourDirGI", finalResultHandle);
            cmd.SetGlobalTexture("_SDF", finalSDF);
            cmd.SetGlobalTexture("_JFA", finalJFA);
            cmd.SetGlobalVector("_RC_Param", new Vector2(width, height));
            
            cmd.EndSample("Other Process");

            context.ExecuteCommandBuffer(cmd);
            CommandBufferPool.Release(cmd);
        }

        // 2. 记得释放
        public void Dispose()
        {
            m_JFA_Handle_0?.Release();
            m_JFA_Handle_1?.Release();
            m_RadianceHandle_0?.Release();
            m_RadianceHandle_1?.Release();
        }
        
        private void BlitJumpFloodRT(CommandBuffer cmd) {
            if (jumpFlood1IsFinal)
            {
                Blitter.BlitCameraTexture(cmd, m_JFA_Handle_0, m_JFA_Handle_1, jfaMat, 0);
            }
            else {
                Blitter.BlitCameraTexture(cmd, m_JFA_Handle_1, m_JFA_Handle_0, jfaMat, 0);
            }
            jumpFlood1IsFinal = !jumpFlood1IsFinal;
        }
        private void BlitGiRT(CommandBuffer cmd)
        {
            if (gi1IsFinal)
            {
                Blitter.BlitCameraTexture(cmd, m_RadianceHandle_0, m_RadianceHandle_1, rcMat, 0);
            }
            else
            {
                Blitter.BlitCameraTexture(cmd, m_RadianceHandle_1, m_RadianceHandle_0, rcMat, 0);
            }

            gi1IsFinal = !gi1IsFinal;
        }
    }
}