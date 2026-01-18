#define MAX_RC_LIGHTS 16


#define RC_SDF_LIGHT_DATA\
    int _RC_LightCount;\
    float4 _RC_LightPosRadius[MAX_RC_LIGHTS];\
    float4 _RC_LightColorDecay[MAX_RC_LIGHTS];\
    float4 _RC_LightDir[MAX_RC_LIGHTS];\
    float4 _RC_LightAngles[MAX_RC_LIGHTS];

