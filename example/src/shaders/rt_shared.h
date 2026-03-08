#ifndef RT_SHARED_GLSL
#define RT_SHARED_GLSL

struct RtPushConstants {
    uint output_image;
    uint accel_index;
    uint64_t vertex_address;
    uint64_t index_address;
    float time;
    float _pad[3];
};

layout(buffer_reference, std430, buffer_reference_align = 16) readonly buffer VertexBuffer {
    vec3 position[];
};

layout(buffer_reference, std430, buffer_reference_align = 4) readonly buffer IndexBuffer {
    uint index[];
};

// Material IDs (based on instance custom index)
#define MAT_GROUND 0
#define MAT_RED_METAL 1
#define MAT_BLUE_REFLECT 2
#define MAT_GREEN 3

// Light direction (sun-like)
const vec3 LIGHT_DIR = normalize(vec3(0.5, 0.8, -0.3));
const vec3 LIGHT_COLOR = vec3(1.0, 0.95, 0.8);

#endif // RT_SHARED_GLSL
