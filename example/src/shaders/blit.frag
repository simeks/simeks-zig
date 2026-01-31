#version 450
#extension GL_EXT_nonuniform_qualifier : require
#extension GL_EXT_scalar_block_layout : require

#include "bindless.h"

layout(location = 0) in vec2 in_uv;
layout(location = 0) out vec4 out_color;

layout(push_constant, scalar) uniform _pc {
    uint texture_index;
    uint sampler_index;
};

void main() {
    const vec2 uv = vec2(in_uv.x, 1.0 - in_uv.y);
    out_color = texture(sampler2D(texture2D_table[nonuniformEXT(texture_index)], sampler_table[sampler_index]), uv);
}
