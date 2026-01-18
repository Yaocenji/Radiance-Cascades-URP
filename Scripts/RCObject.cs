using UnityEngine;
#if UNITY_EDITOR
using UnityEditor;
#endif

[ExecuteAlways]
[RequireComponent(typeof(Renderer))]
public class RCObject : MonoBehaviour
{
    // --- 属性配置 ---
    
    [Header("Textures")]
    [Tooltip("如果不填：\n1. SpriteRenderer 会自动使用当前的 Sprite 图片\n2. MeshRenderer 会使用材质球默认图片")]
    public Texture2D overrideAlbedo; 
    public Texture2D normalMap;

    [Header("Emission Data")]
    [ColorUsage(false, true)] 
    public Color emissionColor = Color.black;

    [Header("Radiance Cascades Data")]
    [Tooltip("勾选=1 (阻挡光线), 不勾选=0 (不阻挡)")]
    public bool isWall = true;
    
    [Range(0.0f, 1.0f)]
    [Tooltip("遮蔽强度 (0=完全透明, 1=完全不透明)")]
    public float occlusion = 1.0f;
    
    [Header("Normal Control")]
    public bool manualRotation = false;
    [Range(0, 360)] public float overrideAngle = 0f;

    // --- 内部缓存 ---
    private Renderer _renderer;
    private SpriteRenderer _spriteRenderer; // 额外缓存 SpriteRenderer
    private MaterialPropertyBlock _mpb;

    // --- ID 缓存 ---
    private static readonly int ID_MainTex = Shader.PropertyToID("_MainTex");
    private static readonly int ID_BumpMap = Shader.PropertyToID("_BumpMap");
    private static readonly int ID_EmissionColor = Shader.PropertyToID("_EmissionColor");
    private static readonly int ID_IsWall = Shader.PropertyToID("_IsWall");
    private static readonly int ID_Occlusion = Shader.PropertyToID("_Occlusion");
    private static readonly int ID_RotationSinCos = Shader.PropertyToID("_RotationSinCos");
    private static readonly int ID_FlipSigns = Shader.PropertyToID("_FlipSigns"); // 新增：处理Sprite翻转

    private void OnEnable()
    {
        Init();
        ApplyProperties();
    }
    
    private void Start()
    {
        Init();
        ApplyProperties();
    }

    // OnValidate 仅在编辑器数值改变时触发，性能开销小，适合编辑器预览
    private void OnValidate()
    {
        Init();
        ApplyProperties();
    }

    private void Init()
    {
        if (_renderer == null)
            _renderer = GetComponent<Renderer>();
        
        // 尝试获取 SpriteRenderer (如果是 MeshRenderer 则为 null)
        if (_spriteRenderer == null)
            _spriteRenderer = GetComponent<SpriteRenderer>();

        if (_mpb == null)
            _mpb = new MaterialPropertyBlock();
    }

    public void ApplyProperties()
    {
        if (_renderer == null) return;

        // 1. 获取当前的 Block (虽然我们要清理，但获取一下是好习惯，防止丢失某些引擎自动注入的信息)
        _renderer.GetPropertyBlock(_mpb);
        
        // 2.【关键修复】清理旧数据
        // 这解决了“贴图丢失”或“贴图卡死”的问题。
        // 如果这里不 Clear，当你把 overrideAlbedo 设为 null 时，旧的 Texture 还会留在 Block 里。
        _mpb.Clear(); 

        // 3. 设置纹理
        if (overrideAlbedo != null)
        {
            // 情况 A: 用户强制指定了纹理
            _mpb.SetTexture(ID_MainTex, overrideAlbedo);
        }
        else if (_spriteRenderer != null && _spriteRenderer.sprite != null)
        {
            // 情况 B: 用户没指定，且是 SpriteRenderer
            // 【核心修复】显式把 Sprite 的图塞给 Shader。
            // 在 URP SRP Batcher 中，有时 MPB 会导致 Sprite 自身的纹理绑定失效，显式设置最稳妥。
            _mpb.SetTexture(ID_MainTex, _spriteRenderer.sprite.texture);
        }
        // 情况 C: MeshRenderer 且没指定 Override -> MPB 里不存 _MainTex，Shader 会自动回退用材质球的纹理

        // 4. 设置法线
        if (normalMap != null)
            _mpb.SetTexture(ID_BumpMap, normalMap);

        // 5. 设置基础属性
        _mpb.SetColor(ID_EmissionColor, emissionColor);
        _mpb.SetFloat(ID_IsWall, isWall ? 1.0f : 0.0f);
        _mpb.SetFloat(ID_Occlusion, occlusion);

        // 6. 计算旋转 (包含 Flip 处理)
        CalculateRotationAndFlip();

        // 7. 应用
        _renderer.SetPropertyBlock(_mpb);
    }

    private void CalculateRotationAndFlip()
    {
        // --- 旋转 ---
        float angleInDegrees;
        if (manualRotation)
        {
            angleInDegrees = overrideAngle;
            //Debug.Log(overrideAngle);
        }
        else
        {
            angleInDegrees = transform.eulerAngles.z;
            //Debug.Log(transform.eulerAngles.z);
        }
        // 反向旋转
        angleInDegrees *= -1;
        
        float radians = angleInDegrees * Mathf.Deg2Rad;
        Vector2 sinCos = new Vector2(Mathf.Cos(radians), Mathf.Sin(radians));
        _mpb.SetVector(ID_RotationSinCos, sinCos);

        // --- Flip (翻转) 支持 ---
        // 如果 Sprite 翻转了，法线也需要翻转，否则光照会反
        float flipX = 1.0f;
        float flipY = 1.0f;

        if (_spriteRenderer != null)
        {
            flipX = _spriteRenderer.flipX ? -1.0f : 1.0f;
            flipY = _spriteRenderer.flipY ? -1.0f : 1.0f;
        }
        // Transform 的负缩放也会导致翻转，检查一下
        if (transform.lossyScale.x < 0) flipX *= -1.0f;
        if (transform.lossyScale.y < 0) flipY *= -1.0f;

        // 传入 Shader 修正 TBN
        _mpb.SetVector(ID_FlipSigns, new Vector4(flipX, flipY, 0, 0));
    }
    
    private void Update()
    {        
        
        // 无论是 运行模式(Play) 还是 编辑模式(Edit)，都需要响应 Transform 的变化
        
        // 如果开启了手动模式，就不需要监听 Transform 变化了（OnValidate 会处理 overrideAngle）
        if (manualRotation) return;

        // 检测 Transform 是否发生了位移、旋转或缩放
        // transform.hasChanged 是 Unity 内置的标记，当物体被移动/旋转时会自动设为 true
        if (transform.hasChanged)
        {
            ApplyProperties();
            
            // 必须手动重置为 false，否则下次还会进来
            transform.hasChanged = false; 
        }
        
        
        // 运行时逻辑
        if (Application.isPlaying) 
        {
            // 只有当物体发生位移、旋转、缩放 或者 是动画控制的 Sprite 发生变化时才更新
            // 注意：如果你的 Sprite 有序列帧动画，sprite.texture 会变，必须每帧更新或监听变化
            if (transform.hasChanged || (_spriteRenderer != null && _spriteRenderer.sprite != null)) 
            {
                ApplyProperties();
                transform.hasChanged = false;
            }
        }
    }

    // --- 添加到菜单 ---
    #if UNITY_EDITOR
    // RC_Object.mat 的 GUID（从 .meta 文件中获取）
    private static readonly string DefaultMaterialGUID = "ee5f934945b7e9c4b97d0c558b96f56d";
    private static Material _cachedDefaultMaterial;

    [MenuItem("GameObject/2D Object/RC Object (Sprite)", false, 10)]
    static void CreateRCObject(MenuCommand menuCommand)
    {
        GameObject go = new GameObject("RC Object");
        SpriteRenderer spriteRenderer = go.AddComponent<SpriteRenderer>();
        go.AddComponent<RCObject>();
        
        // 加载并设置默认材质
        if (_cachedDefaultMaterial == null)
        {
            string assetPath = AssetDatabase.GUIDToAssetPath(DefaultMaterialGUID);
            if (!string.IsNullOrEmpty(assetPath))
            {
                _cachedDefaultMaterial = AssetDatabase.LoadAssetAtPath<Material>(assetPath);
            }
        }
        
        if (_cachedDefaultMaterial != null)
        {
            spriteRenderer.material = _cachedDefaultMaterial;
        }
        
        GameObjectUtility.SetParentAndAlign(go, menuCommand.context as GameObject);
        Undo.RegisterCreatedObjectUndo(go, "Create RC Object");
        Selection.activeObject = go;
    }
    #endif
}