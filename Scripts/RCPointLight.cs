using UnityEngine;
#if UNITY_EDITOR
using UnityEditor;
#endif

[ExecuteAlways] // 确保在编辑器非运行模式下也能工作
[DisallowMultipleComponent]
public class RCPointLight : MonoBehaviour
{
    [Header("Basic Settings")]
    [ColorUsage(true, true)] // 开启HDR，允许强度超过1
    public Color lightColor = new Color(1, 0.9f, 0.7f, 1);
    
    [Min(0)]
    public float radius = 5.0f;

    [Header("Attenuation")]
    [Tooltip("衰减系数 k，公式为 exp(-dist * k)")]
    [Min(0.01f)]
    public float decayFactor = 1.0f;

    [Header("Spot Angle (Degrees)")]
    [Range(0, 360)] public float innerAngle = 360f;
    [Range(0, 360)] public float outerAngle = 360f;

    // 运行时状态，由管理器更新
    [HideInInspector] public bool isValidLight = false;

    private void OnEnable()
    {
        RCSDFPointLightManager.RegisterLight(this);
    }

    private void OnDisable()
    {
        RCSDFPointLightManager.UnregisterLight(this);
        isValidLight = false;
    }

    private void Update()
    {
        // 如果变换发生改变，通知管理器（可选，如果每帧都重建列表则不需要）
        if (transform.hasChanged)
        {
            transform.hasChanged = false;
        }
        
        // 确保外角不小于内角，防止Shader计算错误
        if (outerAngle < innerAngle) outerAngle = innerAngle;
    }

    // 在Scene窗口绘制简单的调试线框
private void OnDrawGizmos()
    {
        if (!enabled) return;

        // 确定基础颜色（如果是无效光源显示红色）
        Color baseColor = isValidLight ? lightColor : Color.red;
        // 保证Alpha通道用于Gizmos显示清晰
        Color solidColor = new Color(baseColor.r, baseColor.g, baseColor.b, 1.0f);
        Color fadeColor = new Color(baseColor.r, baseColor.g, baseColor.b, 0.4f);

        Vector3 pos = transform.position;
        // 既然是2D系统，我们默认 transform.right 是光照朝向
        Vector3 forward = transform.right; 

        // 1. 绘制中心点
        Gizmos.color = solidColor;
        Gizmos.DrawWireSphere(pos, 0.2f);

        // 2. 绘制最大半径圆 (很淡)
        Gizmos.color = new Color(baseColor.r, baseColor.g, baseColor.b, 0.1f);
        Gizmos.DrawWireSphere(pos, radius);

        // 3. 绘制扇形角度 (如果不是360度全向光)
        if (outerAngle < 360f || innerAngle < 360f)
        {
            // --- 外角 (Outer Angle) - 范围边界 ---
            Gizmos.color = fadeColor;
            float halfOuter = outerAngle * 0.5f;
            
            // 计算外角方向向量 (绕Z轴旋转)
            Vector3 outDirA = Quaternion.Euler(0, 0, halfOuter) * forward;
            Vector3 outDirB = Quaternion.Euler(0, 0, -halfOuter) * forward;

            Gizmos.DrawLine(pos, pos + outDirA * radius);
            Gizmos.DrawLine(pos, pos + outDirB * radius);
            // 连接外边，形成扇形感
            Gizmos.DrawLine(pos + outDirA * radius, pos + outDirB * radius);

            // --- 内角 (Inner Angle) - 满强度区域 ---
            if (innerAngle < outerAngle)
            {
                Gizmos.color = solidColor; // 内角用实色
                float halfInner = innerAngle * 0.5f;

                Vector3 inDirA = Quaternion.Euler(0, 0, halfInner) * forward;
                Vector3 inDirB = Quaternion.Euler(0, 0, -halfInner) * forward;

                // 内角线稍微画短一点点，以示区分，或者画满皆可
                Gizmos.DrawLine(pos, pos + inDirA * radius);
                Gizmos.DrawLine(pos, pos + inDirB * radius);
            }
        }
        else
        {
            // 如果是全向光，只画个十字准星示意
             Gizmos.color = fadeColor;
             Gizmos.DrawRay(pos, forward * radius);
             Gizmos.DrawRay(pos, -forward * radius);
             Gizmos.DrawRay(pos, transform.up * radius);
             Gizmos.DrawRay(pos, -transform.up * radius);
        }

        // 4. 绘制黄色中心主轴，指示方向
        Gizmos.color = Color.yellow;
        Gizmos.DrawRay(pos, forward * (radius * 0.2f));
    }

    // --- 添加到菜单 ---
    #if UNITY_EDITOR
    [MenuItem("GameObject/Light/RC SDF Point Light", false, 10)]
    static void CreateCustomLight(MenuCommand menuCommand)
    {
        GameObject go = new GameObject("RC Point Light");
        go.AddComponent<RCPointLight>();
        GameObjectUtility.SetParentAndAlign(go, menuCommand.context as GameObject);
        Undo.RegisterCreatedObjectUndo(go, "Create RC Point Light");
        Selection.activeObject = go;
    }
    #endif
}

// --- Inspector 自定义编辑器 (用于显示警告) ---
#if UNITY_EDITOR
[CustomEditor(typeof(RCPointLight))]
[CanEditMultipleObjects]
public class RCPointLightEditor : Editor
{
    public override void OnInspectorGUI()
    {
        RCPointLight light = (RCPointLight)target;

        // 检测是否有效
        if (!light.isValidLight && light.enabled && light.gameObject.activeInHierarchy)
        {
            EditorGUILayout.HelpBox($"Max light count ({RCSDFPointLightManager.MaxLights}) exceeded! This light will be ignored.", MessageType.Warning);
        }

        DrawDefaultInspector();
    }
}
#endif