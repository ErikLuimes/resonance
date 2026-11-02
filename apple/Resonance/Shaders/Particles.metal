#include <metal_stdlib>
using namespace metal;

// The Particle sphere (ParticlesView.swift): points spread evenly over a
// sphere, a third of them per voice, displaced here every frame from each
// voice's state (ParticleSphere.swift). A voice's points ripple with its
// envelope at a rate set by its note, noise jitters them, and every note
// start sends a wave across the sphere from the voice's own pole. Each
// point eases toward where that puts it (particleSettle), so note changes,
// new waves and noise never make it jump. The sphere turns, is projected in
// perspective, and the points are drawn as soft dots, added together.

struct ParticlePoint {
    float4 position; // x, y, z on the unit sphere; w: latitude
    float4 info;     // x: angle from its voice's pole; y: random 0-1; z: voice
};

struct ParticleVoice {
    float4 state;    // x: level 0-1; y: ripple frequency; z: seconds since the last note; w: 1 for noise
    float4 color;
};

struct ParticleUniforms {
    float2 size;     // drawable, pixels
    float time;
    float noiseFrame;
    float2 rotation; // about y, then x
    float radius;    // pixels
    float pointScale;
    float alphaScale;
    float follow;    // how far each point eases toward its target this frame, 0-1
    ParticleVoice voices[3];
};

struct ParticleOut {
    float4 position [[position]];
    float size [[point_size]];
    float4 color;
};

static float hash(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453);
}

// How far a point should sit off the unit sphere right now.
static float displacement(ParticlePoint p, constant ParticleUniforms &u) {
    int vi = int(p.info.z);
    float4 state = u.voices[vi].state;
    float level = state.x;
    float since = state.z;

    float d = level * 0.12 * sin(state.y * p.position.w * 3.0 + u.time * (1.5 + float(vi) * 0.7));
    if (state.w > 0.5) {
        d += level * (hash(float2(fmod(u.noiseFrame, 997.0), p.info.y * 1000.0)) - 0.5) * 0.25;
    }
    float w = p.info.x - since * 2.4;
    d += exp(-(w * w) / 0.035) * 0.32 * exp(-since * 1.4);
    return d;
}

// Eases every point's displacement toward its target, once per frame.
kernel void particleSettle(uint id [[thread_position_in_grid]],
                           device const ParticlePoint *points [[buffer(0)]],
                           constant ParticleUniforms &u [[buffer(1)]],
                           device float *offsets [[buffer(2)]],
                           constant uint &count [[buffer(3)]]) {
    if (id >= count) return;
    float target = displacement(points[id], u);
    offsets[id] += (target - offsets[id]) * u.follow;
}

vertex ParticleOut particleVertex(uint id [[vertex_id]],
                                  device const ParticlePoint *points [[buffer(0)]],
                                  constant ParticleUniforms &u [[buffer(1)]],
                                  device const float *offsets [[buffer(2)]]) {
    ParticlePoint p = points[id];
    int vi = int(p.info.z);
    float level = u.voices[vi].state.x;
    float d = offsets[id];

    float3 q = p.position.xyz * u.radius * (1.0 + d);
    float cy = cos(u.rotation.x), sy = sin(u.rotation.x);
    float cx = cos(u.rotation.y), sx = sin(u.rotation.y);
    float x1 = q.x * cy + q.z * sy, z1 = -q.x * sy + q.z * cy;
    float y2 = q.y * cx - z1 * sx, z2 = q.y * sx + z1 * cx;

    float camera = u.radius * 3.4;
    float scale = camera / (camera + z2);
    float2 pixel = u.size * 0.5 + float2(x1, y2) * scale;
    float depth = (1.0 - z2 / u.radius) * 0.5;
    float alpha = clamp(0.12 + depth * 0.55 + level * 0.45 * depth, 0.06, 1.0) * u.alphaScale;

    ParticleOut out;
    out.position = float4(pixel / u.size * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0);
    out.size = (0.7 + depth * 1.6 + level * 0.8) * u.pointScale;
    out.color = float4(u.voices[vi].color.rgb * alpha, alpha);
    return out;
}

fragment float4 particleFragment(ParticleOut in [[stage_in]], float2 coord [[point_coord]]) {
    float r = length(coord - 0.5) * 2.0;
    float edge = 1.0 - smoothstep(0.6, 1.0, r);
    return in.color * edge;
}
