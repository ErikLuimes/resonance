#include <metal_stdlib>
using namespace metal;

// The Rasters visualizer (RasterRenderer.swift): a C64 demo's screen. It's
// drawn on the C64's own grid, 384 × 272 with the border, every pixel a
// square block, a line at a time as the video chip did: copper bars the
// full width of the screen and its border, stars drifting behind, and a
// scroller riding a sine wave. Each pixel of the view is the average of
// four samples of that grid, so the blocks have clean edges at any size;
// then a tube's scanlines and a little vignette. Composited with bloom by
// Notes.metal.

struct RasterUniforms {
    float2 size;       // drawable, pixels
    float time;
    float flash;       // the border's flash on a drum, 0–1
    float scroll;      // how far the scroller has moved, in C64 pixels
    float text_width;  // the scroller's text, in C64 pixels
    float dim;         // how bright the C64's own blues are
    float bar_count;
    float4 status;     // x: the status line's width, in C64 pixels
    float4 colors[3];
    float4 bars[18];   // x: line; y: half height, in lines; z: brightness; w: voice
};

struct RasterOut {
    float4 position [[position]];
};

vertex RasterOut rasterVertex(uint vid [[vertex_id]]) {
    RasterOut out;
    out.position = float4(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0, 0.0, 1.0);
    return out;
}

constant float2 rasterGrid = float2(384.0, 272.0);
// The screen inside the border: 320 × 200.
constant float2 rasterScreenFrom = float2(32.0, 36.0);
constant float2 rasterScreenTo = float2(352.0, 236.0);
// The C64's blue and light blue.
constant float3 rasterBlue = float3(0.208, 0.157, 0.475);
constant float3 rasterLightBlue = float3(0.424, 0.369, 0.71);

static float rasterHash(float n) {
    return fract(sin(n * 127.1) * 43758.5453);
}

// The color of one C64 pixel.
static float3 rasterPixel(float2 cell, constant RasterUniforms &u, texture2d<float> text, texture2d<float> status) {
    bool on_screen = cell.x >= rasterScreenFrom.x && cell.x < rasterScreenTo.x
        && cell.y >= rasterScreenFrom.y && cell.y < rasterScreenTo.y;
    float3 color = on_screen ? rasterBlue * u.dim : mix(rasterLightBlue * u.dim, float3(1.0), u.flash * 0.6);

    // Stars, on the screen only: a row has one or none, drifting left at
    // its own speed.
    if (on_screen) {
        float pick = rasterHash(cell.y);
        if (pick < 0.3) {
            float speed = 14.0 + 70.0 * rasterHash(cell.y + 31.0);
            float x = fmod(rasterHash(cell.y + 7.0) * 320.0 + 320.0 - fmod(u.time * speed, 320.0), 320.0);
            if (floor(x) == cell.x - rasterScreenFrom.x) {
                color = float3(0.35 + 0.6 * (speed - 14.0) / 70.0);
            }
        }
    }

    // Copper bars: whole lines, border and all, shaded in five steps to a
    // bright middle. Later bars are in front.
    int count = int(u.bar_count);
    for (int i = 0; i < count; i++) {
        float4 bar = u.bars[i];
        float from_middle = abs(cell.y + 0.5 - bar.x) / max(bar.y, 0.5);
        if (from_middle < 1.0 && bar.z > 0.01) {
            float step = floor((1.0 - from_middle) * 5.0);
            float shade = 0.16 + 0.21 * step;
            float3 tint = u.colors[int(bar.w)].rgb;
            float3 lit = tint * shade + float3(step >= 4.0 ? 0.35 : 0.0);
            color = mix(color, lit, bar.z);
        }
    }

    // The status line at the top of the screen, as a C64 prints: what each
    // voice is playing, in light blue.
    if (on_screen) {
        float2 at = cell - (rasterScreenFrom + float2(8.0, 8.0));
        if (at.y >= 0.0 && at.y < 16.0 && at.x >= 0.0 && at.x < u.status.x
            && status.read(uint2(uint(at.x), uint(at.y))).r > 0.5) {
            color = rasterLightBlue * 1.5;
        }
    }

    // The scroller: 16 lines tall, riding a sine wave, in front of it all.
    if (on_screen && u.text_width > 0.0) {
        float wave = floor(204.0 + sin(cell.x * 0.045 + u.time * 2.6) * 9.0);
        float row = cell.y - (wave - 8.0);
        if (row >= 0.0 && row < 16.0) {
            float column = fmod(cell.x - rasterScreenFrom.x + u.scroll, u.text_width);
            if (text.read(uint2(uint(column), uint(row))).r > 0.5) {
                // Lit from above: brighter at the top of each letter.
                color = mix(float3(1.0), float3(0.72, 0.8, 1.0), row / 16.0);
            } else if (row > 0.0 && column > 0.0
                       && text.read(uint2(uint(column - 1.0), uint(row - 1.0))).r > 0.5) {
                // A one-pixel shadow.
                color *= 0.35;
            }
        }
    }
    return color;
}

fragment float4 rasterFragment(RasterOut in [[stage_in]], constant RasterUniforms &u [[buffer(0)]],
                               texture2d<float> text [[texture(0)]], texture2d<float> status [[texture(1)]]) {
    // The grid fills the view's height; a wide view just has more border.
    float per_pixel = rasterGrid.y / u.size.y;
    float3 color = float3(0.0);
    for (int i = 0; i < 4; i++) {
        float2 offset = float2(i & 1, i >> 1) * 0.5 - 0.25;
        float2 at = in.position.xy + offset;
        float2 cell = float2((at.x - u.size.x * 0.5) * per_pixel + rasterGrid.x * 0.5, at.y * per_pixel);
        color += rasterPixel(floor(cell), u, text, status);
    }
    color *= 0.25;

    // A tube: each line a little darker at its edges, and the corners dimmer.
    float line = fract(in.position.y * per_pixel);
    color *= 0.86 + 0.14 * sin(line * 3.14159265);
    float2 from_center = in.position.xy / u.size - 0.5;
    color *= 1.0 - 0.55 * dot(from_center, from_center);
    return float4(color, 1.0);
}
