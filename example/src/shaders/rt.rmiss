#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require

#include "rt_shared.h"

layout(push_constant, scalar) uniform _pc {
    RtPushConstants pc;
};

layout(location = 0) rayPayloadInEXT vec4 payload;

void main() {
    vec3 dir = normalize(gl_WorldRayDirectionEXT);

    // Sky gradient based on ray direction
    float t = 0.5 * (dir.y + 1.0);

    // Horizon colors
    vec3 horizonColor = vec3(0.7, 0.8, 0.95);
    vec3 zenithColor = vec3(0.3, 0.5, 0.9);
    vec3 groundColor = vec3(0.15, 0.12, 0.1);

    vec3 sky;
    if (dir.y > 0.0) {
        // Above horizon - blend to zenith
        sky = mix(horizonColor, zenithColor, pow(dir.y, 0.5));
    } else {
        // Below horizon - darker ground reflection
        sky = mix(horizonColor, groundColor, pow(-dir.y, 0.3));
    }

    // Sun glow
    float sunDot = max(dot(dir, LIGHT_DIR), 0.0);
    vec3 sunGlow = LIGHT_COLOR * pow(sunDot, 64.0) * 2.0;
    vec3 sunDisc = LIGHT_COLOR * pow(sunDot, 512.0) * 5.0;

    payload.rgb = sky + sunGlow + sunDisc;
}
