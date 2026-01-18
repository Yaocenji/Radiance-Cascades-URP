using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

#if UNITY_EDITOR
using UnityEditor;
#endif

#if UNITY_EDITOR
[InitializeOnLoad]
#endif
public static class RCSDFPointLightManager
{
    public const int MaxLights = 16;

    // shader property IDs
    private static readonly int _CountID = Shader.PropertyToID("_RC_LightCount");
    private static readonly int _PosRadiusID = Shader.PropertyToID("_RC_LightPosRadius"); // xyz: pos, w: radius
    private static readonly int _ColorDecayID = Shader.PropertyToID("_RC_LightColorDecay"); // xyz: color, w: decay
    private static readonly int _DirID = Shader.PropertyToID("_RC_LightDir"); // xyz: direction (right)
    private static readonly int _AngleID = Shader.PropertyToID("_RC_LightAngles"); // x: cos(inner/2), y: cos(outer/2)

    // CPU端缓存数组
    private static readonly Vector4[] _posRadiusArray = new Vector4[MaxLights];
    private static readonly Vector4[] _colorDecayArray = new Vector4[MaxLights];
    private static readonly Vector4[] _dirArray = new Vector4[MaxLights];
    private static readonly Vector4[] _angleArray = new Vector4[MaxLights];

    // 活跃光源列表
    private static readonly List<RCPointLight> _lights = new List<RCPointLight>();

    static RCSDFPointLightManager()
    {
        // 订阅渲染管线事件 (支持 URP, HDRP)
        RenderPipelineManager.beginCameraRendering += OnBeginCameraRendering;
        // 如果是 Built-in 管线，可能需要 Camera.onPreRender，但在 Editor 下 beginCameraRendering 通常也有效
        Camera.onPreRender += OnCameraPreRender;
    }

    public static void RegisterLight(RCPointLight light)
    {
        if (!_lights.Contains(light))
        {
            _lights.Add(light);
            UpdateLightStatus();
        }
    }

    public static void UnregisterLight(RCPointLight light)
    {
        if (_lights.Contains(light))
        {
            _lights.Remove(light);
            light.isValidLight = false; // 重置状态
            UpdateLightStatus();
        }
    }

    // 标记哪些光源是生效的（前16个）
    private static void UpdateLightStatus()
    {
        for (int i = 0; i < _lights.Count; i++)
        {
            _lights[i].isValidLight = (i < MaxLights);
        }
    }

    // 渲染回调 (SRP)
    private static void OnBeginCameraRendering(ScriptableRenderContext context, Camera camera)
    {
        PushDataToShader();
    }

    // 渲染回调 (Built-in legacy)
    private static void OnCameraPreRender(Camera camera)
    {
        PushDataToShader();
    }

    private static void PushDataToShader()
    {
        int count = 0;
        int totalRegistered = _lights.Count;

        for (int i = 0; i < totalRegistered; i++)
        {
            if (count >= MaxLights) break;

            RCPointLight light = _lights[i];
            
            // 防御性编程：如果有光源被销毁但没注销
            if (light == null) continue; 
            if (!light.isActiveAndEnabled) continue;

            // 1. Position & Radius
            Vector3 pos = light.transform.position;
            _posRadiusArray[count] = new Vector4(pos.x, pos.y, pos.z, light.radius);

            // 2. Color & Decay
            // HDR颜色直接传递，RGB值可能大于1
            _colorDecayArray[count] = new Vector4(light.lightColor.r, light.lightColor.g, light.lightColor.b, light.decayFactor);

            // 3. Direction (取transform.right作为X轴朝向)
            Vector3 right = light.transform.right;
            _dirArray[count] = new Vector4(right.x, right.y, right.z, 0);

            // 4. Angles (预计算Cos值以优化Shader性能)
            // 将角度转为弧度，取一半，算Cos
            // 注意：Unity Mathf.Cos 接收弧度
            float halfInner = light.innerAngle * 0.5f * Mathf.Deg2Rad;
            float halfOuter = light.outerAngle * 0.5f * Mathf.Deg2Rad;
            
            // x = cos(inner/2), y = cos(outer/2)
            // 角度越小，Cos值越大。 InnerCos > OuterCos
            _angleArray[count] = new Vector4(Mathf.Cos(halfInner), Mathf.Cos(halfOuter), 0, 0);

            count++;
        }

        // 提交数据
        Shader.SetGlobalInt(_CountID, count);
        
        // 只有在有光源时才传递数组，节省带宽 (但在某些驱动上最好总是传，这里做个简单优化)
        if (count > 0)
        {
            Shader.SetGlobalVectorArray(_PosRadiusID, _posRadiusArray);
            Shader.SetGlobalVectorArray(_ColorDecayID, _colorDecayArray);
            Shader.SetGlobalVectorArray(_DirID, _dirArray);
            Shader.SetGlobalVectorArray(_AngleID, _angleArray);
        }
    }
}