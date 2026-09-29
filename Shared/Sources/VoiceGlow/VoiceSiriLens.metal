#include <metal_stdlib>
using namespace metal;

// The voice lens, after the iOS 27 Siri language: a dark liquid-glass capsule with
// an iridescent rim and a fine horizon line, and vivid lobes of light that swell
// above and below the horizon with the voice. Lobes add together, so where they
// overlap the light runs white-hot.
//
// Everything is analytic per pixel (a capsule distance field and a handful of
// smooth bumps), so it needs no textures and costs a fraction of a millisecond.

struct LensUniforms {
    float2 size;        // drawable size in pixels
    float  scale;       // pixels per point
    float  time;        // seconds
    float  level;       // smoothed loudness 0...1
    float  energy;      // slower speech-presence envelope 0...1
    float  mode;        // 0 live, 1 waiting, 2 finishing
    float  appear;      // 0...1 entrance / exit
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

static float capsuleSDF(float2 p, float2 halfSize) {
    float r = halfSize.y;
    float2 q = abs(p) - float2(halfSize.x - r, 0);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static float3 hueColor(float h) {
    // A saturated spectrum without the muddy midpoints of plain HSV.
    float3 k = float3(0.0, 2.0 / 3.0, 1.0 / 3.0);
    return clamp(abs(fract(h + k) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
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

    // Capsule, shrunk by a pixel so the rim antialiases inside the target.
    float2 halfSize = center - float2(1.5, 1.5);
    float d = capsuleSDF(p, halfSize);
    float inside = smoothstep(aa, -aa, d);
    if (d > 3.0 * u.scale) { return float4(0); }

    // Glass: near-black, a touch lighter toward the bottom, like the island lens.
    float vy = px.y / u.size.y;
    float3 glass = mix(float3(0.015, 0.015, 0.02), float3(0.07, 0.07, 0.085), vy);
    float glassAlpha = mix(0.985, 0.95, vy);

    // Horizontal coordinate across the usable width, -1...1.
    float span = halfSize.x - halfSize.y * 0.55;
    float x = p.x / span;
    float envelope = smoothstep(1.0, 0.55, abs(x));
    float y = -p.y;                                   // up is positive, 0 at the horizon
    float H = halfSize.y * 0.92;                      // tallest a lobe may grow

    float live = u.mode < 0.5 ? 1.0 : 0.0;
    float waiting = (u.mode > 0.5 && u.mode < 1.5) ? 1.0 : 0.0;
    float finishing = u.mode > 1.5 ? 1.0 : 0.0;

    // Six lobes, alternating above and below the horizon, each drifting on its own
    // slow clock so the shape never visibly repeats.
    float3 colors[6] = {
        float3(1.00, 0.23, 0.19),   // red
        float3(1.00, 0.62, 0.04),   // orange
        float3(0.20, 0.84, 0.29),   // green
        float3(0.04, 0.52, 1.00),   // blue
        float3(0.35, 0.85, 1.00),   // cyan
        float3(0.75, 0.33, 0.97)    // violet
    };
    float3 light = float3(0);
    float t = u.time;
    float voice = live * (0.10 + 0.90 * u.level) + waiting * 0.06 + finishing * 0.05;
    for (int i = 0; i < 6; i++) {
        float fi = float(i);
        float side = (i % 2 == 0) ? 1.0 : -1.0;
        float c = 0.42 * sin(t * (0.53 + 0.11 * fi) + fi * 1.9);
        float w = 0.42 + 0.16 * sin(t * (0.71 + 0.07 * fi) + fi * 0.7);
        float wobble = 0.55 + 0.45 * sin(t * (1.9 + 0.23 * fi) + fi * 2.3);
        float band = bandAt(u, abs(c));
        float amp = H * voice * wobble * (0.65 + 0.7 * band);
        float z = (x - c) / w;
        float bump = max(0.0, 1.0 - z * z);
        bump *= bump;
        float top = amp * bump * envelope;
        float yy = y * side;                             // distance on this lobe's side
        float body = smoothstep(-aa, aa, top - yy) * smoothstep(-aa, aa, yy);
        // Brighter toward the lobe's edge, as light gathers at the rim of the wave.
        float k = top > 0.5 ? clamp(yy / top, 0.0, 1.0) : 0.0;
        float intensity = body * mix(0.80, 1.45, k * k);
        float halo = exp(-max(0.0, yy - top) / (3.0 * u.scale)) * step(0.0, yy) * bump * envelope * 0.55;
        light += colors[i] * (intensity + halo);
    }

    // Horizon: a fine bright line, strongest where the light is.
    float line = exp(-(y * y) / (0.55 * u.scale * u.scale)) * envelope;
    float shimmer = 0.6 + 0.4 * sin(t * 3.0 - x * 5.0);
    light += float3(0.95, 0.97, 1.0) * line * (0.16 + 0.45 * finishing * shimmer + 0.30 * u.level);

    // Additive light saturates to white where lobes overlap.
    float3 lit = 1.0 - exp(-light * 2.1);
    float litAmount = max(lit.r, max(lit.g, lit.b));

    // Rim: iridescent, following the edge around, with a soft top specular.
    float angle = atan2(p.y, p.x) / (2.0 * M_PI_F);
    float rim = exp(-abs(d + 0.6) / (0.55 * u.scale));
    float3 rimColor = mix(float3(1.0), hueColor(angle + t * 0.03), 0.55);
    float specular = exp(-pow((d + 2.0 * u.scale) / (1.4 * u.scale), 2.0)) * smoothstep(0.2, -0.6, p.y / halfSize.y) * 0.22;

    float3 rgb = glass * glassAlpha * inside + lit * inside + rimColor * rim * 0.45 + float3(specular) * inside;
    float alpha = clamp(max(glassAlpha * inside, litAmount * inside) + rim * 0.45, 0.0, 1.0);
    return float4(rgb, alpha) * u.appear;
}
