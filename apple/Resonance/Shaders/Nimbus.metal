#include <metal_stdlib>
using namespace metal;

// The Nimbus visualizer (NimbusRenderer.swift): cloud metaballs in a pale
// morning sky, lit by the low sun and, from inside, by the music. Six
// soft balls of cloud, two a voice, drift round each other and run
// together where they meet. A voice's pair swells with its level and
// jumps on every new note, rides higher the higher it plays, and glows
// from within in the voice's color; and they all drift and churn faster
// the louder the music is.
//
// The cloud is a volume, not a surface: each pixel's line of sight is
// walked through it in steps, and at every step some light is added and
// some of what's behind is hidden, by how thick the cloud is there. How
// thick comes from a block of noise, read at four scales, drifting. The
// idea of a slowly turning cloud at sunset is after dathor's
// "Metamorphosis Volume" on Shadertoy; none of its code is here.
// Composited with bloom by Notes.metal.

struct NimbusUniforms {
    float4 eye;
    float4 right;      // w: time
    float4 up;
    float4 forward;    // w: focal length, pixels
    float4 view;       // xy: size, pixels; z: steps through the cloud; w: all three voices' level
    float4 colors[3];  // rgb: a voice's color; a: how brightly its billow glows
    float4 swell;      // xyz: how far each billow has swollen, 0–1 and a little over; w: how far the cloud has churned
    float4 lift;       // xyz: how far each billow has risen with its voice's pitch, −1…1
    float4 balls[6];   // xyz: where each ball of cloud is; w: how far it reaches
    float4 tails[6];   // xyz: where it was a moment ago: its smoke trails back to there
};

struct NimbusOut {
    float4 position [[position]];
};

vertex NimbusOut nimbusVertex(uint vid [[vertex_id]]) {
    NimbusOut out;
    out.position = float4(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0, 0.0, 1.0);
    return out;
}

// The ball that holds the whole cloud, and where the sun is.
constant float3 nimbusMiddle = float3(0.0, 0.0, 0.0);
constant float nimbusReach = 5.6;
constant float3 nimbusSun = float3(-0.58, 0.16, -0.80);

constexpr sampler nimbusSampler(filter::linear, address::repeat);

// Smooth noise, about one feature a unit: the block's values, eased
// between its points so they don't show as facets.
static float nimbusNoise(texture3d<float> noise, float3 p) {
    float3 whole = floor(p), part = p - whole;
    part = part * part * (3.0 - 2.0 * part);
    return noise.sample(nimbusSampler, (whole + part + 0.5) / 64.0, level(0)).r;
}

// The cloud is metaballs: six soft balls of smoke, two a voice, that
// roam round each other (NimbusVoices.balls), parting and meeting, and
// run together where they come near, as blobs of liquid do. Each leaves
// a tail of smoke back along the way it came.
//
// How thick the cloud is at `p`, 0 where there's none. `fine` reads the
// noise at all four scales; without it, two, for the light. `inside` is
// how deep `p` is in each voice's balls.
static float nimbusDensity(texture3d<float> noise, float3 p, constant NimbusUniforms &u, bool fine, thread float3 &inside) {
    // Each ball pulls on what's within its reach, most at its middle and
    // not at all at its edge; where the pulls add up to enough, there's
    // cloud. Two that come near add up between them: that's the bridge
    // that forms as they join. The reach is measured from the nearest
    // point of the ball's tail, which thins toward its end.
    float pull = 0.0, alone = 0.0;
    inside = float3(0.0);
    for (int i = 0; i < 6; i++) {
        float3 head = u.balls[i].xyz, back = u.tails[i].xyz - head;
        // Nowhere near this one: most of the sky is nowhere near any.
        float3 off = p - (head + back * 0.5);
        float far = u.balls[i].w + length(back) * 0.5;
        if (dot(off, off) > far * far) { continue; }
        float along = saturate(dot(p - head, back) / max(dot(back, back), 1e-4));
        float3 to = p - (head + back * along);
        float reach = u.balls[i].w * (1.0 - 0.55 * along);
        float near = saturate(1.0 - dot(to, to) / (reach * reach));
        float here = near * near * near * (1.0 - 0.6 * along);
        pull += here;
        alone = max(alone, here);
        inside[i % 3] += here;
    }
    // Thin at a ball's edge and thick only deep inside, so the noise has
    // an edge to fray into wisps: smoke, not putty.
    float shape = saturate(pull * 1.05);
    shape = shape * (0.5 + 0.5 * shape);
    // How much of what's here is two balls at once: where they meet.
    float meeting = saturate((pull - alone) * 2.5);
    if (shape <= 0.0) { return 0.0; }
    // The noise drifts and is itself pushed about by slower noise, which
    // draws it out into wisps and hollows. How far it has drifted is the
    // music's doing: it churns on faster the louder it is.
    float t = u.swell.w;
    float3 q = p + float3(0.0, -t * 0.09, t * 0.04);
    // Where two balls meet they stir each other up: the push is stronger
    // there, and the smoke curls.
    q += (float3(nimbusNoise(noise, q * 0.8 + 11.0), nimbusNoise(noise, q * 0.8 + 23.0), nimbusNoise(noise, q * 0.8 + 37.0)) - 0.5)
        * (1.3 + 2.2 * meeting);
    float billows = nimbusNoise(noise, q * 1.1) * 0.5 + nimbusNoise(noise, q * 2.6 + 3.7) * 0.27;
    if (fine) {
        billows += nimbusNoise(noise, q * 5.9 + float3(0.0, t * 0.07, 7.1)) * 0.17 + nimbusNoise(noise, q * 12.5) * 0.09;
    } else {
        billows += 0.115;
    }
    // The noise eats into the shape from its edge: where the shape is
    // thin, only the noise's peaks are cloud.
    return saturate((shape * 1.7 - (1.0 - billows) * 1.5) * 5.0);
}

// A pale morning sky: warm and hazy at the horizon, soft blue above and
// below, the sun low in it.
static float3 nimbusSky(float3 ray) {
    float up = abs(ray.y);
    float3 sky = mix(float3(1.0, 0.86, 0.72), float3(0.56, 0.68, 0.86), pow(saturate(up), 0.5));
    // Below the horizon it's the same haze, a little grayer.
    sky = mix(sky, float3(0.62, 0.64, 0.7), ray.y < 0.0 ? saturate(-ray.y * 1.4) : 0.0);
    float toward = saturate(dot(ray, normalize(nimbusSun)));
    sky += float3(1.0, 0.85, 0.6) * (pow(toward, 420.0) * 3.0 + pow(toward, 24.0) * 0.35 + pow(toward, 4.0) * 0.12);
    return sky * 0.8;
}

// Walks `ray` through the cloud. Returns its light in rgb, and in a how
// much of what's behind it still shows.
static float4 nimbusMarch(texture3d<float> noise, float3 origin, float3 ray, int steps, bool fine, float jitter,
                          constant NimbusUniforms &u) {
    float3 to = origin - nimbusMiddle;
    float b = dot(to, ray), c = dot(to, to) - nimbusReach * nimbusReach;
    float h = b * b - c;
    if (h < 0.0) { return float4(0.0, 0.0, 0.0, 1.0); }
    h = sqrt(h);
    float near = max(-b - h, 0.0), far = -b + h;
    if (far <= near) { return float4(0.0, 0.0, 0.0, 1.0); }
    float step = (far - near) / float(steps);
    float3 sun = normalize(nimbusSun);
    float toward = dot(ray, sun);
    // Looking toward the sun, a cloud's edges shine: light scatters forward.
    float forward = 0.55 + 0.9 * pow(saturate(toward * 0.5 + 0.5), 5.0);
    float3 light = float3(0.0);
    float shows = 1.0;
    float t = near + step * jitter;
    for (int i = 0; i < steps && shows > 0.02; i++, t += step) {
        float3 p = origin + ray * t;
        float3 inside;
        float density = nimbusDensity(noise, p, u, fine, inside);
        if (density < 0.004) { continue; }
        // How much sun gets here: a few looks toward it through the cloud.
        float shade = 0.0;
        float3 unused;
        int looks = fine ? 3 : 1;
        for (int k = 1; k <= looks; k++) {
            shade += nimbusDensity(noise, p + sun * (0.3 * float(k) * float(k) * 0.5 + 0.12), u, false, unused);
        }
        float sunlit = exp(-shade * (fine ? 1.4 : 3.0));
        // White where the sun reaches, blue-gray in its own shade.
        float3 color = float3(1.0, 0.93, 0.82) * sunlit * forward * 1.05
            + float3(0.3, 0.34, 0.44) * (0.6 + 0.4 * saturate(p.y * 0.4 + 0.5));
        // Each voice's balls take its color, more the louder it is: on
        // a pale sky a glow wouldn't show, so it's the cloud itself
        // that's colored.
        float3 share = inside / max(inside.x + inside.y + inside.z, 1e-3);
        float3 tint = u.colors[0].rgb * share.x + u.colors[1].rgb * share.y + u.colors[2].rgb * share.z;
        float strength = saturate(u.colors[0].a * share.x + u.colors[1].a * share.y + u.colors[2].a * share.z);
        color *= mix(float3(1.0), tint * 1.15 + 0.12, 0.25 + 0.6 * strength);
        color += tint * strength * 0.25;
        // Thin enough to see into: smoke.
        float hides = 1.0 - exp(-density * step * 4.2);
        light += color * hides * shows;
        shows *= 1.0 - hides;
    }
    return float4(light, shows);
}

fragment float4 nimbusFragment(NimbusOut in [[stage_in]], constant NimbusUniforms &u [[buffer(0)]],
                               texture3d<float> noise [[texture(0)]]) {
    float2 pixel = in.position.xy - u.view.xy * 0.5;
    float3 origin = u.eye.xyz;
    float3 ray = normalize(u.forward.xyz * u.forward.w + u.right.xyz * pixel.x - u.up.xyz * pixel.y);
    int steps = clamp(int(u.view.z), 16, 96);
    // Each pixel starts its walk a little differently, so the steps
    // don't show as bands.
    float jitter = fract(sin(dot(in.position.xy, float2(12.9898, 78.233))) * 43758.5453);

    float4 cloud = nimbusMarch(noise, origin, ray, steps, true, jitter, u);
    // Bright parts roll off toward white instead of clipping to it.
    float3 color = 1.0 - exp(-(cloud.rgb + nimbusSky(ray) * cloud.a) * 1.25);

    float2 from_center = in.position.xy / u.view.xy - 0.5;
    color *= 1.0 - 0.7 * dot(from_center, from_center);
    return float4(color, 1.0);
}
