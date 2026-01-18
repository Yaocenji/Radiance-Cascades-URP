using System;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;

[Serializable, VolumeComponentMenu("Radiance Cascades/RC Configuration")]
public class RadianceCascadesVolume : VolumeComponent, IPostProcessComponent
{
    [Header("General")]
    [Tooltip("开启/关闭 Radiance Cascades")]
    public BoolParameter enableRC = new BoolParameter(true);

    public enum Quality
    { 
        Custom, Low, Medium, High, Ultra
    }
    [Header("质量预设")]
    [Tooltip("设为非custom的时候，其他选项将被自动计算并设置。")]
    public Quality quality = Quality.Ultra;
    
    [Header("Quality & Performance")]
    [Tooltip("渲染分辨率比例 (0.1 - 1.0)。注意：在Volume之间混合此参数会导致RT重建，建议保持全局一致。")]
    public ClampedFloatParameter renderScale = new ClampedFloatParameter(0.5f, 0.1f, 1.0f);

    [Tooltip("级联层数 (1 - 10)。层数越多，计算越慢，但能覆盖更远的距离。")]
    public ClampedIntParameter cascadeCount = new ClampedIntParameter(4, 1, 10);

    [Header("Lighting")]
    [Tooltip("射线最大物理距离 (相对于屏幕对角线)。")]
    public ClampedFloatParameter rayRange = new ClampedFloatParameter(1.0f, 0.1f, 2.0f);

    [Tooltip("多次反弹的强度 (建议 0.2-0.8)。过高会导致光照无限累积爆掉。")]
    public ClampedFloatParameter bounceIntensity = new ClampedFloatParameter(0.6f, 0.0f, 1.2f);

    [Header("Environment")]
    [Tooltip("天空/环境光颜色")]
    public ColorParameter skyColor = new ColorParameter(Color.black);
    
    [Tooltip("环境光强度")]
    public MinFloatParameter skyIntensity = new MinFloatParameter(0.0f, 0.0f);
    
    [Tooltip("太阳颜色")]
    public ColorParameter sunColor = new ColorParameter(Color.black);
    
    [Tooltip("太阳方向")]
    public ClampedFloatParameter sunAngle = new ClampedFloatParameter(0.0f, 0.0f, 2 * Mathf.PI);
    
    [Tooltip("太阳强度")]
    public MinFloatParameter sunIntensity = new MinFloatParameter(0.0f, 0.0f);
    
    [Tooltip("太阳软硬")]
    public MinFloatParameter sunHardness = new MinFloatParameter(1.0f, 1.0f);

    [Header("Interior Lighting")]
    [Tooltip("开启=使用真实体光照（SDF非正部分步进计算，应用occ系数）。关闭=使用偷光法（从边缘向外偷光，不应用occ系数）。")]
    public BoolParameter useVolumetricLighting = new BoolParameter(true);
    
    [Tooltip("偷光强度 (仅在useVolumetricLighting=false时生效, 0=不使用偷光, 值越大偷光效果越强)")]
    public ClampedFloatParameter trickLightIntensity = new ClampedFloatParameter(1.0f, 0.0f, 5.0f);
    
    [Tooltip("偷光距离 (仅在useVolumetricLighting=false时生效, 从边缘向外偷光的最大距离)")]
    public ClampedFloatParameter trickLightDistance = new ClampedFloatParameter(35.0f, 1.0f, 100.0f);

    // --- 接口实现 ---

    public bool IsActive()
    {
        // 只有当勾选了 enable 且层数大于0时才生效
        return enableRC.value && cascadeCount.value > 0;
    }

    // 这是一个不透明效果，不需要 Tile 兼容
    public bool IsTileCompatible() => false;
    
    // 自动计算画质
    private void AutoSetOptions()
    {
        int width = Camera.main.pixelWidth;
        int height = Camera.main.pixelWidth;
    }
} 