#include <metal_stdlib>
using namespace metal;

// The Terrain visualizer (TerrainRenderer.swift): the spectrum as a
// landscape. Frequency runs left to right, time runs away from you, and
// the height is how loud each band is. The CPU keeps the last rows of the
// spectrum in a texture, a ring it writes one row of at a time; this
// builds the mesh from it (no vertex buffer: every vertex works out its
// own place from its number), fills it dark so near ridges hide far ones,
// and draws a bright line along every row in the color of whichever voices
// sound there. The scene is composited with bloom by Notes.metal.

struct TerrainUniforms {
    float4x4 view_projection;
    float4 color0;     // the voices' colors
    float4 color1;
    float4 color2;
    float4 background; // rgb: what the fill is tinted with
    float4 grid;       // x: columns; y: rows; z: the newest row in the texture; w: how far to the next row, 0–1
    float4 shape;      // x: width; y: depth; z: height; w: pixels per point
};

struct TerrainOut {
    float4 position [[position]];
    float3 levels;
    float row;    // whole on each row of the mesh
    float column;
    float height; // 0–1
    float away;   // 0 at the front, 1 at the back
};

constant uint2 terrainCorners[6] = { uint2(0, 0), uint2(1, 0), uint2(0, 1), uint2(1, 0), uint2(1, 1), uint2(0, 1) };

vertex TerrainOut terrainVertex(uint vid [[vertex_id]],
                                texture2d<float> history [[texture(0)]],
                                constant TerrainUniforms &u [[buffer(0)]]) {
    uint columns = uint(u.grid.x), rows = uint(u.grid.y);
    uint cell = vid / 6;
    uint2 corner = terrainCorners[vid % 6];
    uint column = cell % (columns - 1) + corner.x;
    uint row = cell / (columns - 1) + corner.y;

    // Row 0 is the spectrum right now, at the front; the rows behind it
    // slide away smoothly between one being added and the next.
    uint newest = uint(u.grid.z);
    float3 levels = history.read(uint2(column, (newest + rows - row) % rows)).rgb;
    float behind = row == 0 ? 0.0 : float(row) - 1.0 + u.grid.w;
    float away = behind / float(rows - 1);

    // The voices together: any one loud is loud.
    float height = 1.0 - (1.0 - levels.r) * (1.0 - levels.g) * (1.0 - levels.b);
    // Only what's well above the scale's floor rises, so peaks stand out
    // from flat ground, and the land sinks flat toward the back.
    height = pow(saturate((height - 0.3) / 0.7), 1.7) * (1.0 - smoothstep(0.7, 1.0, away));

    float x = (float(column) / float(columns - 1) - 0.5) * u.shape.x;
    TerrainOut out;
    out.position = u.view_projection * float4(x, height * u.shape.z, -away * u.shape.y, 1.0);
    out.levels = levels;
    out.row = float(row);
    out.column = float(column);
    out.height = height;
    out.away = away;
    return out;
}

fragment float4 terrainFragment(TerrainOut in [[stage_in]],
                                constant TerrainUniforms &u [[buffer(0)]]) {
    // The color of whichever voices sound here.
    float3 weight = in.levels * in.levels;
    float sum = weight.r + weight.g + weight.b;
    float3 tint = sum > 1e-5
        ? (u.color0.rgb * weight.r + u.color1.rgb * weight.g + u.color2.rgb * weight.b) / sum
        : (u.color0.rgb + u.color1.rgb + u.color2.rgb) / 3.0;

    // A line along every row, about a point and a half wide. Where rows
    // crowd closer than that (far away), they blend into an even sheen.
    float to_row = abs(fract(in.row + 0.5) - 0.5);
    float per_pixel = max(fwidth(in.row), 1e-5);
    float half_width = 0.5 * u.shape.w;
    float line = 1.0 - smoothstep(half_width - 0.5, half_width + 0.5, to_row / per_pixel);
    float crowded = saturate(per_pixel * half_width * 2.0);
    line = mix(line, crowded, saturate((per_pixel - 0.25) * 4.0));
    // The row at the front, the spectrum now, is brighter.
    float front = 1.0 - smoothstep(0.0, 1.5, in.row);

    float fade = 1.0 - smoothstep(0.45, 1.0, in.away);
    float lit = 0.16 + 0.84 * in.height;
    float3 lines = tint * line * lit * (1.0 + front * 0.8) * 1.4 * fade;
    float3 fill = u.background.rgb + tint * in.height * in.height * 0.1 * fade;
    // Premultiplied: it thins out to nothing at the very back.
    float there = 1.0 - smoothstep(0.88, 1.0, in.away);
    return float4((fill + lines) * there, there);
}
