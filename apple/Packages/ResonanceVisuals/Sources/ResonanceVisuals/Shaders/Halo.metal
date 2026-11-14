#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The Halo (HaloView.swift): three glowing rings around the center, one per
// voice. `radii` holds each ring's radius at 256 angles from -pi, voice after
// voice, in units of half the view's shorter side (HaloShape.swift);
// `levels` each voice's envelope. Every pixel looks up its angle in each
// ring and adds a thin line, a soft glow and a faint fill in that voice's
// color.
[[ stitchable ]] half4 halo(float2 position, half4 color, float2 size,
                            device const float *radii, int radiusCount,
                            device const float *levels, int levelCount,
                            half4 color0, half4 color1, half4 color2) {
    const int samples = 256;
    float scale = min(size.x, size.y) * 0.5;
    float2 p = (position - size * 0.5) / scale;
    float r = length(p);
    float u = (atan2(p.y, p.x) / (2.0 * M_PI_F) + 0.5) * float(samples);
    int i0 = int(floor(u)) % samples;
    int i1 = (i0 + 1) % samples;
    float f = fract(u);
    float pixel = 1.0 / scale;

    half4 colors[3] = { color0, color1, color2 };
    half3 rgb = half3(0.02, 0.02, 0.024);
    for (int v = 0; v < 3 && (v + 1) * samples <= radiusCount && v < levelCount; v++) {
        float ring = mix(radii[v * samples + i0], radii[v * samples + i1], f);
        float level = levels[v];
        float d = r - ring;
        float x = abs(d) / (1.1 * pixel);
        float line = exp(-x * x) * (0.35 + level * 0.65);
        float glow = exp(-abs(d) / (0.03 + level * 0.03)) * (0.16 + level * 0.34);
        // Inside the ring, strongest near its edge.
        float fill = d < 0.0 ? smoothstep(0.0, ring, r) * (0.05 + level * 0.12) : 0.0;
        rgb += colors[v].rgb * half(line + glow + fill);
    }
    return half4(min(rgb, half3(1.0)), 1.0);
}
