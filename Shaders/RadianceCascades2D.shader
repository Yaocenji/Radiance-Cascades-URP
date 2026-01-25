Shader "RadianceCascades/RadianceCascades2D"
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
            Name "RCPass"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment Frag
            
            // Interior Lighting 变体编译（互斥：体光照或偷光法）
            #pragma multi_compile RC_USE_VOLUMETRIC_LIGHTING RC_USE_TRICK_LIGHT

            #define MAX_CASCADE_COUNT 10

            // -------------------------------------------------------------------------
            // 1. 核心引用库
            // -------------------------------------------------------------------------
            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
            
            // 这个文件包含了标准的 Vert 函数和 Attributes/Varyings 结构体
            // 它是 URP 14+ 全屏后处理的标准写法
            #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
            
            TEXTURE2D(_SDF);
            TEXTURE2D(_LightSrc_Occlusion);

            CBUFFER_START(UnityPerMaterial)
            float _StepSize;
            float2 _RC_Param;
            float4 _RC_CascadeRanges[MAX_CASCADE_COUNT];
            float2 _RC_CascadeResolution;
            uint _RC_CascadeLevel;
            uint _RC_CascadeCount;

            float _RC_SkyRadiance;
            float3 _RC_SkyColor;
            float3 _RC_SunColor;
            float _RC_SunAngle;
            float _RC_SunIntensity;
            float _RC_SunHardness;
            
            float _RC_RayRange;
            CBUFFER_END

            float2 CalculateRayRange(uint index, uint count)
            {
                //A relatively cheap way to calculate ray ranges instead of using pow()
                //The values returned : 0, 3, 15, 63, 255
                //Dividing by 3       : 0, 1, 5, 21, 85
                //and the distance between each value is multiplied by 4 each time

                float maxValue = (1 << (count*2)) - 1;
                float start = (1 << (index*2)) - 1;
                float end = (1 << (index*2 + 2)) - 1;

                float2 r = float2(start, end) / maxValue;
                return r * _RC_RayRange;
            }

            float3 SampleSkyRadiance(float a0, float a1) {
                // Sky integral formula taken from "Analytic Direct Illumination" - Mathis
                // https://www.shadertoy.com/view/NttSW7
                const float3 SkyColor = _RC_SkyColor;
                const float3 SunColor = _RC_SunColor;
                const float SunA = _RC_SunAngle;
                const float SSunS = 8.0;
                const float ISSunS = 1/SSunS;
                float3 SI = SkyColor*(a1-a0-0.5*(cos(a1)-cos(a0)));
                SI += SunColor*(atan(SSunS*(SunA-a0))-atan(SSunS*(SunA-a1)))*ISSunS;
                return SI * 0.16;
            }

            //Raymarching
            float4 SampleRadianceSDF(float2 rayOrigin, float2 rayDirection, float2 rayRange)
            {
                float t = rayRange.x + .1f;
                float4 hit = float4(0, 0, 0, 1);

                float2 _Aspect = _RC_Param / max(_RC_Param.x, _RC_Param.y);
                float2 texelSize = 1 / _RC_Param;

                // 上一次迭代是否在空气
                bool isInAirLast = true;
                // 当前是否在空气
                bool isInAir = true;
                
                for (int i = 0; i < 32; i++)
                {
                    float2 currentPosition = rayOrigin + t * rayDirection * texelSize;

                    if (t > rayRange.y || currentPosition.x < 0 || currentPosition.y < 0 || currentPosition.x > 1 || currentPosition.y > 1)
                    {
                        break;
                    }
                    float sdf = SAMPLE_TEXTURE2D(_SDF, sampler_LinearRepeat, currentPosition).r;
                    
                    // sdf < 0 表示真的撞上了
                    #if RC_USE_VOLUMETRIC_LIGHTING
                    // 真实体光照：SDF非正部分步进计算
                    if (sdf < 0.15)
                    {
                        // 判断此处的厚度
                        float4 litOcc = float4(SAMPLE_TEXTURE2D(_LightSrc_Occlusion, sampler_LinearClamp, currentPosition));
                        
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
                            isInAir = false;
                            float realDist = min(rayRange.y - t, dist);

                            // 这一步总共的"光学厚度" (Optical Depth)
                            // 密度 * 距离
                            // 体渲染时：应用occ系数（litOcc.w已经包含了per-object的occlusion）
                            float segmentDensity = litOcc.w * realDist;
                            // 这一步的透光率 (Segment Transmittance)
                            // 严谨物理公式是 exp(-segmentDensity)
                            float segmentTransmittance = exp(-segmentDensity); // 1.5 是调节系数，控制不透明感

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
                            
                            /*hit.xyz += hit.w * litOcc.rgb * .7f;
                            hit.w *= (1 - litOcc.w) * .8f;
                            t += 3;*/
                        }

                        //t += 1;
                        
                        /*hit = float4(SAMPLE_TEXTURE2D(_LightSrc_Occlusion, sampler_PointClamp, currentPosition).rgb, 0);
                        break;*/
                        
                    }
                    #else
                    // 不使用体光照：直接跳过SDF非正部分
                    if (sdf < 0.15)
                    {
                        // 撞到物体，直接结束// 判断此处的厚度
                        float4 litOcc = float4(SAMPLE_TEXTURE2D(_LightSrc_Occlusion, sampler_LinearClamp, currentPosition));
                        hit.xyz += hit.w * litOcc.rgb * .5f;
                        hit.w = 0;
                        break;
                    }
                    #endif
                    else
                    {
                        //  进入空气
                        isInAir = true;
                        // 这里可以往回缩一点，但不要缩过头了
                        // 规则：如果 distance > 30，那么向后缩3，否则向后缩 distance / 10
                        t += sdf;
                        if (sdf > 30)
                            t -= 3;
                        else
                            t -= sdf / 10.0f;      
                    }   
                }
    
                return hit;
            }


            //Raymarching
            float4 SampleRadianceSDFFixed(float2 rayOrigin, float2 rayDirection, float2 rayRange)
            {
                float t = rayRange.x + .1f;
                float4 hit = float4(0, 0, 0, 1);

                float2 texelSize = 1 / _RC_Param;
                
                for (int i = 0; i < 32; i++)
                {
                    float2 currentPosition = rayOrigin + t * rayDirection * texelSize;

                    if (t > rayRange.y || currentPosition.x < 0 || currentPosition.y < 0 || currentPosition.x > 1 || currentPosition.y > 1)
                    {
                        break;
                    }
                    float sdf = SAMPLE_TEXTURE2D(_SDF, sampler_LinearRepeat, currentPosition).r;
                    
                    // sdf < 0 表示真的撞上了
                    if (sdf < 0)
                    {
                        // 判断此处的厚度
                        float4 litOcc = float4(SAMPLE_TEXTURE2D(_LightSrc_Occlusion, sampler_LinearClamp, currentPosition));
                        
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
                            float realDist = min(rayRange.y - t, dist);

                            // 这一步总共的“光学厚度” (Optical Depth)
                            // 密度 * 距离
                            float segmentDensity = litOcc.w * realDist;
                            // 这一步的透光率 (Segment Transmittance)
                            // 严谨物理公式是 exp(-segmentDensity)
                            float segmentTransmittance = exp(-segmentDensity);

                            // 3. 累积光照 (Radiance)
                            // 能量守恒：被阻挡掉的光转化为了发光（假设是自发光体）
                            // 或者是简单的累加：Emission * 这一段总共的可见度
                            // 近似：(Emission) * (进入时的透光率 - 离开时的透光率)
                            // 这表示“这段路程中被截获/发出的光”
                            float3 segmentLight = litOcc.rgb * (1.0 - segmentTransmittance);

                            hit.rgb += hit.w * segmentLight;

                            // 4. 全局透光率衰减
                            hit.w *= segmentTransmittance;
                            
                            t += realDist;
                        }
                        
                    }
                    else
                    {
                        // 这里可以往回缩一点，但不要缩过头了
                        // 规则：如果 distance > 30，那么向后缩3，否则向后缩 distance / 10
                        t += sdf;
                        /*if (sdf > 30)
                            t -= 3;
                        else
                            t -= sdf / 10.0f; */     
                    }   
                }
    
                return hit;
            }
            
            float InterleavedGradientNoise(float2 position_screen)
            {
                float3 magic = float3(0.06711056f, 0.00583715f, 52.9829189f);
                return frac(magic.z * frac(dot(position_screen, magic.xy)));
            }


            // 将角度归一化到 [0, 2PI)
            float WrapAngle(float angle)
            {
                // 使用 fmod 处理周期，+TWO_PI 保证正数
                return fmod(angle % TWO_PI + TWO_PI, TWO_PI); 
                // 注意：HLSL中 fmod 对负数返回负数，所以要这样写。
                // 更高效写法: angle - floor(angle / TWO_PI) * TWO_PI
            }

            // 核心函数：把 b 限制在 a 的 +/- c 范围内
            float ClampAngle(float a, float b, float c)
            {
                // 1. 计算原始差值
                float diff = b - a;

                // 2. 将差值映射到 [-PI, PI]，寻找最短路径
                // 这一步非常关键，处理了 0/360 的突变
                diff = diff - floor((diff + PI) / TWO_PI) * TWO_PI;

                // 3. 钳制差值
                // 如果 diff 已经在 [-c, c] 内，则不变
                // 如果 diff > c，则限制为 c；如果 diff < -c，限制为 -c
                float clampedDiff = clamp(diff, -c, c);

                // 4. 应用差值并归一化
                return WrapAngle(a + clampedDiff);
            }

            
            //#define Fix_RingingArtifacts
            
            float4 Frag(Varyings IN) : SV_Target
            {
                // 该着色器对应的屏幕像素坐标
                float2 pixelIndex = floor(IN.texcoord.xy * _RC_CascadeResolution);

                // 这一层的块数
                uint blockSqrtCount = 1 << _RC_CascadeLevel;//Another way to write pow(2, _CascadeLevel)

                // 这一层的一块的分辨率
                float2 blockDim = _RC_CascadeResolution / blockSqrtCount;
                // 这一层的块的坐标索引
                int2 block2DIndex = floor(pixelIndex / blockDim);
                // 这一层的块的flatten索引
                float blockIndex = block2DIndex.x + block2DIndex.y * blockSqrtCount;

                // 这一层的块内像素坐标
                float2 coordsInBlock = fmod(pixelIndex, blockDim);

                // 最终答案
                float4 finalResult = 0;

                // 射线起始点（像素空间），是当前甜甜圈的中心点
                float2 rayOrigin = (coordsInBlock + 0.5) * blockSqrtCount;
                // 射线跨越距离
                float2 rayRange = CalculateRayRange(_RC_CascadeLevel, _RC_CascadeCount);

                //bool  = false;

                
                // 角度分辨率
                float angleStep = PI * 2 / (blockSqrtCount * blockSqrtCount * 4);
                    
                // 分别收集四个细分角度的光照
                for (int i = 0; i < 4; i++)
                {
                    // 当前循环对应的角度索引
                    float angleIndex = blockIndex * 4 + i;
                    // 当前循环对应的角度
                    float angle = (angleIndex + 0.5) * angleStep;
                    // 根据角度获取射线方向
                    float2 rayDirection = float2(cos(angle), sin(angle));

                    // 预生产一个抖动
                    float noise = InterleavedGradientNoise(pixelIndex * i);
                    // 在射线方向上略微偏移起始点 (0 ~ 1 个像素单位)
                    float2 thisRayOrigin = rayOrigin + 1 * (noise - 0.5); 

                    // 根据SDF采样
                    float4 radiance = SampleRadianceSDF(thisRayOrigin / _RC_CascadeResolution, rayDirection, rayRange);
                    
                    if(radiance.a >= 0.0001){
                        if (_RC_CascadeLevel != _RC_CascadeCount - 1)
                        {
                            //Merging with the Upper Cascade (_MainTex)

                            // 不使用parallel振铃伪影修复
                            #ifndef  Fix_RingingArtifacts
                                // 在上一层的块内像素坐标，+.25是为了让位置在中间
                                float2 position = coordsInBlock * 0.5 + 0.25;
                                // 对应的上一层的块本身的像素坐标偏移
                                float2 positionOffset = float2(fmod(angleIndex, blockSqrtCount * 2), floor(angleIndex / (blockSqrtCount * 2)));

                                // 把这个像素坐标clamp一下防止采样到隔壁的块
                                position = clamp(position, 0.5, blockDim * 0.5 - 0.5);

                                float2 samplePos = (position + positionOffset * blockDim * 0.5);
                                float2 sampleUV = samplePos / _RC_CascadeResolution;

                                // 采样上一层的块
                                float4 rad = SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, sampleUV);

                                // 叠加
                                radiance.rgb += rad.rgb * radiance.a;
                                radiance.a *= rad.a;
                            
                            
                            #else
                            
                            // 使用parallel振铃伪影修复
                                // 上一层的块数
                                uint upBlockSqrtCount = 1 << (_RC_CascadeLevel + 1);
                                // 上一次 一块的尺度
                                uint2 upBlockDim = _RC_CascadeResolution / upBlockSqrtCount;
                                
                                // 最近的上一层的甜甜圈中心的像素坐标（是插值的四个中心之一）
                                //float2 upRayOrigin = (floor(rayOrigin / upBlockSqrtCount) + .5) * upBlockSqrtCount;
                                //finalResult = float4(upRayOrigin / _RC_CascadeResolution, 0, 1);

                                // 基于（0,0）甜甜圈（probe探针中心）中心点为原点，甜甜圈（probe探针中心）块边长为步长的归一化相对坐标
                                float2 centeredUpDenutCoord = (rayOrigin - upBlockSqrtCount / 2) / upBlockSqrtCount;

                                // 四个插值的上一层的甜甜圈（probe探针中心）的二维索引
                                int2 upDenutIdx00 = int2(floor(centeredUpDenutCoord.x), floor(centeredUpDenutCoord.y));
                                int2 upDenutIdx01 = int2(floor(centeredUpDenutCoord.x), ceil (centeredUpDenutCoord.y));
                                int2 upDenutIdx10 = int2(ceil (centeredUpDenutCoord.x), floor(centeredUpDenutCoord.y));
                                int2 upDenutIdx11 = int2(ceil (centeredUpDenutCoord.x), ceil (centeredUpDenutCoord.y));

                                // 下一层的射线目标
                                float2 target = rayOrigin + rayDirection * rayRange.y;
                                
                                // 甜甜圈（probe探针中心）中心 像素坐标
                                float2 upRayOrigin00 = (upDenutIdx00 + .5) * upBlockSqrtCount;
                                float2 upRayOrigin01 = (upDenutIdx01 + .5) * upBlockSqrtCount;
                                float2 upRayOrigin10 = (upDenutIdx10 + .5) * upBlockSqrtCount;
                                float2 upRayOrigin11 = (upDenutIdx11 + .5) * upBlockSqrtCount;

                                // 甜甜圈（probe探针中心）中心，指向下一层的射线目标的向量
                                float2 upRayDir00 = normalize(target - upRayOrigin00 /*(_RC_CascadeLevel == _RC_CascadeCount - 3 ? upRayOrigin00 : rayOrigin)*/);
                                float2 upRayDir01 = normalize(target - upRayOrigin01 /*(_RC_CascadeLevel == _RC_CascadeCount - 3 ? upRayOrigin01 : rayOrigin)*/);
                                float2 upRayDir10 = normalize(target - upRayOrigin10 /*(_RC_CascadeLevel == _RC_CascadeCount - 3 ? upRayOrigin10 : rayOrigin)*/);
                                float2 upRayDir11 = normalize(target - upRayOrigin11 /*(_RC_CascadeLevel == _RC_CascadeCount - 3 ? upRayOrigin11 : rayOrigin)*/);

                                float t = 0;
                                upRayDir00 = (upRayDir00) * t + rayDirection * (1.0 - t);
                                upRayDir01 = (upRayDir01) * t + rayDirection * (1.0 - t);
                                upRayDir10 = (upRayDir10) * t + rayDirection * (1.0 - t);
                                upRayDir11 = (upRayDir11) * t + rayDirection * (1.0 - t);

                                // 需要merge
                                // 进行merge
                                // 上一层，在不进行预混合x4的角度分辨率
                                float up_noPreMixAngleStep = PI * 2 / (upBlockSqrtCount * upBlockSqrtCount);

                                // 上一层，的方向角，目前先认为是纯平行的
                                float upRayAngle00 = atan2(upRayDir00.y, upRayDir00.x) /*angle*/;
                                float upRayAngle01 = atan2(upRayDir01.y, upRayDir01.x) /*angle*/;
                                float upRayAngle10 = atan2(upRayDir10.y, upRayDir10.x) /*angle*/;
                                float upRayAngle11 = atan2(upRayDir11.y, upRayDir11.x) /*angle*/;

                                // debug功能：
                                // 如果angle向左，那么：下面两个角度顺时针一格（-1），上面两个角度逆时针一格（+1）
                                // 如果angle向右，那么：下面两个角度逆时针一格（+1），上面两个角度顺时针一格（-1）
                                // 如果angle向上，那么：左边两个角度顺时针一格（-1），右边两个角度逆时针一格（+1）
                                // 如果angle向下，那么：左边两个角度逆时针一格（+1），右边两个角度顺时针一格（-1）
                                float stepParam = 0.25;
                                if (angle >= PI * 0.75 && angle < PI * 1.25)
                                {
                                    upRayAngle00 = angle - up_noPreMixAngleStep * stepParam;
                                    upRayAngle10 = angle - up_noPreMixAngleStep * stepParam;
                                    
                                    upRayAngle01 = angle + up_noPreMixAngleStep * stepParam;
                                    upRayAngle11 = angle + up_noPreMixAngleStep * stepParam;
                                }
                                else if (angle < 0 || angle >= PI * 1.75)
                                {
                                    upRayAngle00 = angle + up_noPreMixAngleStep * stepParam;
                                    upRayAngle10 = angle + up_noPreMixAngleStep * stepParam;
                                    
                                    upRayAngle01 = angle - up_noPreMixAngleStep * stepParam;
                                    upRayAngle11 = angle - up_noPreMixAngleStep * stepParam;
                                }
                                else if (angle >= PI * 0.25 && angle < PI * 0.75)
                                {
                                    upRayAngle00 = angle - up_noPreMixAngleStep * stepParam;
                                    upRayAngle01 = angle - up_noPreMixAngleStep * stepParam;
                                    
                                    upRayAngle10 = angle + up_noPreMixAngleStep * stepParam;
                                    upRayAngle11 = angle + up_noPreMixAngleStep * stepParam;
                                }
                                else if (angle >= PI * 1.25 && angle < PI * 1.75)
                                {
                                    upRayAngle00 = angle + up_noPreMixAngleStep * stepParam;
                                    upRayAngle01 = angle + up_noPreMixAngleStep * stepParam;
                                    
                                    upRayAngle10 = angle - up_noPreMixAngleStep * stepParam;
                                    upRayAngle11 = angle - up_noPreMixAngleStep * stepParam;
                                }

                                upRayAngle00 = fmod(fmod(upRayAngle00, 2 * PI) + 2 * PI, 2 * PI);
                                upRayAngle01 = fmod(fmod(upRayAngle01, 2 * PI) + 2 * PI, 2 * PI);
                                upRayAngle10 = fmod(fmod(upRayAngle10, 2 * PI) + 2 * PI, 2 * PI);
                                upRayAngle11 = fmod(fmod(upRayAngle11, 2 * PI) + 2 * PI, 2 * PI);

                                // 新增：钳制
                                upRayAngle00 = ClampAngle(angle, upRayAngle00, up_noPreMixAngleStep);
                                upRayAngle01 = ClampAngle(angle, upRayAngle01, up_noPreMixAngleStep);
                                upRayAngle10 = ClampAngle(angle, upRayAngle10, up_noPreMixAngleStep);
                                upRayAngle11 = ClampAngle(angle, upRayAngle11, up_noPreMixAngleStep);
                                
                                
                                // 计算上一层总方向数
                                int totalDirs = upBlockSqrtCount * upBlockSqrtCount;
                                
                                // 上一层，这个方向角对应的索引
                                int upBlockIndex00 = (round((upRayAngle00 / up_noPreMixAngleStep) - .5) % totalDirs + totalDirs) % totalDirs;
                                int upBlockIndex01 = (round((upRayAngle01 / up_noPreMixAngleStep) - .5) % totalDirs + totalDirs) % totalDirs;
                                int upBlockIndex10 = (round((upRayAngle10 / up_noPreMixAngleStep) - .5) % totalDirs + totalDirs) % totalDirs;
                                int upBlockIndex11 = (round((upRayAngle11 / up_noPreMixAngleStep) - .5) % totalDirs + totalDirs) % totalDirs;

                                int upBlockIndex00_parallel = (round((angle / up_noPreMixAngleStep) - .5) % totalDirs + totalDirs) % totalDirs;
                                int upBlockIndex01_parallel = (round((angle / up_noPreMixAngleStep) - .5) % totalDirs + totalDirs) % totalDirs;
                                int upBlockIndex10_parallel = (round((angle / up_noPreMixAngleStep) - .5) % totalDirs + totalDirs) % totalDirs;
                                int upBlockIndex11_parallel = (round((angle / up_noPreMixAngleStep) - .5) % totalDirs + totalDirs) % totalDirs;

                                // 上一层，方向角对应的二维索引，也就是要去的block的索引
                                int2 upBlock2DIndex00 = int2(upBlockIndex00 % upBlockSqrtCount, upBlockIndex00 / upBlockSqrtCount);
                                int2 upBlock2DIndex01 = int2(upBlockIndex01 % upBlockSqrtCount, upBlockIndex01 / upBlockSqrtCount);
                                int2 upBlock2DIndex10 = int2(upBlockIndex10 % upBlockSqrtCount, upBlockIndex10 / upBlockSqrtCount);
                                int2 upBlock2DIndex11 = int2(upBlockIndex11 % upBlockSqrtCount, upBlockIndex11 / upBlockSqrtCount);
                                
                                int2 upBlock2DIndex00_parallel = int2(upBlockIndex00_parallel % upBlockSqrtCount, upBlockIndex00_parallel / upBlockSqrtCount);
                                int2 upBlock2DIndex01_parallel = int2(upBlockIndex01_parallel % upBlockSqrtCount, upBlockIndex01_parallel / upBlockSqrtCount);
                                int2 upBlock2DIndex10_parallel = int2(upBlockIndex10_parallel % upBlockSqrtCount, upBlockIndex10_parallel / upBlockSqrtCount);
                                int2 upBlock2DIndex11_parallel = int2(upBlockIndex11_parallel % upBlockSqrtCount, upBlockIndex11_parallel / upBlockSqrtCount);

                                // 上一层，的对应的块内坐标，就是这四个

                                // 因此上一层的采样的块，的起点像素坐标
                                float2 offset00 = upBlock2DIndex00 * upBlockDim;
                                float2 offset01 = upBlock2DIndex01 * upBlockDim;
                                float2 offset10 = upBlock2DIndex10 * upBlockDim;
                                float2 offset11 = upBlock2DIndex11 * upBlockDim;

                                
                                float2 offset00_parallel = upBlock2DIndex00_parallel * upBlockDim;
                                float2 offset01_parallel = upBlock2DIndex01_parallel * upBlockDim;
                                float2 offset10_parallel = upBlock2DIndex10_parallel * upBlockDim;
                                float2 offset11_parallel = upBlock2DIndex11_parallel * upBlockDim;
                                
                                //finalResult = float4(upBlockDim, 0, 0);

                                // 因此上一层的采样的块，的实际的像素坐标
                                float2 innerIdx00 = clamp(upDenutIdx00 + .5, .5f, upBlockDim - .5f);
                                float2 innerIdx01 = clamp(upDenutIdx01 + .5, .5f, upBlockDim - .5f);
                                float2 innerIdx10 = clamp(upDenutIdx10 + .5, .5f, upBlockDim - .5f);
                                float2 innerIdx11 = clamp(upDenutIdx11 + .5, .5f, upBlockDim - .5f);
                                
                                float2 pixel00 = offset00 + innerIdx00;
                                float2 pixel01 = offset01 + innerIdx01;
                                float2 pixel10 = offset10 + innerIdx10;
                                float2 pixel11 = offset11 + innerIdx11;
                                
                                float2 pixel00_parallel = offset00_parallel + innerIdx00;
                                float2 pixel01_parallel = offset01_parallel + innerIdx01;
                                float2 pixel10_parallel = offset10_parallel + innerIdx10;
                                float2 pixel11_parallel = offset11_parallel + innerIdx11;

                                // 获取插值值
                                float2 lerpValue = frac(centeredUpDenutCoord);
                                
                                float weight00 = (1 - lerpValue.y) * (1 - lerpValue.x);
                                float weight01 = lerpValue.y       * (1 - lerpValue.x);
                                float weight10 = (1 - lerpValue.y) * lerpValue.x      ;
                                float weight11 = lerpValue.y       * lerpValue.x      ;

                                float4 rad00 = SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearRepeat, pixel00 / _RC_CascadeResolution);
                                float4 rad01 = SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearRepeat, pixel01 / _RC_CascadeResolution);
                                float4 rad10 = SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearRepeat, pixel10 / _RC_CascadeResolution);
                                float4 rad11 = SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearRepeat, pixel11 / _RC_CascadeResolution);

                                // debug:
                                /*rad00 = float4(pixel00 / _RC_CascadeResolution, 0, 1);
                                rad01 = float4(pixel01 / _RC_CascadeResolution, 0, 1);
                                rad10 = float4(pixel10 / _RC_CascadeResolution, 0, 1);
                                rad11 = float4(pixel11 / _RC_CascadeResolution, 0, 1);
                                float4 rad00_parallel = float4(pixel00_parallel / _RC_CascadeResolution, 0, 1);
                                float4 rad01_parallel = float4(pixel01_parallel / _RC_CascadeResolution, 0, 1);
                                float4 rad10_parallel = float4(pixel10_parallel / _RC_CascadeResolution, 0, 1);
                                float4 rad11_parallel = float4(pixel11_parallel / _RC_CascadeResolution, 0, 1);*/

                                int isRad00Valid = (upDenutIdx00.x >= 0 && upDenutIdx00.y >= 0 && upDenutIdx00.x < upBlockDim.x && upDenutIdx00.y < upBlockDim.y) ? 1 : 0;
                                int isRad01Valid = (upDenutIdx01.x >= 0 && upDenutIdx01.y >= 0 && upDenutIdx01.x < upBlockDim.x && upDenutIdx01.y < upBlockDim.y) ? 1 : 0;
                                int isRad10Valid = (upDenutIdx10.x >= 0 && upDenutIdx10.y >= 0 && upDenutIdx10.x < upBlockDim.x && upDenutIdx10.y < upBlockDim.y) ? 1 : 0;
                                int isRad11Valid = (upDenutIdx11.x >= 0 && upDenutIdx11.y >= 0 && upDenutIdx11.x < upBlockDim.x && upDenutIdx11.y < upBlockDim.y) ? 1 : 0;
                                
                                float4 mergeRad = rad00 * weight00 * (float)isRad00Valid +
                                                  rad01 * weight01 * (float)isRad01Valid +
                                                  rad10 * weight10 * (float)isRad10Valid +
                                                  rad11 * weight11 * (float)isRad11Valid;

                                // debug:
                                /*mergeRad = (rad00_parallel - rad00) * weight00 * (float)isRad00Valid +
                                           (rad01_parallel - rad01) * weight01 * (float)isRad01Valid +
                                           (rad10_parallel - rad10) * weight10 * (float)isRad10Valid +
                                           (rad11_parallel - rad11) * weight11 * (float)isRad11Valid;*/

                                // 归一化
                                //mergeRad /= (isRad00Valid + isRad01Valid + isRad10Valid + isRad11Valid) / 4.0f;

                                // debug:
                                /*mergeRad = float4(upRayDir00 * .5 + .5, 0, 1) * weight00 * (float)isRad00Valid +
                                           float4(upRayDir01 * .5 + .5, 0, 1) * weight01 * (float)isRad01Valid +
                                           float4(upRayDir10 * .5 + .5, 0, 1) * weight10 * (float)isRad10Valid +
                                           float4(upRayDir11 * .5 + .5, 0, 1) * weight11 * (float)isRad11Valid;*/
                                
                                
                                radiance.rgb += mergeRad.rgb * radiance.a;
                                radiance.a *= mergeRad.a;
                                
                                //finalResult = radiance * .25;
                                
                            #endif
                            
                        }
                        
                        else{
                            //if this is the Top Cascade and there is no other cascades to merge with, we merge it with the sky radiance instead
                            //float3 sky = SampleSkyRadiance(angle, angle + angleStep) * _RC_SkyRadiance;
                            //radiance.rgb += (sky / angleStep) * 2;

                            // 天光，直接加
                            float3 sky = _RC_SkyColor * _RC_SkyRadiance;
                            // 太阳方向
                            float2 sunDir = float2(cos(_RC_SunAngle), sin(_RC_SunAngle));
                            // 太阳
                            float sunHardness = pow(2, _RC_SunHardness);
                            float3 sun = _RC_SunColor * _RC_SunIntensity * sunHardness * pow(clamp(dot(rayDirection, sunDir), 0, 1), sunHardness);
                            radiance.rgb += (sky + sun) * radiance.a;
                        }
                    }
                    
                    finalResult += radiance * 0.25;
                }


                // 以下是debug

                #ifdef ALL_DEBUG
                // 显示甜甜圈中心的像素位置（转换到01UV来查看）
                //finalResult = float4(rayOrigin / _RC_CascadeResolution, 0, 1);

                
                // 上一层的块数
                uint upBlockSqrtCount = 1 << (_RC_CascadeLevel + 1);
                // 上一次 一块的尺度
                uint2 upBlockDim = _RC_CascadeResolution / upBlockSqrtCount;
                
                // 最近的上一层的甜甜圈中心的像素坐标（是插值的四个中心之一）
                float2 upRayOrigin = (floor(rayOrigin / upBlockSqrtCount) + .5) * upBlockSqrtCount;
                //finalResult = float4(upRayOrigin / _RC_CascadeResolution, 0, 1);

                // 基于（0,0）甜甜圈中心点为原点，甜甜圈块边长为步长的归一化相对坐标
                float2 centeredUpDenutCoord = (rayOrigin - upBlockSqrtCount / 2) / upBlockSqrtCount;

                // 四个插值的上一层的甜甜圈的二维索引
                int2 upDenutIdx00 = int2(floor(centeredUpDenutCoord.x), floor(centeredUpDenutCoord.y));
                int2 upDenutIdx01 = int2(floor(centeredUpDenutCoord.x), ceil (centeredUpDenutCoord.y));
                int2 upDenutIdx10 = int2(ceil (centeredUpDenutCoord.x), floor(centeredUpDenutCoord.y));
                int2 upDenutIdx11 = int2(ceil (centeredUpDenutCoord.x), ceil (centeredUpDenutCoord.y));
                
                // 甜甜圈（probe探针中心）中心 像素坐标
                float2 upRayOrigin00 = (upDenutIdx00 + .5) * upBlockSqrtCount;
                float2 upRayOrigin01 = (upDenutIdx01 + .5) * upBlockSqrtCount;
                float2 upRayOrigin10 = (upDenutIdx10 + .5) * upBlockSqrtCount;
                float2 upRayOrigin11 = (upDenutIdx11 + .5) * upBlockSqrtCount;
                //finalResult = float4(upDenutIdx00 / (float2)upBlockDim, 0, 1);
                //finalResult = float4(frac(centeredUpDenutCoord), 0, 1);

                // 计算当前的pixel对应的角度
                // 在进行预混合x4的角度分辨率 
                float AngleStep = PI * 2 / (blockSqrtCount * blockSqrtCount * 4);
                //finalResult = AngleStep;
                //finalResult = blockSqrtCount;
                // 那这个pixel对应的角度是
                float thisAngle = (blockIndex * 4 + .5) * AngleStep;
                //finalResult = thisAngle ;// / (2 * PI);

                // 根据SDF采样
                float4 radiance = SampleRadianceSDF(rayOrigin / _RC_CascadeResolution, float2(cos(thisAngle), sin(thisAngle)), rayRange);
                //finalResult = radiance;

                // 需要merge
                // 进行merge
                // 上一层，在不进行预混合x4的角度分辨率
                float up_noPreMixAngleStep = PI * 2 / (upBlockSqrtCount * upBlockSqrtCount);
                //finalResult = up_noPreMixAngleStep;

                // 当前循环对应的角度索引
                float angleIndex = blockIndex * 4 + 1;
                // 在上一层的块内像素坐标，+.25是为了让位置在中间
                float2 position = coordsInBlock * 0.5 + 0.25;
                // 对应的上一层的块本身的像素坐标偏移
                float2 positionOffset = float2(fmod(angleIndex, blockSqrtCount * 2), floor(angleIndex / (blockSqrtCount * 2)));
                // 把这个像素坐标clamp一下防止采样到隔壁的块
                position = clamp(position, 0.5, blockDim * 0.5 - 0.5);
                // 根据角度获取射线方向
                // 当前循环对应的角度
                float angle = (angleIndex + 0.5) * angleStep;
                float2 rayDirection = float2(cos(angle), sin(angle));
                float2 target = rayOrigin + rayDirection * rayRange.y;
                float2 newDir = normalize(target - upRayOrigin00);
                float newAngle = atan2(newDir.y, newDir.x);
                newAngle = newAngle <= 0 ? newAngle + 2 * PI : newAngle;
                newAngle = newAngle > 2 * PI ? newAngle - 2 * PI : newAngle;
                
                // 甜甜圈（probe探针中心）中心，指向下一层的射线目标的向量
                float2 upRayDir00 = normalize(target - upRayOrigin00 /*(_RC_CascadeLevel == _RC_CascadeCount - 3 ? upRayOrigin00 : rayOrigin)*/);
                float2 upRayDir01 = normalize(target - upRayOrigin01 /*(_RC_CascadeLevel == _RC_CascadeCount - 3 ? upRayOrigin01 : rayOrigin)*/);
                float2 upRayDir10 = normalize(target - upRayOrigin10 /*(_RC_CascadeLevel == _RC_CascadeCount - 3 ? upRayOrigin10 : rayOrigin)*/);
                float2 upRayDir11 = normalize(target - upRayOrigin11 /*(_RC_CascadeLevel == _RC_CascadeCount - 3 ? upRayOrigin11 : rayOrigin)*/);

                float t = 0;
                upRayDir00 = (upRayDir00) * t + rayDirection * (1.0 - t);
                upRayDir01 = (upRayDir01) * t + rayDirection * (1.0 - t);
                upRayDir10 = (upRayDir10) * t + rayDirection * (1.0 - t);
                upRayDir11 = (upRayDir11) * t + rayDirection * (1.0 - t);

                // 上一层，的方向角，目前先认为是纯平行的
                float upRayAngle00 = atan2(upRayDir00.y, upRayDir00.x) /*angle*/;
                float upRayAngle01 = atan2(upRayDir01.y, upRayDir01.x) /*angle*/;
                float upRayAngle10 = atan2(upRayDir10.y, upRayDir10.x) /*angle*/;
                float upRayAngle11 = atan2(upRayDir11.y, upRayDir11.x) /*angle*/;
                
                // 上一层，这个方向角对应的索引
                int upBlockIndex00 = int((upRayAngle00 / up_noPreMixAngleStep) - .5);
                int upBlockIndex01 = int((upRayAngle01 / up_noPreMixAngleStep) - .5);
                int upBlockIndex10 = int((upRayAngle10 / up_noPreMixAngleStep) - .5);
                int upBlockIndex11 = int((upRayAngle11 / up_noPreMixAngleStep) - .5);
                //finalResult = ((float)upBlockIndex00 / (float)(upBlockSqrtCount * upBlockSqrtCount));

                // 上一层，方向角对应的二维索引，也就是要去的block的索引
                int2 upBlock2DIndex00 = int2(upBlockIndex00 % upBlockSqrtCount, upBlockIndex00 / upBlockSqrtCount);
                int2 upBlock2DIndex01 = int2(upBlockIndex01 % upBlockSqrtCount, upBlockIndex01 / upBlockSqrtCount);
                int2 upBlock2DIndex10 = int2(upBlockIndex10 % upBlockSqrtCount, upBlockIndex10 / upBlockSqrtCount);
                int2 upBlock2DIndex11 = int2(upBlockIndex11 % upBlockSqrtCount, upBlockIndex11 / upBlockSqrtCount);
                //finalResult = upBlockIndex00 / (float)(upBlockSqrtCount * upBlockSqrtCount);
                //finalResult = (upBlockIndex00 % upBlockSqrtCount) / float(upBlockSqrtCount);
                //finalResult = upBlockSqrtCount;
                //finalResult = float4((float2)upBlock2DIndex00 / (float)upBlockSqrtCount, 0, 0);

                // 上一层，的对应的块内坐标，就是这四个
                /*int2 upDenutIdx00
                int2 upDenutIdx01
                int2 upDenutIdx10
                int2 upDenutIdx11*/

                // 因此上一层的采样的块，的起点像素坐标
                float2 offset00 = upBlock2DIndex00 * upBlockDim;
                float2 offset01 = upBlock2DIndex01 * upBlockDim;
                float2 offset10 = upBlock2DIndex10 * upBlockDim;
                float2 offset11 = upBlock2DIndex11 * upBlockDim;
                //finalResult = float4(upBlockDim, 0, 0);

                // 因此上一层的采样的块，的实际的像素坐标
                float2 pixel00 = offset00 + upDenutIdx00;
                float2 pixel01 = offset01 + upDenutIdx01;
                float2 pixel10 = offset10 + upDenutIdx10;
                float2 pixel11 = offset11 + upDenutIdx11;
                //finalResult = float4(pixel00 / _RC_CascadeResolution, 0, 0);

                float4 rad00 = SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, pixel00 / _RC_CascadeResolution);
                float4 rad01 = SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, pixel01 / _RC_CascadeResolution);
                float4 rad10 = SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, pixel10 / _RC_CascadeResolution);
                float4 rad11 = SAMPLE_TEXTURE2D(_BlitTexture, sampler_PointClamp, pixel11 / _RC_CascadeResolution);

                // 获取插值值
                float2 lerpValue = frac(centeredUpDenutCoord);
                
                float4 mergeRad = (rad00 * (1 - lerpValue.y) + rad01 * lerpValue.y) * (1 - lerpValue.x) +
                                  (rad10 * (1 - lerpValue.y) + rad11 * lerpValue.y) * lerpValue.x;
                radiance.rgb += mergeRad.rgb * radiance.a;
                radiance.a *= mergeRad.a;
                
                //finalResult = radiance * .25;


                
                
                // 采样上一层的块
                float4 rad = SAMPLE_TEXTURE2D(_BlitTexture, sampler_LinearClamp, (position + positionOffset * blockDim * 0.5) / _RC_CascadeResolution);
                //finalResult = float4((position + positionOffset * blockDim * 0.5) / _RC_CascadeResolution, 0, 1);

                float2 ref_pixel = (position + positionOffset * blockDim * 0.5);
                float2 diff = ref_pixel - pixel11;
                float diffLen = length(pixel11 - pixel00) + length(pixel10 - pixel00) + length(pixel01 - pixel00);// + length(pixel00 - pixel00);

                
                
                //finalResult = abs(newAngle - angle) / (2 * PI);
                //finalResult = length(upRayOrigin00 - rayOrigin) / 64.0f;
                //finalResult = float4(rayDirection * .5 + 0.5, 0, 1);
                //finalResult = length(newDir - rayDirection);
                //finalResult = rayRange.y;// / 1024;
                //finalResult = float4(newDir * .5 + 0.5, 0, 1);
                // 检查输出颜色是否有 NaN
                /*if (any(isnan(finalResult)) || any(isinf(finalResult))) 
                {
                    return float4(1.0, 0.0, 1.0, 1.0); // 显眼的品红色
                }*/


                // 上一层，的方向角，目前先认为是纯平行的

                upRayAngle00 = upRayAngle00 < 0 ? upRayAngle00 + 2 * PI : upRayAngle00;
                upRayAngle01 = upRayAngle01 < 0 ? upRayAngle01 + 2 * PI : upRayAngle01;
                upRayAngle10 = upRayAngle10 < 0 ? upRayAngle10 + 2 * PI : upRayAngle10;
                upRayAngle11 = upRayAngle11 < 0 ? upRayAngle11 + 2 * PI : upRayAngle11;

                upRayAngle00 = upRayAngle00 > 2 * PI ? upRayAngle00 - 2 * PI : upRayAngle00;
                upRayAngle01 = upRayAngle01 > 2 * PI ? upRayAngle01 - 2 * PI : upRayAngle01;
                upRayAngle10 = upRayAngle10 > 2 * PI ? upRayAngle10 - 2 * PI : upRayAngle10;
                upRayAngle11 = upRayAngle11 > 2 * PI ? upRayAngle11 - 2 * PI : upRayAngle11;

                float angleDiff00 = abs(upRayAngle00 - angle);
                float angleDiff01 = abs(upRayAngle01 - angle);
                float angleDiff10 = abs(upRayAngle10 - angle);
                float angleDiff11 = abs(upRayAngle11 - angle);
                angleDiff00 = min(angleDiff00, 2 * PI - angleDiff00);
                angleDiff01 = min(angleDiff01, 2 * PI - angleDiff01);
                angleDiff10 = min(angleDiff10, 2 * PI - angleDiff10);
                angleDiff11 = min(angleDiff11, 2 * PI - angleDiff11);
                //finalResult = angleDiff11;// / (2 * PI);
                
                //finalResult = float4(diffLen, diffLen, diffLen, 1);

                /*if (radiance.a >= 0.001)
                {
                    radiance.rgb += rad.rgb * radiance.a;
                    radiance.a *= rad.a;
                }*/
                
                //finalResult = radiance * .25f;

                #endif
                
                return finalResult;
            }
            
            ENDHLSL
        }
    }
}