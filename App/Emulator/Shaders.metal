#include <metal_stdlib>
using namespace metal;

struct VOut { float4 position [[position]]; float2 uv; };

vertex VOut fullscreen_vertex(uint vid [[vertex_id]]) {
    // Triangle strip: BL, BR, TL, TR
    float2 pos[4] = { {-1,-1}, {1,-1}, {-1,1}, {1,1} };
    float2 uv[4]  = { {0,1},  {1,1},  {0,0},  {1,0} };
    VOut o; o.position = float4(pos[vid], 0, 1); o.uv = uv[vid];
    return o;
}

fragment float4 frame_fragment(VOut in [[stage_in]],
                               texture2d<float> frame [[texture(0)]]) {
    constexpr sampler s(mag_filter::nearest, min_filter::nearest,
                        address::clamp_to_edge);
    return float4(frame.sample(s, in.uv).rgb, 1.0);
}
