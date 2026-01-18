Shader "Hidden/RadianceCascades/ScreenUV"
{
    Properties
    {
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
            Name "ScreenUVPass"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"


            CBUFFER_START(UnityPerMaterial)
            float2 _RC_Param;
            CBUFFER_END
            
            // 简单的 4-邻域 边缘检测
            bool IsEdge(float2 uv, float2 texelSize)
            {
                float myAlpha = SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uv).a;

                float threshold = 0.001;
                // 1. 如果我自己不是墙，我肯定不是墙的边缘
                if (myAlpha < threshold) return false;
                //return true;

                // 2. 检查上下左右四个邻居
                // 只要有一个邻居是空气 (Alpha < 0.5)，那我就是边缘
                float u = SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uv + float2(0, texelSize.y)).a;
                float d = SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uv - float2(0, texelSize.y)).a;
                float l = SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uv - float2(texelSize.x, 0)).a;
                float r = SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, uv + float2(texelSize.x, 0)).a;

                if (u < threshold || d < threshold || l < threshold || r < threshold) return true;

                // 3. 我是墙，且邻居全是墙 -> 我是内部点，不是种子
                return false;
            }
            
            float2 Frag(Varyings input) : SV_Target
            {
                float2 texelSize = 1.0f / _RC_Param;
                if (IsEdge(input.texcoord, texelSize.xy))
                {
                    return float2(input.texcoord); 
                }
                else
                {
                    // 无效值
                    return float2(-1, -1);
                }
            }
            ENDHLSL
        }
    }
}