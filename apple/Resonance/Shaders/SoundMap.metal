#include <metal_stdlib>
using namespace metal;

// The Sound Map (SoundMapView.swift). The CPU projects every node, link and
// label into pixels each frame; these shaders turn them into quads. Lines,
// nodes and labels add up in a half-float scene, which is then blurred
// small for bloom and composited onto the view.

struct MapUniforms {
    float2 size; // drawable, pixels
};

static float4 toClip(float2 pixel, float2 size) {
    return float4(pixel.x / size.x * 2.0 - 1.0, 1.0 - pixel.y / size.y * 2.0, 0.0, 1.0);
}

// Quad corners for a 4-vertex triangle strip.
constant float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };

// MARK: Lines

struct MapSegment {
    float4 ends;  // a.xy, b.xy
    float4 color; // premultiplied
    float4 info;  // x: width, pixels
};

struct SegmentOut {
    float4 position [[position]];
    float4 color;
    float across; // pixels from the centre line
    float half_width;
};

vertex SegmentOut mapSegmentVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                   const device MapSegment *segments [[buffer(0)]],
                                   constant MapUniforms &u [[buffer(1)]]) {
    MapSegment s = segments[iid];
    float2 a = s.ends.xy, b = s.ends.zw;
    float2 d = b - a;
    float len = max(length(d), 1e-4);
    float2 dir = d / len;
    float2 normal = float2(-dir.y, dir.x);
    // Thin lines are drawn 1 px wide and fainter, so they don't shimmer.
    float width = max(s.info.x, 1.0);
    float half_width = width * 0.5 + 1.0;
    float2 c = corners[vid];
    float2 p = (c.x < 0 ? a - dir : b + dir) + normal * c.y * half_width;
    SegmentOut out;
    out.position = toClip(p, u.size);
    out.color = s.color * min(s.info.x, 1.0);
    out.across = c.y * half_width;
    out.half_width = width * 0.5;
    return out;
}

fragment float4 mapSegmentFragment(SegmentOut in [[stage_in]]) {
    float coverage = saturate(in.half_width + 0.5 - abs(in.across));
    return in.color * coverage;
}

// MARK: Nodes

struct MapNode {
    float4 shape;  // centre.xy; z: half size; w: halo radius (pixels)
    float4 color;  // rgb; a: intensity
    float4 detail; // x: flash; y: stroke width; z: fill; w: centre dot half size
};

struct NodeOut {
    float4 position [[position]];
    float2 local;
    float4 shape;
    float4 color;
    float4 detail;
};

vertex NodeOut mapNodeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                             const device MapNode *nodes [[buffer(0)]],
                             constant MapUniforms &u [[buffer(1)]]) {
    MapNode n = nodes[iid];
    float extent = max(n.shape.z + n.detail.y + 1.0, max(n.shape.w, n.detail.w + 1.0)) + 1.0;
    float2 local = corners[vid] * extent;
    NodeOut out;
    out.position = toClip(n.shape.xy + local, u.size);
    out.local = local;
    out.shape = n.shape;
    out.color = n.color;
    out.detail = n.detail;
    return out;
}

fragment float4 mapNodeFragment(NodeOut in [[stage_in]]) {
    float2 p = in.local;
    float half_size = in.shape.z;
    float intensity = in.color.a;
    float box = max(abs(p.x), abs(p.y));
    float stroke = 0.0, fill = 0.0;
    if (half_size > 0.0) {
        float sw = in.detail.y;
        stroke = saturate(sw * 0.5 + 0.5 - abs(box - half_size));
        fill = box < half_size ? in.detail.z : 0.0;
    }
    float dot_size = in.detail.w;
    float centre = saturate(dot_size + 0.5 - box);
    float halo = 0.0;
    if (in.shape.w > 0.0) {
        float r = length(p) / in.shape.w;
        halo = exp(-r * r * 4.0) * 0.45 * in.detail.x;
    }
    // Lit nodes have a white centre; faint ones are just a dot in their colour.
    float3 dot_color = half_size > 0.0 ? float3(1.0) : in.color.rgb;
    float3 rgb = in.color.rgb * (stroke + fill) * intensity + dot_color * centre * intensity + float3(halo);
    return float4(rgb, 0.0);
}

// MARK: Labels

struct MapGlyph {
    float4 rect;  // x, y, width, height (pixels)
    float4 uv;    // u0, v0, u1, v1
    float4 color; // rgb, alpha
};

struct GlyphOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
};

vertex GlyphOut mapGlyphVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                               const device MapGlyph *glyphs [[buffer(0)]],
                               constant MapUniforms &u [[buffer(1)]]) {
    MapGlyph g = glyphs[iid];
    float2 c = corners[vid] * 0.5 + 0.5;
    GlyphOut out;
    out.position = toClip(g.rect.xy + c * g.rect.zw, u.size);
    out.uv = mix(g.uv.xy, g.uv.zw, c);
    out.color = g.color;
    return out;
}

fragment float4 mapGlyphFragment(GlyphOut in [[stage_in]],
                                 texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float coverage = atlas.sample(s, in.uv).r;
    return float4(in.color.rgb * in.color.a * coverage, 0.0);
}

// MARK: Composite

struct CompositeOut {
    float4 position [[position]];
    float2 uv;
};

vertex CompositeOut mapCompositeVertex(uint vid [[vertex_id]]) {
    float2 c = corners[vid];
    CompositeOut out;
    out.position = float4(c, 0.0, 1.0);
    out.uv = float2(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
    return out;
}

fragment float4 mapCompositeFragment(CompositeOut in [[stage_in]],
                                     texture2d<float> scene [[texture(0)]],
                                     texture2d<float> bloom [[texture(1)]],
                                     constant float &strength [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = scene.sample(s, in.uv).rgb + bloom.sample(s, in.uv).rgb * strength;
    // A soft shoulder instead of a hard clip, so bright spots stay round.
    float3 over = max(c - 0.8, 0.0);
    c = min(c, 0.8) + 0.2 * (1.0 - exp(-over / 0.2));
    // Premultiplied over the view's own background.
    return float4(c, max(c.r, max(c.g, c.b)));
}
