#include <metal_stdlib>
using namespace metal;

// The bloom composite the glowing visualizers share: a scene with its
// blurred copy added on, a soft light behind, and a soft shoulder instead
// of a hard clip. The names are the Notes visualizer's, where it began.
// The Mac app's Shaders/Notes.metal has the same pass for the renderers
// that haven't moved into this package yet (Notes, Terrain, Rasters);
// that copy goes when they do.

constant float2 bloomCorners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };

struct NotesCompositeOut {
    float4 position [[position]];
    float2 uv;
};

vertex NotesCompositeOut notesCompositeVertex(uint vid [[vertex_id]]) {
    float2 c = bloomCorners[vid];
    NotesCompositeOut out;
    out.position = float4(c, 0.0, 1.0);
    out.uv = float2(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
    return out;
}

struct NotesComposite {
    float bloom;
    float backdrop; // the light behind the scene, at its brightest
};

fragment float4 notesCompositeFragment(NotesCompositeOut in [[stage_in]],
                                       texture2d<float> scene [[texture(0)]],
                                       texture2d<float> bloom [[texture(1)]],
                                       constant NotesComposite &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 shapes = scene.sample(s, in.uv);
    float2 from_center = (in.uv - float2(0.5, 0.45)) * float2(1.25, 1.5);
    float light = u.backdrop * (1.0 - smoothstep(0.1, 0.95, length(from_center)));
    float3 c = float3(light, light, light * 0.94) * (1.0 - saturate(shapes.a))
        + shapes.rgb + bloom.sample(s, in.uv).rgb * u.bloom;
    float3 over = max(c - 0.8, 0.0);
    c = min(c, 0.8) + 0.2 * (1.0 - exp(-over / 0.2));
    return float4(c, saturate(max(shapes.a, max(c.r, max(c.g, c.b)))));
}
