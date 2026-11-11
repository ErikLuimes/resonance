#include <metal_stdlib>
using namespace metal;

// The Ferrofluid visualizer (FerroRenderer.swift): a pool of black,
// glossy liquid that stands up in spikes where a magnet pulls it, as
// ferrofluid does. Each voice is a magnet under the pool. The surface is
// a height over the pool's floor, a honeycomb of spikes each as tall as
// the pull at its foot; every pixel walks its line of sight down to that
// surface and lights what it finds: black, with the room and each voice's
// colored light reflected in it. Composited with bloom by Notes.metal.

struct FerroUniforms {
    float4 camera_position; // w: how many steps each line of sight takes
    float4 camera_right;
    float4 camera_up;
    float4 camera_forward; // w: focal length, pixels
    float4 view;           // xy: size, pixels; z: the pool's radius; w: the spikes' spacing
    float4 magnets[3];     // xy: place on the floor (x, z); z: pull, 0–1; w: reach
    float4 colors[3];
};

struct FerroOut {
    float4 position [[position]];
};

vertex FerroOut ferroVertex(uint vid [[vertex_id]]) {
    FerroOut out;
    out.position = float4(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0, 0.0, 1.0);
    return out;
}

constant float ferroTallest = 0.62;

// The pull at a place on the floor, 0–1, fading out at the pool's edge.
static float ferroPull(float2 p, constant FerroUniforms &u) {
    float pull = 0.0;
    for (int i = 0; i < 3; i++) {
        float2 d = p - u.magnets[i].xy;
        pull += u.magnets[i].z * exp(-dot(d, d) / (u.magnets[i].w * u.magnets[i].w));
    }
    float radius = u.view.z;
    return min(pull, 1.15) * (1.0 - smoothstep(radius * 0.72, radius, length(p)));
}

// The surface's height at a place on the floor: the nearest spike of the
// honeycomb, as tall as the pull at its own foot, so each spike is whole.
static float ferroHeight(float2 p, constant FerroUniforms &u) {
    float s = u.view.w;
    float2 a = float2(s, 0.0), b = float2(s * 0.5, s * 0.8660254);
    float qy = p.y / b.y;
    float2 cell = floor(float2(p.x / s - qy * 0.5, qy));
    float nearest = 1e9;
    float2 foot = float2(0.0);
    for (int j = 0; j < 2; j++) {
        for (int i = 0; i < 2; i++) {
            float2 c = (cell.x + float(i)) * a + (cell.y + float(j)) * b;
            float d = distance(p, c);
            if (d < nearest) { nearest = d; foot = c; }
        }
    }
    float pull = ferroPull(foot, u);
    float k = saturate(1.0 - nearest / (s * 0.6));
    // A rounded foot and a sharp tip; a still pool is only faintly dimpled.
    float spike = pow(k, 1.5) * (0.012 + 0.4 * pull * pull + 0.07 * pull);
    return min(spike, ferroTallest);
}

fragment float4 ferroFragment(FerroOut in [[stage_in]], constant FerroUniforms &u [[buffer(0)]]) {
    float2 pixel = in.position.xy - u.view.xy * 0.5;
    float3 origin = u.camera_position.xyz;
    float3 ray = normalize(u.camera_forward.xyz * u.camera_forward.w + u.camera_right.xyz * pixel.x
                           - u.camera_up.xyz * pixel.y);
    // Looking up or level: nothing but the room.
    if (ray.y > -0.02) { return float4(0.0); }

    // From where the line of sight drops below the tallest spike to where
    // it would meet the floor, in even steps, then closing in on the hit.
    float enter = max((ferroTallest - origin.y) / ray.y, 0.0);
    float leave = -origin.y / ray.y;
    int steps = clamp(int(u.camera_position.w), 16, 96);
    float step = (leave - enter) / float(steps);
    float t = enter, before = enter;
    bool hit = false;
    for (int i = 0; i < steps; i++) {
        float3 p = origin + ray * t;
        if (p.y < ferroHeight(p.xz, u)) { hit = true; break; }
        before = t;
        t += step;
    }
    if (hit) {
        float low = before, high = t;
        for (int i = 0; i < 6; i++) {
            float middle = (low + high) * 0.5;
            float3 p = origin + ray * middle;
            if (p.y < ferroHeight(p.xz, u)) { high = middle; } else { low = middle; }
        }
        t = (low + high) * 0.5;
    } else {
        t = leave;
    }
    float3 p = origin + ray * t;
    float there = 1.0 - smoothstep(u.view.z, u.view.z * 1.1, length(p.xz));
    if (there <= 0.0) { return float4(0.0); }

    float e = 0.004;
    float h = ferroHeight(p.xz, u);
    float3 normal = normalize(float3(h - ferroHeight(p.xz + float2(e, 0), u), e,
                                     h - ferroHeight(p.xz + float2(0, e), u)));
    float3 mirrored = reflect(ray, normal);
    float facing = saturate(dot(normal, -ray));
    float glance = pow(1.0 - facing, 4.0);

    // The room in it: a soft light overhead and a thin bright horizon.
    float overhead = smoothstep(0.5, 0.98, mirrored.y) * 0.16;
    float horizon = exp(-pow((mirrored.y - 0.12) / 0.09, 2.0)) * 0.09;
    float3 color = float3(0.004) + (overhead + horizon) * (0.35 + 0.65 * glance) * float3(0.8, 0.85, 1.0);

    // Each voice's light hangs over its magnet, as bright as its pull.
    for (int i = 0; i < 3; i++) {
        float pull = u.magnets[i].z;
        float3 lamp = float3(u.magnets[i].x, 1.15, u.magnets[i].y);
        float3 toward = lamp - p;
        float far = length(toward);
        toward /= far;
        float falloff = 1.0 / (1.0 + far * far * 0.55);
        float gleam = pow(saturate(dot(mirrored, toward)), 42.0) * 3.2;
        float sheen = pow(saturate(dot(normal, toward)), 2.0) * 0.16;
        // A spike's steep sides face away from the light but glance it
        // back at you: its outline glows in the voice's color.
        float rim = glance * saturate(dot(normal, toward) + 0.6) * 0.9;
        color += u.colors[i].rgb * (gleam + sheen + rim) * falloff * (0.1 + pull);
    }
    return float4(color * there, there);
}
