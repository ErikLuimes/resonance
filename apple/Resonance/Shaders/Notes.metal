#include <metal_stdlib>
using namespace metal;

// The Notes visualizer (NotesRenderer.swift). The CPU projects the staff,
// the notes and the balls into pixels each frame; everything is one shape,
// a capsule with a radius at each end (a disc when the ends meet). Shapes
// are drawn back to front into a half-float scene with premultiplied
// alpha, so dark notes cover what's behind them and lit ones add light;
// the scene is then blurred small for bloom and composited onto the view.

struct NotesUniforms {
    float2 size; // drawable, pixels
};

struct NoteShape {
    float4 ends;  // a.xy, b.xy (pixels)
    float4 radii; // x: radius at a; y: radius at b; z: edge blur (pixels); w: kind
    float4 color; // premultiplied rgb; a: how much it covers (0 only adds light)
};

// `radii.w`
// 0: an even fill
constant float kindBead = 1.0;  // a fill with a highlight, like a glossy bead
constant float kindGlow = 2.0;  // light falling off from the center line
constant float kindPiece = 3.0; // an even fill with square ends: a piece of a longer line

struct ShapeOut {
    float4 position [[position]];
    float2 pixel;
    float4 ends [[flat]];
    float4 radii [[flat]];
    float4 color [[flat]];
};

constant float2 noteCorners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };

vertex ShapeOut noteShapeVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                const device NoteShape *shapes [[buffer(0)]],
                                constant NotesUniforms &u [[buffer(1)]]) {
    NoteShape s = shapes[iid];
    float2 a = s.ends.xy, b = s.ends.zw;
    float2 d = b - a;
    float len = length(d);
    float2 dir = len > 1e-3 ? d / len : float2(1, 0);
    float2 normal = float2(-dir.y, dir.x);
    // A glow reaches three radii out; the others end at their blurred edge.
    float reach = max(s.radii.x, s.radii.y);
    reach = (s.radii.w == kindGlow ? reach * 3.0 : reach + s.radii.z) + 1.5;
    float2 c = noteCorners[vid];
    float2 p = (c.x < 0 ? a - dir * reach : b + dir * reach) + normal * c.y * reach;
    ShapeOut out;
    out.position = float4(p.x / u.size.x * 2.0 - 1.0, 1.0 - p.y / u.size.y * 2.0, 0.0, 1.0);
    out.pixel = p;
    out.ends = s.ends;
    out.radii = s.radii;
    out.color = s.color;
    return out;
}

fragment float4 noteShapeFragment(ShapeOut in [[stage_in]]) {
    float2 a = in.ends.xy, b = in.ends.zw;
    float2 d = b - a;
    float l2 = dot(d, d);
    float along = l2 > 1e-6 ? dot(in.pixel - a, d) / l2 : 0.0;
    float t = saturate(along);
    float radius = max(mix(in.radii.x, in.radii.y, t), 1e-3);
    float2 offset = in.pixel - (a + d * t);
    float from_line = length(offset);

    if (in.radii.w == kindGlow) {
        float q = from_line / radius;
        return in.color * exp(-q * q * 1.6);
    }

    float edge = max(in.radii.z, 0.7);
    float coverage = 1.0 - smoothstep(-edge, edge, from_line - radius);
    if (in.radii.w == kindPiece && along != t) { coverage = 0.0; }
    float4 color = in.color * coverage;
    if (in.radii.w == kindBead) {
        // Lit from the upper left: a small soft highlight and a faint rim.
        float2 n = offset / radius;
        float nz = sqrt(saturate(1.0 - dot(n, n)));
        float3 normal = float3(n, nz);
        float highlight = pow(saturate(dot(normal, normalize(float3(-0.35, -0.55, 0.75)))), 28.0);
        float rim = pow(1.0 - nz, 3.0) * 0.06;
        // Out of focus, the highlight spreads out with the rest.
        float sharp = saturate(1.0 - in.radii.z / radius);
        color.rgb += (highlight * 0.5 * sharp + rim) * coverage * in.color.a;
    }
    return color;
}

// MARK: Composite

struct NotesCompositeOut {
    float4 position [[position]];
    float2 uv;
};

vertex NotesCompositeOut notesCompositeVertex(uint vid [[vertex_id]]) {
    float2 c = noteCorners[vid];
    NotesCompositeOut out;
    out.position = float4(c, 0.0, 1.0);
    out.uv = float2(c.x * 0.5 + 0.5, 0.5 - c.y * 0.5);
    return out;
}

struct NotesComposite {
    float bloom;
    float backdrop; // the light behind the staff, at its brightest
};

fragment float4 notesCompositeFragment(NotesCompositeOut in [[stage_in]],
                                       texture2d<float> scene [[texture(0)]],
                                       texture2d<float> bloom [[texture(1)]],
                                       constant NotesComposite &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float4 shapes = scene.sample(s, in.uv);
    // A soft light behind everything, falling off to the corners, for the
    // dark staff and unplayed notes to show against.
    float2 from_center = (in.uv - float2(0.5, 0.45)) * float2(1.25, 1.5);
    float light = u.backdrop * (1.0 - smoothstep(0.1, 0.95, length(from_center)));
    float3 c = float3(light, light, light * 0.94) * (1.0 - saturate(shapes.a))
        + shapes.rgb + bloom.sample(s, in.uv).rgb * u.bloom;
    // A soft shoulder instead of a hard clip, so bright spots stay round.
    float3 over = max(c - 0.8, 0.0);
    c = min(c, 0.8) + 0.2 * (1.0 - exp(-over / 0.2));
    // Premultiplied over the view's own background.
    return float4(c, saturate(max(shapes.a, max(c.r, max(c.g, c.b)))));
}
