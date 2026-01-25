Shader "RadianceCascades/RC_Object"
{
    Properties
    {
        [Header(Textures)]
        _MainTex ("Albedo (RGB) Alpha (A)", 2D) = "white" {}
        _BumpMap ("Normal Map", 2D) = "bump" {}

        [Header(Emission Data)]
        [HDR] _EmissionColor ("Emission Color", Color) = (0,0,0,0)
        
        [Header(Radiance Cascades Data)]
        _IsWall ("Is Wall (1=Block Light)", Float) = 1.0
        _Occlusion ("Occlusion (0=Transparent, 1=Opaque)", Range(0.0, 1.0)) = 1.0
        
        /*[HideInInspector]
        _RC_HistoryTexture ("History Texture", 2D) = "black" {}*/
    }

    SubShader
    {
        // 渲染队列根据需要调整，通常墙壁是不透明的 (Geometry)
        Tags { "RenderType"="Opaque" "RenderPipeline"="UniversalPipeline" "Queue"="Geometry" }

        // =================================================================================
        // Pass 1: Universal2D
        // 作用：主相机渲染，玩家看到的最终画面 (Albedo + Normal Lighting)
        // =================================================================================
        Pass
        {
            Name "Universal2D"
            Tags { "Queue" = "Transparent" "LightMode"="Universal2D" }

            // 混合模式根据需求，墙壁通常是不透明 (One Zero)
            Blend SrcAlpha OneMinusSrcAlpha, One OneMinusSrcAlpha
            Cull Off
            ZWrite Off

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            
            // 引入 URP 核心库
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            // ---------------------------------------------------------
            // 1. CBUFFER 定义 (严格匹配 SRP Batcher)
            // ---------------------------------------------------------
            CBUFFER_START(UnityPerMaterial)
                float4 _MainTex_ST;
                float4 _BumpMap_ST;
                half4 _EmissionColor;
                half _IsWall;
            CBUFFER_END

            // ---------------------------------------------------------
            // 2. 纹理定义 (分离采样器以提高性能)
            // ---------------------------------------------------------
            TEXTURE2D(_MainTex);        SAMPLER(sampler_MainTex);
            TEXTURE2D(_BumpMap);        SAMPLER(sampler_BumpMap);

            // ---------------------------------------------------------
            // 3. 输入/输出 结构体
            // ---------------------------------------------------------
            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv         : TEXCOORD0;
                float3 normalOS   : NORMAL;
                float4 tangentOS  : TANGENT;
                float4 color  : COLOR;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv         : TEXCOORD0;
                float4 color : TEXCOORD6;
            };

            // ---------------------------------------------------------
            // 4. 顶点着色器
            // ---------------------------------------------------------
            Varyings Vert(Attributes IN)
            {
                Varyings OUT = (Varyings)0;
                // 顶点变换
                VertexPositionInputs vertexInput = GetVertexPositionInputs(IN.positionOS.xyz);
                OUT.positionCS = vertexInput.positionCS;
                OUT.uv = TRANSFORM_TEX(IN.uv, _MainTex);

                OUT.color = IN.color;
                return OUT;
            }

            half4 Frag(Varyings IN) : SV_Target
            {
                half4 albedo = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, IN.uv);
                
                half3 finalColor = albedo.rgb * IN.color;
                
                return half4(finalColor, albedo.a);
            }
            ENDHLSL
        }

        // =================================================================================
        // Pass 2: RC_GBuffer
        // 作用：为 Radiance Cascades 准备数据 (Occlusion + Emission)
        // 优化：剔除不需要的法线计算，仅输出纯数据
        // =================================================================================
        Pass
        {
            Name "RC_GBuffer_LightOcc"
            Tags { "Queue" = "Transparent" "LightMode"="RC_GBuffer_LightOcc" } // 对应 C# 中的 ShaderTagId("RC_GBuffer")

            Blend One Zero
            Cull Off
            ZWrite Off

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            
            // Interior Lighting 变体编译（互斥：体光照或偷光法）
            #pragma multi_compile RC_USE_VOLUMETRIC_LIGHTING RC_USE_TRICK_LIGHT
            
            // 引入 URP 核心库
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            // ---------------------------------------------------------
            // 1. CBUFFER 定义 (严格匹配 SRP Batcher)
            // ---------------------------------------------------------
            CBUFFER_START(UnityPerMaterial)
                float4 _MainTex_ST;
                float4 _BumpMap_ST;
                half4 _EmissionColor;
                half _IsWall;
                half _Occlusion;
                float4 _RC_History_Param;
                float4 _RC_Param;
                float4x4 _RC_PrevViewProjMatrix;
                float4x4 _RC_CurrViewProjMatrix;
                float _RC_BounceIntensity;
            CBUFFER_END

            TEXTURE2D(_MainTex);        SAMPLER(sampler_MainTex);
            TEXTURE2D(_BumpMap);        SAMPLER(sampler_BumpMap);
            
            TEXTURE2D(_RC_HistoryTexture);   SAMPLER(sampler_PointClamp);

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv         : TEXCOORD0;
                float3 vertColor : COLOR;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv         : TEXCOORD0;
                float3 vertColor  : TEXCOORD1;
                float3 positionWS : TEXCOORD2;
            };

            // ---------------------------------------------------------
            // 4. 顶点着色器
            // ---------------------------------------------------------
            Varyings Vert(Attributes IN)
            {
                Varyings output = (Varyings)0;
                // 顶点变换
                VertexPositionInputs vertexInput = GetVertexPositionInputs(IN.positionOS.xyz);
                output.positionCS = vertexInput.positionCS;
                output.uv = TRANSFORM_TEX(IN.uv, _MainTex);
                output.vertColor = IN.vertColor;
                output.positionWS = vertexInput.positionWS;

                return output;
            }

            // 计算 Motion Vector (UV 空间位移)
            float2 CalculateMotion(float3 worldPos)
            {
                // 1. 当前帧裁剪空间坐标 (-1 ~ 1)
                float4 clipPos = mul(_RC_CurrViewProjMatrix, float4(worldPos, 1.0));
                
                // 2. 上一帧裁剪空间坐标
                float4 prevClipPos = mul(_RC_PrevViewProjMatrix, float4(worldPos, 1.0));

                // 3. 转为 UV (0 ~ 1)
                float2 uv = (clipPos.xy / clipPos.w) * 0.5 + 0.5;
                float2 prevUV = (prevClipPos.xy / prevClipPos.w) * 0.5 + 0.5;

                // 4. 差值
                float2 ans = uv - prevUV;
                ans.y = -ans.y;
                return ans;
            }

            // ---------------------------------------------------------
            // 5. 片元着色器 (模板)
            // ---------------------------------------------------------
            half4 Frag(Varyings IN) : SV_Target
            {
                half4 albedo = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, IN.uv);
                half3 emitColorAns = _EmissionColor * IN.vertColor * albedo.a;

                float2 motionvector = CalculateMotion(IN.positionWS);
                
                // 计算基础occlusion：基于isWall和alpha
                half baseOcclusion = (abs(_IsWall) * albedo.a) <= .5f ? 0 : 1;
                clip(albedo.a - .5f);
                
                half occlusion = baseOcclusion * _Occlusion;
                
                if (occlusion > 0.001f)
                {
                    float2 screenUV = IN.positionCS.xy / _RC_Param.xy;// * _RC_History_Param.zw;
                    screenUV -= motionvector;
                    half3 historyColor = SAMPLE_TEXTURE2D(_RC_HistoryTexture, sampler_PointClamp, screenUV).rgb;
                    //if (length(historyColor) > 0.1f)
                    emitColorAns += historyColor * _RC_BounceIntensity;
                }
                // emitColorAns = float3(motionvector, 0);
                // occlusion *= .1;   // TMP
                return half4(emitColorAns, occlusion);
            }
            ENDHLSL
        }

        // =================================================================================
        // Pass: NormSpec
        // =================================================================================
        Pass
        {
            Name "GBuffer_NormSpec"
            Tags { "Queue" = "Transparent" "LightMode"="GBuffer_NormSpec" } // 对应 C# 中的 ShaderTagId("RC_GBuffer")

            Blend One Zero
            Cull Off
            ZWrite Off

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            
            // 引入 URP 核心库
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            // ---------------------------------------------------------
            // 1. CBUFFER 定义 (严格匹配 SRP Batcher)
            // ---------------------------------------------------------
            CBUFFER_START(UnityPerMaterial)
                float4 _MainTex_ST;
                float4 _BumpMap_ST;
                half4 _EmissionColor;
                half _IsWall;
                half _Occlusion;
                half _GICoefficient;
                float2 _RotationSinCos; // x=cos, y=sin
            CBUFFER_END

            TEXTURE2D(_MainTex);        SAMPLER(sampler_MainTex);
            TEXTURE2D(_BumpMap);        SAMPLER(sampler_BumpMap);

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv         : TEXCOORD0;
                float3 vertColor : COLOR;
                float3 normalOS   : NORMAL;
                float4 tangentOS  : TANGENT;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv         : TEXCOORD0;
                float3 vertColor  : TEXCOORD1;
                half3 normalWS    : TEXCOORD2;
                half3 tangentWS   : TEXCOORD3;
                half3 bitangentWS : TEXCOORD4;
            };

            // ---------------------------------------------------------
            // 4. 顶点着色器
            // ---------------------------------------------------------
            Varyings Vert(Attributes IN)
            {
                Varyings OUT = (Varyings)0;
                // 顶点变换
                VertexPositionInputs vertexInput = GetVertexPositionInputs(IN.positionOS.xyz);
                OUT.positionCS = vertexInput.positionCS;
                OUT.uv = TRANSFORM_TEX(IN.uv, _MainTex);
                OUT.vertColor = IN.vertColor;


                // 手动构建 TBN
                float cosA = _RotationSinCos.x;
                float sinA = _RotationSinCos.y;
                // [ cos  -sin ]
                // [ sin   cos ]
                half3 worldTangent = half3(cosA, sinA, 0);
                half3 worldBitangent = half3(-sinA, cosA, 0);
                half3 worldNormal = half3(0, 0, 1); 

                // 赋值
                OUT.tangentWS = worldTangent;
                OUT.bitangentWS = worldBitangent;
                OUT.normalWS = worldNormal;


                return OUT;
            }

            // ---------------------------------------------------------
            // 法线映射：将3D法线压缩到2D (RG通道)
            // 使用八面体映射 (Octahedral Mapping)
            // ---------------------------------------------------------
            half2 EncodeNormalOctahedron(half3 n)
            {
                // // 将法线映射到八面体，然后展开到平面
                // n /= (abs(n.x) + abs(n.y) + abs(n.z));
                // half2 result;
                // if (n.z >= 0.0)
                // {
                //     result = n.xy;
                // }
                // else
                // {
                //     result = (1.0 - abs(n.yx)) * (n.xy >= 0.0 ? 1.0 : -1.0);
                // }
                // // 映射到 [0, 1] 范围
                // return result * 0.5 + 0.5;
                return normalize(n).xy * 0.5 + 0.5;
            }

            // ---------------------------------------------------------
            // 5. 片元着色器 (模板)
            // ---------------------------------------------------------
            half4 Frag(Varyings IN) : SV_Target
            {
                // 采样基础色
                half4 albedo = SAMPLE_TEXTURE2D(_MainTex, sampler_MainTex, IN.uv);
                // 计算基础occlusion：基于isWall和alpha
                half baseOcclusion = (abs(_IsWall) * albedo.a) <= .5f ? 0 : 1;
                clip(albedo.a - .5f);
                half occlusion = baseOcclusion * _Occlusion;

                half4 packednorm = SAMPLE_TEXTURE2D(_BumpMap, sampler_BumpMap, IN.uv);
                half3 unpackednorm = UnpackNormal(packednorm);
                unpackednorm = normalize(unpackednorm);
                
                half3 normalWS = mul(half3x3(IN.tangentWS, IN.bitangentWS, IN.normalWS), unpackednorm);

                // 将法线编码到RG通道
                half2 encodedNormal = EncodeNormalOctahedron(normalWS);
                
                // RG通道存储编码后的法线，B通道存储GI系数，A通道保留
                // GI系数用 / 10 打包到[0, 1]，这意味着GI系数范围是0.1到10.0
                return half4(encodedNormal /** (occlusion > 0.001 ? 1 : 0.0001)*/, _GICoefficient / 10.0, 1.0);
            }
            ENDHLSL
        }
    }
}