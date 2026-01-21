#version 460
#extension GL_EXT_ray_tracing : require

// Shadow miss shader - if we miss, we're not in shadow
layout(location = 1) rayPayloadInEXT bool isShadowed;

void main() {
    isShadowed = false;
}
