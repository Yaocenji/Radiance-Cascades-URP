Shader "RadianceCascades/DistanceField"
{
    Properties
    {
        // 为了兼容性保留，但在 URP Blitter 中通常由脚本设置 _BlitTexture
        _MainTex ("Texture", 2D) = "white" {}
        _Tolerance ("Tolerance", Float) = 0.001
    }

    SubShader
    {
        Tags { "RenderType"="Opaque" "RenderPipeline" = "UniversalPipeline" }
        
        // 核心渲染状态设置：关深度测试、关剔除、关深度写入
        Cull Off 
        ZWrite Off 
        ZTest Always

        Pass
        {
            Name "SDFPass"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag

            // -------------------------------------------------------------------------
            // 1. 核心引用库
            // -------------------------------------------------------------------------
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            
            // 这个文件包含了标准的 Vert 函数和 Attributes/Varyings 结构体
            // 它是 URP 14+ 全屏后处理的标准写法
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"

            // 我们需要原始的 Occlusion 图来判断正负
            TEXTURE2D(_LightSrc_Occlusion); 

            CBUFFER_START(UnityPerMaterial)
            float _StepSize;
            float _Tolerance;
            CBUFFER_END

            float2 _RC_Param;
            
            float Frag(Varyings IN) : SV_Target
            {
                float2 targUV = SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, IN.texcoord).xy;
                float2 targPos = targUV;
                float2 thisPos = IN.texcoord;
                
                // 像素级距离，而不是UV空间距离
                float dist = length(targPos * _RC_Param - thisPos * _RC_Param);
                
                float isWall = SAMPLE_TEXTURE2D(_LightSrc_Occlusion, sampler_PointClamp, IN.texcoord).w;
                // 如果是墙(1)，距离为负；如果是空(0)，距离为正
                // SDF 定义：内部 < 0, 外部 > 0
                float sdf = (isWall > _Tolerance) ? -dist : dist;

                // 小技巧：SDF + 1，让occ内缩一点，可以避免光源自遮挡
                sdf += 1;
                
                return sdf;
            }
            ENDHLSL
        }
    }
}