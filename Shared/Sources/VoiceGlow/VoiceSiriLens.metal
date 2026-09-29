#include <metal_stdlib>
using namespace metal;

// Voice light for the suggestion ribbon, in the iOS 27 Siri language: vivid lobes
// of light that swell above and below a fine horizon with the voice, adding to
// white where they cross. There is no container: the light is drawn straight onto
// the keyboard's own background and fills the ribbon's free space, fading out at
// both ends.
//
// Everything is analytic per pixel (a handful of smooth bumps), so it needs no
// textures and costs a fraction of a millisecond.

struct LensUniforms {
    float2 size;        // drawable size in pixels
    float  scale;       // pixels per point
    float  time;        // seconds
    float  level;       // smoothed loudness 0...1
    float  dark;        // 1 in dark mode, 0 in light mode
    float  mode;        // 0 live, 1 waiting, 2 finishing
    float  appear;      // 0...1 entrance
    float4 bandsA;      // spectrum, low to high
    float4 bandsB;
    float4 bandsC;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut lensVertex(uint vid [[vertex_id]]) {
    // One triangle that covers the whole target.
    float2 positions[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    VertexOut out;
    out.position = float4(positions[vid], 0, 1);
    out.uv = positions[vid] * 0.5 + 0.5;
    return out;
}

static float bandAt(constant LensUniforms &u, float x) {
    // x in 0...1 from the centre outward; lows in the middle.
    float bands[12] = { u.bandsA.x, u.bandsA.y, u.bandsA.z, u.bandsA.w,
                        u.bandsB.x, u.bandsB.y, u.bandsB.z, u.bandsB.w,
                        u.bandsC.x, u.bandsC.y, u.bandsC.z, u.bandsC.w };
    float f = clamp(x, 0.0, 1.0) * 11.0;
    int i = int(floor(f));
    int j = min(i + 1, 11);
    return mix(bands[i], bands[j], smoothstep(0.0, 1.0, f - float(i)));
}

fragment float4 lensFragment(VertexOut in [[stage_in]], constant LensUniforms &u [[buffer(0)]]) {
    float2 px = float2(in.uv.x, 1.0 - in.uv.y) * u.size;   // top-left origin, pixels
    float2 center = u.size * 0.5;
    float2 p = px - center;
    float aa = 1.0;

    // Across the ribbon, -1...1, fading softly at both ends.
    float x = p.x / center.x;
    float envelope = smoothstep(1.0, 0.55, abs(x));
    float y = -p.y;                                   // up is positive, 0 at the horizon
    // Tallest a lobe may grow. Kept well inside the ribbon: its bottom edge sits
    // right on the top row of keys, so light reaching it read as spilling onto them.
    float H = center.y * 0.62;
    // And anything near the top or bottom edge fades out rather than stopping hard.
    float vertical = smoothstep(center.y * 0.95, center.y * 0.60, abs(y));

    float live = u.mode < 0.5 ? 1.0 : 0.0;
    float waiting = (u.mode > 0.5 && u.mode < 1.5) ? 1.0 : 0.0;
    float finishing = u.mode > 1.5 ? 1.0 : 0.0;

    // Broad lobes that wander the ribbon and overlap one another, alternating
    // above and below the horizon; the crossings are what read as light. Each
    // drifts on its own slow clock so the shape never repeats.
    const int count = 7;
    float3 colors[count] = {
        float3(1.00, 0.23, 0.19),   // red
        float3(0.04, 0.52, 1.00),   // blue
        float3(1.00, 0.62, 0.04),   // orange
        float3(0.75, 0.33, 0.97),   // violet
        float3(0.20, 0.84, 0.29),   // green
        float3(0.35, 0.85, 1.00),   // cyan
        float3(1.00, 0.18, 0.55)    // magenta
    };
    float3 light = float3(0);
    float presence = 0;                               // how much light is at this x
    float t = u.time;
    float voice = live * (0.10 + 1.25 * u.level) + waiting * 0.05 + finishing * 0.04;
    for (int i = 0; i < count; i++) {
        float fi = float(i);
        float side = (i % 2 == 0) ? 1.0 : -1.0;
        // Home positions spaced along the ribbon, each wandering around its own.
        float home = -0.50 + 1.00 * fi / float(count - 1);
        float c = home + 0.30 * sin(t * (0.41 + 0.08 * fi) + fi * 1.9);
        float w = 0.34 + 0.12 * sin(t * (0.57 + 0.07 * fi) + fi * 0.7);
        float wobble = 0.50 + 0.50 * sin(t * (1.7 + 0.21 * fi) + fi * 2.3);
        float band = bandAt(u, abs(c));
        float amp = min(H, H * voice * (0.35 + 0.65 * wobble) * (1.0 + 1.2 * band));
        float z = (x - c) / w;
        float bump = max(0.0, 1.0 - z * z);
        bump *= bump;
        float top = amp * bump * envelope;
        float yy = y * side;                             // distance on this lobe's side
        // A lobe with no height contributes nothing (edge smoothing alone left every
        // lobe a one-pixel sliver on the horizon, which summed into a standing line).
        float exists = smoothstep(0.0, 1.5 * u.scale, top);
        float body = smoothstep(-aa, aa, top - yy) * smoothstep(-aa, aa, yy) * exists;
        // Brighter toward the lobe's edge, as light gathers at the rim of the wave.
        float k = top > 0.5 ? clamp(yy / top, 0.0, 1.0) : 0.0;
        float intensity = body * mix(0.55, 1.35, k * k);
        float halo = exp(-max(0.0, yy - top) / (3.0 * u.scale)) * step(0.0, yy) * bump * envelope * 0.5 * exists;
        light += colors[i] * (intensity + halo);
        presence += bump * envelope * clamp(amp / H, 0.0, 1.0);
    }

    // Horizon: a hairline that glints only under the light, never a standing line.
    // While waiting or finishing, a short soft shimmer at the centre is the only
    // sign of life.
    float line = exp(-(y * y) / (0.45 * u.scale * u.scale));
    float shimmer = 0.6 + 0.4 * sin(t * 3.0 - x * 7.0);
    float centre = exp(-(x * x) / 0.08);
    float lineStrength = live * 0.9 * clamp(presence, 0.0, 1.0)
                       + (waiting * 0.25 + finishing * 0.55) * shimmer * centre;
    light += float3(0.95, 0.97, 1.0) * line * lineStrength;
    light *= vertical;

    float peak = max(light.r, max(light.g, light.b));
    float coverage = 1.0 - exp(-peak * 2.1);
    float3 rgb;
    if (u.dark > 0.5) {
        // Dark keyboard: light adds, and crossings burn toward white.
        rgb = 1.0 - exp(-light * 2.1);
    } else {
        // Light keyboard: white would vanish into the background, so keep the hue
        // saturated, and keep it translucent so crossings still show both colours.
        float3 hue = light / max(peak, 1e-3);
        float veil = (1.0 - exp(-peak * 1.3)) * 0.82;
        rgb = hue * veil;
        coverage = veil;
    }
    float alpha = u.dark > 0.5 ? max(rgb.r, max(rgb.g, rgb.b)) : coverage;
    return float4(rgb, clamp(alpha, 0.0, 1.0)) * u.appear;
}
