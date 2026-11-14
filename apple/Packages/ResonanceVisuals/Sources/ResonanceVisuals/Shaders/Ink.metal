#include <metal_stdlib>
using namespace metal;

// The Ink visualizer (InkRenderer.swift): a fluid simulated on the GPU, in
// the usual steps of a stable-fluids solver. Each step is one pass over a
// texture: add what the voices pour in, spin the fluid up where it already
// turns (so curls survive), work out where it's being squeezed
// (divergence), solve for the pressure that undoes that, subtract the
// pressure's push, then carry the velocity and the dye along the flow.
// Velocities are in grid cells a second; y runs down, as textures do.

struct InkUniforms {
    float2 texel; // one cell of the texture being written, in uv
    float dt;
    float a;      // each pass's own
    float b;
    float c;
    float d;
    float e;
};

struct InkOut {
    float4 position [[position]];
    float2 uv;
};

// One triangle that covers the target.
vertex InkOut inkVertex(uint vid [[vertex_id]]) {
    float2 p = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
    InkOut out;
    out.position = float4(p, 0.0, 1.0);
    out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);
    return out;
}

constexpr sampler inkSampler(filter::linear, address::clamp_to_edge);

// MARK: Pouring in

struct InkSplat {
    float4 place; // center.xy and radius.xy, in uv
    float4 value; // what's added at the center
};

struct InkSplatOut {
    float4 position [[position]];
    float2 local;
    float4 value [[flat]];
};

constant float2 inkCorners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };

vertex InkSplatOut inkSplatVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                  const device InkSplat *splats [[buffer(0)]]) {
    InkSplat s = splats[iid];
    // Out to three radii, where the falloff has all but gone.
    float2 local = inkCorners[vid] * 3.0;
    float2 uv = s.place.xy + local * s.place.zw;
    InkSplatOut out;
    out.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    out.local = local;
    out.value = s.value;
    return out;
}

// Added to what's there (the pipeline blends one to one).
fragment float4 inkSplatFragment(InkSplatOut in [[stage_in]]) {
    return in.value * exp(-dot(in.local, in.local));
}

// MARK: The solver

// How much the fluid turns at each cell.
fragment float4 inkCurlFragment(InkOut in [[stage_in]], texture2d<float> velocity [[texture(0)]],
                                constant InkUniforms &u [[buffer(0)]]) {
    float l = velocity.sample(inkSampler, in.uv - float2(u.texel.x, 0)).y;
    float r = velocity.sample(inkSampler, in.uv + float2(u.texel.x, 0)).y;
    float t = velocity.sample(inkSampler, in.uv - float2(0, u.texel.y)).x;
    float b = velocity.sample(inkSampler, in.uv + float2(0, u.texel.y)).x;
    return float4(0.5 * ((r - l) - (b - t)), 0, 0, 1);
}

// Pushes the fluid around its own whirls, which the grid would otherwise
// smooth away. `a` is how hard.
fragment float4 inkVorticityFragment(InkOut in [[stage_in]], texture2d<float> velocity [[texture(0)]],
                                     texture2d<float> curl [[texture(1)]], constant InkUniforms &u [[buffer(0)]]) {
    float l = abs(curl.sample(inkSampler, in.uv - float2(u.texel.x, 0)).x);
    float r = abs(curl.sample(inkSampler, in.uv + float2(u.texel.x, 0)).x);
    float t = abs(curl.sample(inkSampler, in.uv - float2(0, u.texel.y)).x);
    float b = abs(curl.sample(inkSampler, in.uv + float2(0, u.texel.y)).x);
    float c = curl.sample(inkSampler, in.uv).x;
    float2 toward = float2(r - l, b - t) * 0.5;
    toward /= length(toward) + 1e-4;
    float2 force = float2(toward.y, -toward.x) * c * u.a;
    float2 v = velocity.sample(inkSampler, in.uv).xy + force * u.dt;
    return float4(clamp(v, float2(-2000.0), float2(2000.0)), 0, 1);
}

// The fluid's sides are walls: what would flow through one is turned back.
static float2 inkWalled(texture2d<float> velocity, float2 uv, float2 center) {
    float2 v = velocity.sample(inkSampler, uv).xy;
    if (uv.x < 0.0 || uv.x > 1.0) { v.x = -center.x; }
    if (uv.y < 0.0 || uv.y > 1.0) { v.y = -center.y; }
    return v;
}

fragment float4 inkDivergenceFragment(InkOut in [[stage_in]], texture2d<float> velocity [[texture(0)]],
                                      constant InkUniforms &u [[buffer(0)]]) {
    float2 c = velocity.sample(inkSampler, in.uv).xy;
    float l = inkWalled(velocity, in.uv - float2(u.texel.x, 0), c).x;
    float r = inkWalled(velocity, in.uv + float2(u.texel.x, 0), c).x;
    float t = inkWalled(velocity, in.uv - float2(0, u.texel.y), c).y;
    float b = inkWalled(velocity, in.uv + float2(0, u.texel.y), c).y;
    return float4(0.5 * ((r - l) + (b - t)), 0, 0, 1);
}

// One round of working the pressure out (Jacobi); the renderer runs a few.
fragment float4 inkPressureFragment(InkOut in [[stage_in]], texture2d<float> pressure [[texture(0)]],
                                    texture2d<float> divergence [[texture(1)]], constant InkUniforms &u [[buffer(0)]]) {
    float l = pressure.sample(inkSampler, in.uv - float2(u.texel.x, 0)).x;
    float r = pressure.sample(inkSampler, in.uv + float2(u.texel.x, 0)).x;
    float t = pressure.sample(inkSampler, in.uv - float2(0, u.texel.y)).x;
    float b = pressure.sample(inkSampler, in.uv + float2(0, u.texel.y)).x;
    float d = divergence.sample(inkSampler, in.uv).x;
    return float4((l + r + t + b - d) * 0.25, 0, 0, 1);
}

// `a` scales a texture as it's copied: the last frame's pressure is a
// head start for this one's.
fragment float4 inkScaleFragment(InkOut in [[stage_in]], texture2d<float> source [[texture(0)]],
                                 constant InkUniforms &u [[buffer(0)]]) {
    return source.sample(inkSampler, in.uv) * u.a;
}

fragment float4 inkGradientFragment(InkOut in [[stage_in]], texture2d<float> velocity [[texture(0)]],
                                    texture2d<float> pressure [[texture(1)]], constant InkUniforms &u [[buffer(0)]]) {
    float l = pressure.sample(inkSampler, in.uv - float2(u.texel.x, 0)).x;
    float r = pressure.sample(inkSampler, in.uv + float2(u.texel.x, 0)).x;
    float t = pressure.sample(inkSampler, in.uv - float2(0, u.texel.y)).x;
    float b = pressure.sample(inkSampler, in.uv + float2(0, u.texel.y)).x;
    float2 v = velocity.sample(inkSampler, in.uv).xy - float2(r - l, b - t);
    return float4(v, 0, 1);
}

// Carries `source` along the flow: each cell takes what was upstream of
// it. `a` is how fast it fades, per second; `b`, `c` the velocity grid's
// cell in uv.
fragment float4 inkAdvectFragment(InkOut in [[stage_in]], texture2d<float> velocity [[texture(0)]],
                                  texture2d<float> source [[texture(1)]], constant InkUniforms &u [[buffer(0)]]) {
    float2 v = velocity.sample(inkSampler, in.uv).xy;
    float2 from = in.uv - u.dt * v * float2(u.b, u.c);
    return source.sample(inkSampler, from) / (1.0 + u.a * u.dt);
}

// MARK: Showing it

// Liquid Light: the dye as blobs of colored oil on a projector's glass,
// lit from behind. Each blob is a lens: it tints the lamp's light with its
// color, bends it at its rim (which goes dark, then bright), and its
// surface throws back a highlight. `a` is the exposure, `b` the shine.
fragment float4 inkLiquidLightFragment(InkOut in [[stage_in]], texture2d<float> dye [[texture(0)]],
                                       constant InkUniforms &u [[buffer(0)]]) {
    float3 c = dye.sample(inkSampler, in.uv).rgb;
    float3 weights = float3(0.3, 0.5, 0.2);
    float2 step = u.texel * 2.0;
    float l = dot(dye.sample(inkSampler, in.uv - float2(step.x, 0)).rgb, weights);
    float r = dot(dye.sample(inkSampler, in.uv + float2(step.x, 0)).rgb, weights);
    float t = dot(dye.sample(inkSampler, in.uv - float2(0, step.y)).rgb, weights);
    float b = dot(dye.sample(inkSampler, in.uv + float2(0, step.y)).rgb, weights);
    float2 slope = float2(l - r, t - b);
    float3 normal = normalize(float3(slope, 0.22));
    float thickness = dot(c, weights);
    // Oil doesn't thin out into the water: it has an edge.
    float oil = smoothstep(0.06, 0.4, thickness * u.a);

    // The lamp, seen through the oil, which bends where it's looked up.
    float2 bent = in.uv + normal.xy * 0.035 * oil;
    float2 from_center = (bent - float2(0.5, 0.47)) * float2(1.15, 1.45);
    float lamp = 1.0 - smoothstep(0.15, 1.0, length(from_center));
    // The oil's own color, deepened: light passes through it twice as thick.
    float3 hue = c / (max(c.r, max(c.g, c.b)) + 1e-4);
    float3 through = mix(hue, hue * hue, saturate(thickness * u.a - 0.4));
    float3 water = float3(0.05, 0.035, 0.09);
    float3 lit = lamp * mix(water, through, oil) * float3(1.0, 0.96, 0.88);

    // A rim: dark where the lens turns the light away, bright just inside.
    float edge = saturate(length(slope) * 3.5) * oil;
    lit *= 1.0 - 0.55 * edge;
    float3 light = normalize(float3(-0.4, -0.6, 0.7));
    float shine = pow(saturate(dot(reflect(-light, normal), float3(0, 0, 1))), 40.0);
    lit += shine * u.b * oil;
    // Premultiplied over the view's own background: the oil hides it.
    return float4(lit, saturate(max(oil * 0.9, max(lit.r, max(lit.g, lit.b)))));
}

// Ink: the dye as it is, thick where there's much of it, with a little
// light on it from the upper left so its folds read. `a` is the
// exposure, `b` the shine.
fragment float4 inkDisplayFragment(InkOut in [[stage_in]], texture2d<float> dye [[texture(0)]],
                                   constant InkUniforms &u [[buffer(0)]]) {
    float3 c = dye.sample(inkSampler, in.uv).rgb;
    float3 weights = float3(0.3, 0.5, 0.2);
    float2 step = u.texel * 1.5;
    float l = dot(dye.sample(inkSampler, in.uv - float2(step.x, 0)).rgb, weights);
    float r = dot(dye.sample(inkSampler, in.uv + float2(step.x, 0)).rgb, weights);
    float t = dot(dye.sample(inkSampler, in.uv - float2(0, step.y)).rgb, weights);
    float b = dot(dye.sample(inkSampler, in.uv + float2(0, step.y)).rgb, weights);
    float3 normal = normalize(float3(l - r, t - b, 0.35));
    float3 light = normalize(float3(-0.45, -0.6, 0.65));
    float facing = dot(normal, light);
    float thickness = dot(c, weights);

    // Thick dye saturates toward its color, not toward white.
    float3 lit = 1.0 - exp(-c * u.a);
    lit *= 0.72 + 0.28 * saturate(facing * 1.4 + 0.3);
    float shine = pow(saturate(dot(reflect(-light, normal), float3(0, 0, 1))), 24.0);
    lit += shine * u.b * saturate(thickness * 3.0);
    // Premultiplied over the view's own background.
    return float4(lit, saturate(max(lit.r, max(lit.g, lit.b))));
}
