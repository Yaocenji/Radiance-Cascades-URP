Shader "Hidden/RadianceCascades/JumpFloodAlgorithm"
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
            Name "JFAPass"

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
            
            TEXTURE2D(_InputTex);        // 定义纹理
            SAMPLER(sampler_InputTex);   // 定义采样器 (通常Point或Bilinear)

            CBUFFER_START(UnityPerMaterial)
            float _StepSize;

            float2 _RC_Param;
            CBUFFER_END
            
            float2 Frag(Varyings IN) : SV_Target
            {
                float min_dist_sq = 4.2949673e9;
                float2 min_dist_uv = float2(0, 0);

                float2 aspect = _RC_Param.xy / max(_RC_Param.x, _RC_Param.y);
                float2 stepVec = _StepSize * aspect.yx;
                [unroll]
                for (int y = -1; y <= 1; y ++)
                {
                    [unroll]
                    for (int x = -1; x <= 1; x ++)
                    {
                        float2 offset = float2(x, y) * stepVec;
                        float2 peekUV = IN.texcoord + offset;
                        //float2 peekUV = IN.texcoord + float2(x, y) * _StepSize * aspect.yx;
                        // 越界检查，这个对拖尾很有用！
                        if(peekUV.x < 0.0 || peekUV.x > 1.0 || 
                           peekUV.y < 0.0 || peekUV.y > 1.0)
                        {
                            continue;
                        }
                        
                        float2 peek = SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, peekUV).xy;
                        if (all(peek))
                        {
                            float2 dir = (peek - IN.texcoord) * _RC_Param;
                            float dist_sq = dot(dir, dir);
                            if (dist_sq < min_dist_sq)
                            {
                                min_dist_sq = dist_sq;
                                min_dist_uv = peek;
                            }
                        }
                    }
                }
                
                // 保持原来的数据，如果没有找到更近的
                return float2(min_dist_uv.xy);
            }
            ENDHLSL
        }
    }
}