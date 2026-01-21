#version 460
#extension GL_EXT_ray_tracing : require
#extension GL_EXT_scalar_block_layout : require
#extension GL_EXT_buffer_reference : require
#extension GL_EXT_buffer_reference2 : require
#extension GL_EXT_shader_explicit_arithmetic_types_int64 : require
#extension GL_EXT_nonuniform_qualifier : require

#include "rt_bindless.h"
#include "rt_shared.h"

// Payload: xyz = color, w = recursion depth
layout(location = 0) rayPayloadInEXT vec4 payload;
layout(location = 1) rayPayloadEXT bool shadowPayload;
hitAttributeEXT vec2 barycentrics;

layout(push_constant, scalar) uniform _pc {
    RtPushConstants pc;
};

// Determine material from primitive ID
// Ground: primitives 0-1, Cube1: 2-13, Cube2: 14-25, Cube3: 26-37
uint getMaterialFromPrimitive(uint primId) {
    if (primId < 2) return MAT_GROUND;
    if (primId < 14) return MAT_RED_METAL;
    if (primId < 26) return MAT_BLUE_REFLECT;
    return MAT_GREEN;
}

// Get material color based on material ID
vec3 getMaterialColor(uint matId, vec3 pos, vec3 normal) {
    if (matId == MAT_GROUND) {
        // Checkerboard pattern
        float scale = 0.5;
        float checker = mod(floor(pos.x * scale) + floor(pos.z * scale), 2.0);
        return mix(vec3(0.3, 0.3, 0.35), vec3(0.8, 0.8, 0.85), checker);
    } else if (matId == MAT_RED_METAL) {
        return vec3(0.9, 0.2, 0.15);
    } else if (matId == MAT_BLUE_REFLECT) {
        return vec3(0.2, 0.4, 0.9);
    } else if (matId == MAT_GREEN) {
        return vec3(0.2, 0.8, 0.3);
    }
    return vec3(0.5);
}

float getMaterialReflectivity(uint matId) {
    if (matId == MAT_GROUND) return 0.35;
    if (matId == MAT_RED_METAL) return 0.7;
    if (matId == MAT_BLUE_REFLECT) return 0.85;
    if (matId == MAT_GREEN) return 0.15;
    return 0.0;
}

void main() {
    IndexBuffer ib = IndexBuffer(pc.index_address);
    VertexBuffer vb = VertexBuffer(pc.vertex_address);

    const uint first = gl_PrimitiveID * 3u;
    const uint i0 = ib.index[first + 0];
    const uint i1 = ib.index[first + 1];
    const uint i2 = ib.index[first + 2];

    const vec3 p0 = vb.position[i0];
    const vec3 p1 = vb.position[i1];
    const vec3 p2 = vb.position[i2];

    // Interpolate hit position
    const vec3 bary = vec3(1.0 - barycentrics.x - barycentrics.y, barycentrics.x, barycentrics.y);
    vec3 localPos = p0 * bary.x + p1 * bary.y + p2 * bary.z;

    // Transform to world space
    vec3 worldPos = gl_WorldRayOriginEXT + gl_WorldRayDirectionEXT * gl_HitTEXT;

    // Compute normal and ensure it faces the ray
    vec3 localNormal = normalize(cross(p1 - p0, p2 - p0));
    vec3 worldNormal = normalize(gl_ObjectToWorldEXT * vec4(localNormal, 0.0));
    if (dot(worldNormal, gl_WorldRayDirectionEXT) > 0.0) {
        worldNormal = -worldNormal;
    }

    // Get material properties based on which primitive was hit
    uint matId = getMaterialFromPrimitive(gl_PrimitiveID);
    vec3 albedo = getMaterialColor(matId, worldPos, worldNormal);
    float reflectivity = getMaterialReflectivity(matId);

    // Lighting calculation
    float NdotL = max(dot(worldNormal, LIGHT_DIR), 0.0);

    // Shadow ray
    shadowPayload = true;
    traceRayEXT(
        accel_table[pc.accel_index],
        gl_RayFlagsTerminateOnFirstHitEXT | gl_RayFlagsSkipClosestHitShaderEXT,
        0xFF,
        0,
        0,
        1, // miss shader index for shadows
        worldPos + worldNormal * 0.001,
        0.001,
        LIGHT_DIR,
        100.0,
        1);

    float shadow = shadowPayload ? 0.3 : 1.0;

    // Ambient + diffuse
    vec3 ambient = vec3(0.15, 0.18, 0.25);
    vec3 diffuse = albedo * LIGHT_COLOR * NdotL * shadow;
    vec3 color = albedo * ambient + diffuse;

    // Specular highlight
    vec3 viewDir = -gl_WorldRayDirectionEXT;
    vec3 halfVec = normalize(LIGHT_DIR + viewDir);
    float spec = pow(max(dot(worldNormal, halfVec), 0.0), 32.0) * shadow;
    color += LIGHT_COLOR * spec * 0.5 * reflectivity;

    // Simple environment reflection (no recursive tracing)
    if (reflectivity > 0.0) {
        vec3 reflectDir = reflect(gl_WorldRayDirectionEXT, worldNormal);

        // Compute sky color for reflection direction
        float t = 0.5 * (reflectDir.y + 1.0);
        vec3 horizonColor = vec3(0.7, 0.8, 0.95);
        vec3 zenithColor = vec3(0.3, 0.5, 0.9);
        vec3 groundColor = vec3(0.15, 0.12, 0.1);

        vec3 envColor;
        if (reflectDir.y > 0.0) {
            envColor = mix(horizonColor, zenithColor, pow(reflectDir.y, 0.5));
        } else {
            envColor = mix(horizonColor, groundColor, pow(-reflectDir.y, 0.3));
        }

        // Add sun reflection
        float sunDot = max(dot(reflectDir, LIGHT_DIR), 0.0);
        envColor += LIGHT_COLOR * pow(sunDot, 64.0) * 2.0;

        // Fresnel effect
        float fresnel = pow(1.0 - max(dot(viewDir, worldNormal), 0.0), 3.0);
        float reflectAmount = mix(reflectivity * 0.3, reflectivity * 0.8, fresnel);
        color = mix(color, envColor, reflectAmount);
    }

    payload = vec4(color, 0.0);
}
