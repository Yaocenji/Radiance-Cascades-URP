Shader "RadianceCascades/FinalRender"
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
            Name "FinalRenderPass"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            
            // Interior Lighting 变体编译（互斥：体光照或偷光法）
            #pragma multi_compile RC_USE_VOLUMETRIC_LIGHTING RC_USE_TRICK_LIGHT

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
            #include "./RCSDFPointLightInclude.hlsl"

            TEXTURE2D(_RC_FourDirGI);
            TEXTURE2D(_RC_GlobalGI);
            TEXTURE2D(_SDF);
            TEXTURE2D(_JFA);
            TEXTURE2D(_AlbedoGBuffer);
            TEXTURE2D(_NormSpecGBuffer);
            TEXTURE2D(_LightSrc_Occlusion); 

            TEXTURE2D(_SDF_World);
            TEXTURE2D(_LightSrc_Occlusion_World);

            CBUFFER_START(UnityPreMaterial)
            float2 _RC_Param;
            RC_SDF_LIGHT_DATA
            float _RC_TrickLightIntensity;
            float _RC_TrickLightDistance;

            float4 _Player_PosWS_Direction_Angle;    // 玩家的世界空间位置，影响半径，视野角度
            float4 _Player_Radius_Eye_Inner_Outter_Blank;    // 玩家的世界方向
            CBUFFER_END

            // 定义新采样器用于采样lod
            SamplerState my_Trilinear_Clamp; 

            float2 GetSDFGradient(float2 uv, float2 texelSize)
            {
                float h = 5.0; // 采样步长，可以适当调大以获得更平滑的法线
                float l = SAMPLE_TEXTURE2D(_SDF, sampler_LinearClamp, uv + float2(-h, 0) * texelSize).r;
                float r = SAMPLE_TEXTURE2D(_SDF, sampler_LinearClamp, uv + float2( h, 0) * texelSize).r;
                float d = SAMPLE_TEXTURE2D(_SDF, sampler_LinearClamp, uv + float2( 0,-h) * texelSize).r;
                float u = SAMPLE_TEXTURE2D(_SDF, sampler_LinearClamp, uv + float2( 0, h) * texelSize).r;
                return normalize(float2(r - l, u - d));
            }

            float GetRandom(float2 uv)
            {
                return frac(sin(dot(uv, float2(12.9898, 78.233))) * 43758.5453);
            }

                        float2 posPixel2World(float2 pixelPos, float2 screenParam)
            {
                float2 uv = pixelPos / screenParam;
                float2 ndc = uv * 2.0 - 1.0;
            #if UNITY_UV_STARTS_AT_TOP
                ndc.y = -ndc.y;
            #endif
                float deviceDepth = 0.0;
                float4 clipPos = float4(ndc, deviceDepth, 1.0);
                float4 posWSRaw = mul(unity_MatrixInvVP, clipPos);
                float2 posWS = posWSRaw.xy / posWSRaw.w;
                return posWS;
            }
            float2 posWorld2Pixel(float3 worldPos, float2 screenParam)
            {
                // 1. 世界空间 -> 裁剪空间 (Clip Space)
                // 对应 forward 中的 mul(unity_MatrixInvVP, ...) 的逆操作
                float4 clipPos = mul(unity_MatrixVP, float4(worldPos, 1.0));
                // 也可以使用 URP 内置函数: float4 clipPos = TransformWorldToHClip(worldPos);

                // 2. 裁剪空间 -> NDC (-1 ~ 1)
                float2 ndc = clipPos.xy / clipPos.w;

                // 3. 处理平台差异 (Y轴翻转)
                // 逻辑与 forward 函数完全一致：
                // 如果之前为了匹配 NDC 翻转了 Y，现在为了变回屏幕 UV，需要再次翻转回来
            #if UNITY_UV_STARTS_AT_TOP
                ndc.y = -ndc.y;
            #endif

                // 4. NDC -> UV (0 ~ 1)
                float2 uv = ndc * 0.5 + 0.5;

                // 5. UV -> 屏幕像素坐标
                float2 pixelPos = uv * screenParam;

                return pixelPos;
            }

            //Raymarching
            float4 SampleSDF(float2 rayOrigin, float2 rayDirection, float2 rayRange)
            {
                float t = rayRange.x + .01f;
                float4 hit = float4(0, 0, 0, 1);
                float2 texelSize = 1 / _RC_Param;
                
                float minSDF = 65535.0f;
                float minSDFt = 0;

                const int maxMarchingStep = 32;
                for (int i = 0; i < maxMarchingStep; i++)
                {
                    float2 currentPosition = rayOrigin + t * rayDirection * texelSize;

                    if (t > rayRange.y /*|| currentPosition.x < 0 || currentPosition.y < 0 || currentPosition.x > 1 || currentPosition.y > 1*/)
                    {
                        break;
                    }
                    
                    // 选择合适的图来采样SDF信息
                    // 判断是否超出屏幕
                    bool beyoundScreen = currentPosition.x < 0 || currentPosition.y < 0 || currentPosition.x > 1 || currentPosition.y > 1;
                    // 采样世界空间的UV坐标
                    // 目前是硬编码：世界空间=屏幕空间放大四倍 
                    float2 currentPositionWorld = (currentPosition - .5f) / 4.0f + .5f;
                    
                    float sdf = beyoundScreen ? 4.0f * SAMPLE_TEXTURE2D(_SDF_World, sampler_LinearClamp, currentPositionWorld).r : SAMPLE_TEXTURE2D(_SDF, sampler_LinearClamp, currentPosition).r;
                    if (sdf < minSDF)
                    {
                        minSDF = sdf;
                        minSDFt = t;
                    }
                    
                    // sdf < 0 表示真的撞上了
                    #if RC_USE_VOLUMETRIC_LIGHTING
                    // 真实体光照：SDF非正部分步进计算
                    if (sdf < 0.15)
                    {
                        // 判断此处的厚度
                        float4 litOcc = float4(beyoundScreen ? SAMPLE_TEXTURE2D(_LightSrc_Occlusion_World, sampler_LinearClamp, currentPositionWorld) : SAMPLE_TEXTURE2D(_LightSrc_Occlusion, sampler_LinearClamp, currentPosition));
                        
                        float dist = max(abs(sdf), 1.5);
                        
                        if (litOcc.w >= 0.9999)
                        {
                            // 撞到坚实物体，直接结束
                            hit.xyz += hit.w * litOcc.rgb * .5f;
                            hit.w = 0;
                            break;
                        }
                        else
                        {
                            // 进入半透明物体
                            float realDist = min(rayRange.y - t, dist);

                            // 这一步总共的"光学厚度" (Optical Depth)
                            // 密度 * 距离
                            // 体渲染时：应用occ系数（litOcc.w已经包含了per-object的occlusion）
                            float segmentDensity = litOcc.w * realDist;
                            // 这一步的透光率 (Segment Transmittance)
                            // 严谨物理公式是 exp(-segmentDensity)
                            float segmentTransmittance = exp(-segmentDensity);

                            // 3. 累积光照 (Radiance)
                            // 能量守恒：被阻挡掉的光转化为了发光（假设是自发光体）
                            // 或者是简单的累加：Emission * 这一段总共的可见度
                            // 近似：(Emission) * (进入时的透光率 - 离开时的透光率)
                            // 这表示"这段路程中被截获/发出的光"
                            float3 segmentLight = litOcc.rgb * (1.0 - segmentTransmittance);

                            hit.rgb += hit.w * segmentLight;

                            // 4. 全局透光率衰减
                            hit.w *= segmentTransmittance;
                            
                            t += realDist;
                            
                        }

                    }
                    #else
                    // 不使用体光照：直接跳过SDF非正部分
                    if (sdf < 0.15)
                    {
                        // 撞到物体，直接结束
                        float4 litOcc = float4(beyoundScreen ? SAMPLE_TEXTURE2D(_LightSrc_Occlusion_World, sampler_LinearClamp, currentPositionWorld) : SAMPLE_TEXTURE2D(_LightSrc_Occlusion, sampler_LinearClamp, currentPosition));

                        hit.xyz += hit.w * litOcc.rgb * .5f;
                        hit.w = 0;
                        break;
                    }
                    #endif
                    else
                    {
                        //  进入空气
                        // 这里可以往回缩一点，但不要缩过头了
                        // 规则：如果 distance > 30，那么向后缩3，否则向后缩 distance / 10
                        t += sdf;
                        if (sdf > 30)
                            t -= 1;
                        else
                            t -= sdf /30.0f;      
                    }

                    if (i == maxMarchingStep - 1)
                    {
                        hit.w = 0;
                    }
                }
                //if (hit.w >= .001) hit.w *= smoothstep(0, (rayRange.y - minSDFt) * 0.05, max(0, minSDF + 5 ));
                //hit.x = minPixelDist;
                return hit;
            }
            
            // 采样所有的SDF光照
            float3 CalculateAllSDFLight(float2 posWS, float3 normal)
            {
                float3 ans = 0;
                UNITY_LOOP
                for (int i = 0; i < _RC_LightCount; ++i)
                {
                    float3 lightPosWS = _RC_LightPosRadius[i].xyz;
                    float radius = _RC_LightPosRadius[i].w;
                    float distance = length(posWS - lightPosWS);
                    if (distance >= radius) continue;

                    float4 ColorDecay = _RC_LightColorDecay[i];
                    float distanceAtten = exp(-ColorDecay.w * distance);
                    
                    // 角度衰减
                    // 计算当前像素相对于光源的方向
                    float2 toPixelDir = normalize(posWS - lightPosWS);
                    float2 lightRight = _RC_LightDir[i].xy;
                    // 点积计算夹角余弦
                    float dotVal = dot(lightRight, toPixelDir);
                    float cosInner = _RC_LightAngles[i].x;
                    float cosOuter = _RC_LightAngles[i].y;
                    float spotAtten = smoothstep(cosOuter, cosInner, dotVal);
                    // 如果在聚光灯范围外，直接跳过后续昂贵的 Raymarch
                    if (spotAtten <= 0.0001) continue;

                    // 光源到片元方向
                    float3 lightDir = normalize(float3(posWS, 0) - lightPosWS);
                    float lambert = clamp(dot(-lightDir, normal) /** .5 + .5*/, 0, 1);

                    float2 posPS = posWorld2Pixel(float3(posWS, 0), _RC_Param);
                    float2 posUV = posPS / _RC_Param;
                    float2 lightPosPS = posWorld2Pixel(float3(lightPosWS), _RC_Param);
                    float2 lightPosUV = lightPosPS / _RC_Param;
                    float distancePS = length(lightPosPS - posPS);

                    float4 SDFSample = SampleSDF(posUV, -toPixelDir, float2(0, distancePS));
                    // SDFSample.w 是遮挡系数，出现半透物体就会介于0~1
                    
                    ans += lambert * SDFSample.w * ColorDecay.xyz * distanceAtten * spotAtten;
                }
                return ans;
            }



            //计算玩家视野用的独特的Raymarching：无视光源的遮挡
            float4 SampleSDFPlayerSight(float2 rayOrigin, float2 rayDirection, float2 rayRange)
            {
                float t = rayRange.x + .01f;
                float4 hit = float4(0, 0, 0, 1);
                float2 texelSize = 1 / _RC_Param;
                
                float minSDF = 65535.0f;
                float minSDFt = 0;

                const int maxMarchingStep = 32;
                for (int i = 0; i < maxMarchingStep; i++)
                {
                    float2 currentPosition = rayOrigin + t * rayDirection * texelSize;

                    if (t > rayRange.y /*|| currentPosition.x < 0 || currentPosition.y < 0 || currentPosition.x > 1 || currentPosition.y > 1*/)
                    {
                        break;
                    }
                    
                    // 选择合适的图来采样SDF信息
                    // 判断是否超出屏幕
                    bool beyoundScreen = currentPosition.x < 0 || currentPosition.y < 0 || currentPosition.x > 1 || currentPosition.y > 1;
                    // 采样世界空间的UV坐标
                    // 目前是硬编码：世界空间=屏幕空间放大四倍 
                    float2 currentPositionWorld = (currentPosition - .5f) / 4.0f + .5f;
                    
                    float sdf = beyoundScreen ? 4.0f * SAMPLE_TEXTURE2D(_SDF_World, sampler_LinearClamp, currentPositionWorld).r : SAMPLE_TEXTURE2D(_SDF, sampler_LinearClamp, currentPosition).r;
                    if (sdf < minSDF)
                    {
                        minSDF = sdf;
                        minSDFt = t;
                    }
                    
                    // sdf < 0 表示真的撞上了
                    #if RC_USE_VOLUMETRIC_LIGHTING
                    // 真实体光照：SDF非正部分步进计算
                    if (sdf < 0.15)
                    {
                        // 判断此处的厚度
                        float4 litOcc = float4(beyoundScreen ? SAMPLE_TEXTURE2D(_LightSrc_Occlusion_World, sampler_LinearClamp, currentPositionWorld) : SAMPLE_TEXTURE2D(_LightSrc_Occlusion, sampler_LinearClamp, currentPosition));
                        
                        float dist = max(abs(sdf), 1.5);
                        
                        if (litOcc.w >= 0.9999)
                        {
                            // 撞到坚实物体，直接结束
                            hit.xyz += hit.w * litOcc.rgb * .5f;
                            hit.w = 0;
                            break;
                        }
                        else
                        {
                            // 进入半透明物体
                            float realDist = min(max(rayRange.y - t, 3), dist);
                            float segmentDensity = litOcc.w * realDist;
                            segmentDensity = beyoundScreen ? 4.0f : 1.0f;
                            float segmentTransmittance = exp(-segmentDensity);

                            // 3. 累积光照 (Radiance)
                            // 能量守恒：被阻挡掉的光转化为了发光（假设是自发光体）
                            // 或者是简单的累加：Emission * 这一段总共的可见度
                            // 近似：(Emission) * (进入时的透光率 - 离开时的透光率)
                            // 这表示"这段路程中被截获/发出的光"
                            float3 segmentLight = litOcc.rgb * (1.0 - segmentTransmittance);

                            hit.rgb += hit.w * segmentLight;

                            // 核心改变之处：如果是光源，取消这里的全局透光率衰减
                            //if (!(litOcc.r >= 0.001f || litOcc.g >= 0.001f || litOcc.b >= 0.001f))
                            {
                                hit.w *= segmentTransmittance;
                            }
                            
                            t += realDist;
                            
                        }

                    }
                    #else
                    // 不使用体光照：直接跳过SDF非正部分
                    if (sdf < 0.15)
                    {
                        // 撞到物体，直接结束
                        float4 litOcc = float4(beyoundScreen ? SAMPLE_TEXTURE2D(_LightSrc_Occlusion_World, sampler_LinearClamp, currentPositionWorld) : SAMPLE_TEXTURE2D(_LightSrc_Occlusion, sampler_LinearClamp, currentPosition));

                        hit.xyz += hit.w * litOcc.rgb * .5f;
                        hit.w = 0;
                        break;
                    }
                    #endif
                    else
                    {
                        //  进入空气
                        // 这里可以往回缩一点，但不要缩过头了
                        // 规则：如果 distance > 30，那么向后缩3，否则向后缩 distance / 10
                        t += sdf;
                        if (sdf > 30)
                            t -= 1;
                        else
                            t -= sdf /30.0f;      
                    }

                    if (i == maxMarchingStep - 1)
                    {
                        hit.w = 0;
                    }
                }
                //if (hit.w >= .001) hit.w *= smoothstep(0, (rayRange.y - minSDFt) * 0.05, max(0, minSDF + 5 ));
                //hit.x = minPixelDist;
                return hit;
            }

            // 调整饱和度，输入：颜色，饱和度，输出：调整后的颜色
            float3 AdjustSaturation(float3 color, float saturation = 1.0)
            {
                // 1. 计算亮度 (Luminance)
                // 使用标准的 Rec. 601 亮度系数 (人眼对绿色最敏感，蓝色最不敏感)
                float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
                
                // 2. 构建灰度颜色
                float3 gray = float3(luminance, luminance, luminance);
                
                // 3. 在 灰度 和 原色 之间插值
                // saturation = 0 -> 全灰
                // saturation = 1 -> 原色
                return lerp(gray, color, saturation);
            }
            
            
            half4 Frag(Varyings input) : SV_Target
            {
                half2 uv = input.texcoord;
                half4 ans;
                float2 posPS = uv * _RC_Param;
                float2 ndc = uv * 2.0 - 1.0;
            #if UNITY_UV_STARTS_AT_TOP
                ndc.y = -ndc.y;
            #endif
                float deviceDepth = 0.0;
                float4 clipPos = float4(ndc, deviceDepth, 1.0);
                float4 posWSRaw = mul(unity_MatrixInvVP, clipPos);
                float2 posWS = posWSRaw.xy / posWSRaw.w;

                // 基础色
                half3 albedo = SAMPLE_TEXTURE2D(_AlbedoGBuffer, sampler_LinearClamp, uv).rgb;
                
                // 采样法线和GI系数（从RG通道解码法线，从B通道读取GI系数）
                half4 normSpecData = SAMPLE_TEXTURE2D(_NormSpecGBuffer, sampler_LinearClamp, uv);
                half2 encodedNormal = normSpecData.rg;
                // 解包GI系数
                half giCoefficient = normSpecData.b * 10.0;
                
                // 法线反映射：从八面体映射恢复3D法线
                // 将 [0, 1] 映射回 [-1, 1]
                half2 e = encodedNormal * 2.0 - 1.0;
                half3 normal;
                normal.xy = e;
                normal.z = sqrt(1.0 - e.x * e.x - e.y * e.y);
                
                half3 gi = 0;
                // 四次采样，分别计算法线
                half2 uvs[4];
                uvs[0] = uv * .5f;
                uvs[1] = uv * .5f + float2(.5, 0);
                uvs[2] = uv * .5f + float2(0, .5);
                uvs[3] = uv * .5f + float2(.5, .5);

                float height = 0.5;
                half3 lightDirs[4];
                lightDirs[0] = half3(1, 1, height);
                lightDirs[1] = half3(-1, 1, height);
                lightDirs[2] = half3(-1, -1, height);
                lightDirs[3] = half3(1, -1, height);
                for (int i = 0; i < 4; ++i)
                {
                    lightDirs[i] = normalize(lightDirs[i]);
                }

                // 四方向法线累计
                for (int i = 0; i < 4; ++i)
                {
                    // 兰伯特系数
                    float lambert = clamp(dot(lightDirs[i], normal) /** .5 + .5*/, 0, 1);
                    gi += SAMPLE_TEXTURE2D(_RC_FourDirGI, sampler_LinearClamp, uvs[i]).rgb * .25f * lambert;
                }
                
                // 增加SDF点光源
                gi += CalculateAllSDFLight(posWS, normal);

                // 采样SDF
                float sdf = SAMPLE_TEXTURE2D(_SDF, sampler_LinearClamp, uv).r;
                float2 sdfTexSize = float2(1.0f / _RC_Param.x, 1.0f / _RC_Param.y);
                
                // 采样JFA
                float2 nearestEdge = SAMPLE_TEXTURE2D(_JFA, sampler_LinearClamp, uv);
                float2 toNearest = normalize(nearestEdge - uv);
                float4 litOcc = SAMPLE_TEXTURE2D(_LightSrc_Occlusion, sampler_LinearClamp, uv);
                
                bool isWall = litOcc.w >= .001f;// && abs(litOcc.rgb) <= .001f;

                #if RC_USE_TRICK_LIGHT
                // 偷光法：从边缘向外偷光
                float trickGIParam = _RC_TrickLightIntensity;
                float maxTrickGILen = _RC_TrickLightDistance;
                float3 trickGI = 0;

                // 用噪声
                float noise = GetRandom(uv * _ScreenParams.xy) - 0.5;
                // 扰动采样方向
                float2 jitteredDir = clamp(normalize(float2(noise, -noise) * 0.2), -.5f, .5f);
                
                // 让 LOD 也跳动
                float jitteredLOD = 0.5 * (1 - noise) + noise * 0;
                
                // 扰动采样距离
                float jitteredStealDist = noise * 2 + (1 - noise) * 5;

                if (isWall)
                {
                    // 直接沿着SDF梯度前进
                    // 理论上来说，偷全局光可以直接
                    // 往那个方向"伸手"去偷光 
                    float2 sample_RC_UV = nearestEdge + toNearest * jitteredStealDist * sdfTexSize + jitteredDir * sdfTexSize.xy;
                    float2 samplePS = sample_RC_UV * _RC_Param;
                    float2 sampleWS = posPixel2World(samplePS, _RC_Param);
                    
                    // 采样那里的 GI
                    float3 leakedGI = 0;
                    half2 sampleUVs[4];
                    sampleUVs[0] = sample_RC_UV * .5f;
                    sampleUVs[1] = sample_RC_UV * .5f + float2(.5, 0);
                    sampleUVs[2] = sample_RC_UV * .5f + float2(0, .5);
                    sampleUVs[3] = sample_RC_UV * .5f + float2(.5, .5);
                    for (int i = 0; i < 4; ++i)
                    {
                        float lambert = clamp(dot(lightDirs[i], normal) /** .5 + .5*/, 0, 1);
                        //leakedGI += SAMPLE_TEXTURE2D_LOD(_RC_FourDirGI, my_Trilinear_Clamp, sampleUVs[i], jitteredLOD).rgb * .25f * lambert;
                        leakedGI += SAMPLE_TEXTURE2D(_RC_FourDirGI, sampler_LinearClamp, sampleUVs[i]).rgb * .25f * lambert;
                        leakedGI += CalculateAllSDFLight(sampleWS, normal);
                    }
                    
                    // 计算衰减 (边缘亮，内部黑)
                    float t = abs(sdf) / maxTrickGILen;
                    float edgeMask = 1.0 - pow(t, .125);

                    trickGI += edgeMask * leakedGI * trickGIParam;
                    
                    // 应用偷来的光
                    gi += trickGI;
                }
                #endif
                
                gi *= giCoefficient;

                // AO：
                // 在SDF 介于 0 ~ 15之间，平滑地计算AO，并应用遮挡系数，遮挡系数越高，AO越大
                //float nearestEdgeOcc = SAMPLE_TEXTURE2D(_LightSrc_Occlusion, sampler_LinearClamp, nearestEdge).w;
                float sdfAO = smoothstep(0, 15, sdf);// * nearestEdgeOcc;
                sdfAO = sdf < 0.15 ? 1 : sdfAO;
                sdfAO = sdfAO * .5 + .5;

                // 接下来是一个后处理：玩家视野
                float2 playerPosWS = _Player_PosWS_Direction_Angle.xy;
                float2 playerPosPS = posWorld2Pixel(float3(playerPosWS, 0), _RC_Param);
                float2 playerPosUV = playerPosPS / _RC_Param;
                float playerDirection = _Player_PosWS_Direction_Angle.z;
                float playerAngle = _Player_PosWS_Direction_Angle.w;
                float playerEyeRadius = _Player_Radius_Eye_Inner_Outter_Blank.x;
                float playerInnerRadius = _Player_Radius_Eye_Inner_Outter_Blank.y;
                float playerOutterrRadius = _Player_Radius_Eye_Inner_Outter_Blank.z;

                float2 frag2PlayerDir = normalize(playerPosPS - posPS);
                float2 player2FragDir = -frag2PlayerDir;
                float distancePS = length(posPS - playerPosPS);
                float distanceWS = length(posWS - playerPosWS);
                // 距离系数
                float dist_dPSbWS = distanceWS != 0 ? distancePS / distanceWS : 1;
                // 获取像素空间的半径
                float playerRadiusPS = dist_dPSbWS * playerInnerRadius;
                // 半径圈：
                // float2 fragOffsetFromPlayer = playerPosPS + player2FragDir * dist_dPSbWS * playerRadius;
                
                // 加入角度
                float playerFaceRad = radians(playerDirection);
                float2 playerFaceDir = float2(cos(playerFaceRad), sin(playerFaceRad));
                float angleDiff = degrees(abs(acos(dot(player2FragDir, playerFaceDir))));

                // 如果比半径还近，那么直接可看到
                float radiusParam = smoothstep(playerInnerRadius + .1f, playerInnerRadius - .1f, distanceWS);

                float playerSDF_SightValue = 0;

                // 这里要减去像素空间的半径
                if (distancePS > playerRadiusPS) playerSDF_SightValue = SampleSDFPlayerSight(uv, frag2PlayerDir, float2(0, distancePS - playerRadiusPS)).w;
                else playerSDF_SightValue = 1;

                // 如果在视野角度以内，那么该怎么算怎么算
                if (angleDiff <= playerAngle)
                {
                    // do nothing
                }
                // 否则要加入半径系数
                else
                {
                    playerSDF_SightValue *= radiusParam;
                }

                // 核心后处理
                // 看不见的地方 gi 减少
                //gi *= playerSDF_SightValue * .75 + .25;
                
                // 应用GI系数
                ans.xyz = albedo * (gi + .01f);

                // 看不见的地方调整饱和度，直接调成接近灰色
                float3 playerColor = AdjustSaturation(ans.xyz, playerSDF_SightValue * .95 + .05f);
                // 看不见的地方调低亮度
                playerColor *= playerSDF_SightValue * .4 + .6;
                
                //ans.xyz = playerColor;
                ans.xyz *= sdfAO;

                // 以下是debug内容
                
                /*ans.xy = gradient;// * .5 + .5;
                ans.z = 0;
                ans.w = 1;*/

                /*// debug:绘制SDF等高线
                float dist = SAMPLE_TEXTURE2D(_SDF, sampler_LinearClamp, input.texcoord).r;
                // 取绝对值 (以防你有负数 SDF)
                dist = abs(dist);
                // 2. 生成等高线
                // Frequency: 控制线条密度。
                // 如果 dist 是 UV 单位(0~1)，设大点 (e.g. 50-100)
                // 如果 dist 是 像素单位(0~1000)，设小点 (e.g. 0.05-0.1)
                float frequency = .1; 
                // 使用 Sine 函数生成波纹
                float pattern = sin(dist * frequency * PI);
                // 锐化线条 (使其变成黑白分明的线)
                // abs(pattern) > 0.95 会得到很细的线
                float lines = step(.9, abs(pattern));
                // 3. 混合背景色以便观察
                // 红色 = 线条， 蓝色 = 距离深浅
                return float4(lines, dist * 2.0, 0, 1);*/

                //ans.xyz = isWall;

                /*ans.xy = jitteredDir * .5 + .5;
                ans.z = 0;*/

                // 采样normal
                //ans.xyz = normal.xyz;

                //ans = float4(posWS.xy, 0, 1);
                //ans = float4(_Player_PosWS_Radius_Smoothness_Angle.xy, 0, 1);

                //ans = playerSampleSDF;

                //ans = radiusParam;

                //ans = playerSDF_SightValue;
                
                return ans;
            }
            ENDHLSL
        }
    }
}