#include <metal_stdlib>
using namespace metal;

// The 1084S's tube (MonitorView.swift), over the glass of the case photo.
// One quad, this fragment function; the picture is the 384×272 frame
// MonitorScreen draws, as a mipmapped texture. Measurements and reasons in
// design/crt-monitor/README.md; the shader is the mockup's, line for line.

struct MonitorUniforms {
    float2 quad;        // the view's size in photo pixels
    float2 glassHalf;   // half the glass's size in photo pixels
    float2 scale;       // the raster's size, 1 when on; the power animation shrinks it
    float px;           // device pixels per photo pixel
    float time;
    float bright;       // the picture's brightness, 1 when on
    float focus;        // the beam's width in lines, 0.4 when warm
    float wobble;       // the shimmy while the deflection settles
    float ambient;      // how much of the room shows in the glass, 1 when off
    float seed;         // changes every frame, for the noise
    float collapse;     // 1 while the picture is a line or a dot
};

struct MonitorVertex {
    float4 position [[position]];
    float2 uv;
};

vertex MonitorVertex monitorVertex(uint id [[vertex_id]]) {
    float2 corner = float2(id & 1, id >> 1);
    MonitorVertex out;
    out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
    out.uv = float2(corner.x, 1.0 - corner.y);
    return out;
}

constant float2 FRAME = float2(384.0, 272.0);
constant float RASTER = 0.93;   // the raster's width as a share of the glass
constant float BARREL = 0.07;   // lookup distortion, fitted to the reference's edge bow

constexpr sampler frameSampler(filter::linear, mip_filter::linear, address::clamp_to_edge);

static float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float sdBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float3 frameAt(texture2d<float> frame, float2 t, float lod) {
    return frame.sample(frameSampler, t, level(lod)).rgb;
}

// One line of the picture at texel column u (continuous): crisp texels with
// a pixel-footprint edge, softened by the monitor's video bandwidth.
static float3 lineSample(texture2d<float> frame, float u, float v, float lod) {
    float fw = max(fwidth(u), 1e-4);
    float b = floor(u + 0.5);
    float us = b + clamp((u - b) / fw, -0.5, 0.5);
    float y = v / FRAME.y;
    return 0.18 * frameAt(frame, float2((us - 0.4) / FRAME.x, y), lod)
         + 0.64 * frameAt(frame, float2(us / FRAME.x, y), lod)
         + 0.18 * frameAt(frame, float2((us + 0.4) / FRAME.x, y), lod);
}

fragment float4 monitorFragment(MonitorVertex in [[stage_in]],
                                constant MonitorUniforms &U [[buffer(0)]],
                                texture2d<float> frame [[texture(0)]]) {
    float2 pos = (in.uv - 0.5) * U.quad;
    float2 p = pos / U.glassHalf;
    float sd = sdBox(pos, U.glassHalf, 30.0);
    float aa = 1.0 / U.px;
    float inGlass = 1.0 - smoothstep(-aa, aa, sd);

    // Where this point of the glass looks on the raster.
    float2 q = p / RASTER;
    q *= 1.0 + BARREL * dot(q, q);
    q.x += U.wobble * (0.6 * sin(U.time * 62.0 + q.y * 7.0) + 0.4 * sin(U.time * 9.0));
    q.y *= 1.0 + 0.5 * U.wobble * sin(U.time * 11.0);
    float2 s = max(U.scale, float2(1e-4));
    float2 t = (q / s) * 0.5 + 0.5;

    float3 pic = float3(0.0);
    float pxLine = U.px * U.glassHalf.y * 2.0 * RASTER * s.y / FRAME.y;   // device pixels per raster line
    if (U.collapse < 0.5) {
        if (t.x > -0.03 && t.x < 1.03 && t.y > -0.03 && t.y < 1.03) {
            float foot = 1.0 / max(pxLine, 1e-3);                        // the pixel's footprint in lines
            float lod = clamp(log2(max(foot, 1.0)), 0.0, 8.0);
            float ly = t.y * FRAME.y;
            float k0 = floor(ly - 0.5) - 1.0;
            float u = t.x * FRAME.x + (hash(float2(k0, U.seed)) - 0.5) * 0.25;   // a touch of line jitter
            float3 acc = float3(0.0);
            float wsum = 0.0;
            float sige = 0.0;
            for (int i = 0; i < 4; i++) {
                float k = k0 + float(i);
                float inside = step(0.0, k) * step(k, FRAME.y - 1.0);
                float3 c = lineSample(frame, u, k + 0.5, lod) * inside;
                float lum = dot(c, float3(0.299, 0.587, 0.114));
                float sg = U.focus * (0.85 + 0.35 * lum);                   // bright lines bloom wider
                float s2 = sg * sg + foot * foot / 12.0;                   // plus the pixel's own width
                sige = sqrt(s2);
                float d = ly - (k + 0.5);
                float w = exp(-0.5 * d * d / s2) / sqrt(6.2831853 * s2);
                acc += c * w;
                wsum += w * inside;
            }
            // A focused beam keeps its scanline modulation; a defocused one
            // is normalized, or the picture would dim as it blurs.
            acc /= mix(1.0, max(wsum, 1e-3), smoothstep(0.6, 1.2, sige));
            float2 tc = clamp(t, 0.0, 1.0);
            float2 outside = max(abs(t - 0.5) - 0.5, 0.0) * FRAME;
            float3 halo = (0.10 * frameAt(frame, tc, 3.0) + 0.05 * frameAt(frame, tc, 5.0)) * exp(-length(outside) / 5.0);
            pic = (acc + halo) / 1.15;                                     // a flat field lands on the reference color
            // Shadow mask: only when there are pixels enough to show it.
            float triad = 1.12 * U.px;
            float mstr = 0.22 * smoothstep(2.5, 6.0, triad);
            float ph = fmod(floor(in.position.x / (triad / 3.0)), 3.0);
            float3 stripe = float3(ph == 0.0 ? 1.0 : 0.0, ph == 1.0 ? 1.0 : 0.0, ph == 2.0 ? 1.0 : 0.0);
            pic *= 1.0 + mstr * (stripe - 1.0 / 3.0);
            pic *= 1.0 - 0.08 * smoothstep(0.4, 1.6, dot(p, p));
            pic *= 1.0 + 0.03 * (hash(in.position.xy + U.seed) - 0.5);
        }
    } else {
        // The picture folded into a line, then a dot.
        float2 w = max(U.scale * RASTER, 1.4 * aa / U.glassHalf);
        float kx = mix(2.0, 6.0, smoothstep(0.0, 0.1, U.scale.x));
        float env = exp(-0.5 * pow(abs(p.x) / w.x, kx)) * exp(-0.5 * pow(abs(p.y) / w.y, 2.0));
        pic = frameAt(frame, float2(0.5), 8.0) * env;
    }
    float3 c = pic * U.bright;
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    c += float3(max(lum - 1.0, 0.0)) * 0.8;                                // overdriven phosphor goes white

    // The glass: dark, a little lighter at the bottom, darker at the rim
    // where the tube falls away under the bezel, with the room reflected in it.
    float3 base = mix(float3(0.17, 0.175, 0.19), float3(0.26, 0.27, 0.29), clamp(p.y * 0.5 + 0.5, 0.0, 1.0));
    float rim = smoothstep(0.78, 1.0, max(abs(p.x), abs(p.y)));
    base *= 1.0 - 0.65 * rim;
    float2 h1 = (p - float2(-0.55, -0.5)) / float2(0.55, 0.42);
    float2 h2 = (p - float2(0.6, 0.75)) / float2(0.9, 0.5);
    float3 glass = base + (exp(-dot(h1, h1)) * 0.085 + exp(-dot(h2, h2)) * 0.03) * float3(0.95, 0.97, 1.0);
    float3 color = c + glass * U.ambient;

    // Light spilling onto the bezel around the glass.
    float3 avg = frameAt(frame, float2(0.5), 8.0) * U.bright * (U.collapse > 0.5 ? 0.15 : 1.0);
    float spill = 0.5 * dot(avg, float3(0.299, 0.587, 0.114)) * exp(-max(sd, 0.0) / 12.0);
    float alpha = max(inGlass, min(spill, 1.0));
    color = mix(avg, color, inGlass);
    return float4(color * alpha, alpha);
}
