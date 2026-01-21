#version 450

layout(location = 0) out vec2 out_uv;

const vec2 positions[3] = vec2[](
    vec2(-1.0, -1.0),
    vec2(3.0, -1.0),
    vec2(-1.0, 3.0)
);

void main() {
    const vec2 pos = positions[gl_VertexIndex];
    out_uv = pos * vec2(0.5, -0.5) + vec2(0.5);
    gl_Position = vec4(pos, 0.0, 1.0);
}
