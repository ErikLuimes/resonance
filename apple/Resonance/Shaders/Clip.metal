#include <metal_stdlib>
using namespace metal;

// A clip's frame: the visualizer's picture over the
// theme's background, then the overlays (Silicon's vignette, the burned-in
// card), all premultiplied, into the video's pixel buffer.

struct ClipVertex {
    float4 position [[position]];
    float2 uv;
};

vertex ClipVertex clipVertex(uint id [[vertex_id]]) {
    float2 corner = float2((id << 1) & 2, id & 2);
    ClipVertex out;
    out.position = float4(corner * 2 - 1, 0, 1);
    out.uv = float2(corner.x, 1 - corner.y);
    return out;
}

struct ClipUniforms {
    float4 background;
    /// 1 when the picture is upside down (Core Animation's).
    float flipPicture;
};

fragment float4 clipComposite(ClipVertex in [[stage_in]],
                              texture2d<float> picture [[texture(0)]],
                              texture2d<float> vignette [[texture(1)]],
                              texture2d<float> card [[texture(2)]],
                              constant ClipUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float2 uv = in.uv;
    float2 puv = u.flipPicture > 0.5 ? float2(uv.x, 1 - uv.y) : uv;
    float4 p = picture.sample(s, puv);
    float3 c = p.rgb + u.background.rgb * (1 - p.a);
    float4 v = vignette.sample(s, uv);
    c = v.rgb + c * (1 - v.a);
    float4 k = card.sample(s, uv);
    c = k.rgb + c * (1 - k.a);
    return float4(c, 1);
}
