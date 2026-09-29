#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// The listening visual: glowing ribbons of light that follow the voice, plus an
// edge light along the top of the keyboard.
//
// Everything is analytic (a few sines and exponentials per pixel), so it costs a
// fraction of a millisecond on any iOS 18 GPU and needs no textures, which matters
// inside a keyboard extension's memory ceiling.
//
// Inputs:
//   bounds     the view's bounding rect (x, y, width, height), in points
//   time       seconds, monotonic
//   level      smoothed loudness 0...1
//   energy     slower "presence" envelope 0...1 (speech has been going on)
//   dark       1 in dark mode, 0 in light mode
//   bands      12 coarse spectrum bands, 0...1, low to high

static float bandAt(float x, device const float *bands, int count) {
    // Mirror the spectrum about the centre: low frequencies in the middle, where the
    // ribbons are tallest, highs towards the edges.
    float m = abs(x - 0.5) * 2.0;             // 0 centre ... 1 edges
    float f = m * float(count - 1);
    int i = int(floor(f));
    int j = min(i + 1, count - 1);
    float t = f - float(i);
    t = t * t * (3.0 - 2.0 * t);
    return mix(bands[i], bands[j], t);
}

static float ribbon(float2 uv, float aspect, float time, float amp, float freq,
                    float speed, float phase, float thickness, float centerY) {
    float x = uv.x;
    // Taper towards both ends so the ribbon grows out of the middle.
    float envelope = pow(sin(3.14159265 * clamp(x, 0.0, 1.0)), 1.6);
    float wave = sin(x * freq * aspect + time * speed + phase)
               * 0.65 + 0.35 * sin(x * freq * 2.3 * aspect - time * speed * 1.7 + phase * 1.3);
    float y = centerY + wave * amp * envelope;
    float d = abs(uv.y - y);
    // Core line plus a wide halo.
    float core = exp(-pow(d / thickness, 2.0));
    float halo = exp(-d / (thickness * 5.0)) * 0.55;
    // A translucent body between the ribbon and the centre line gives the wave mass,
    // like light caught in a sheet rather than a wire.
    float lo = min(y, centerY), hi = max(y, centerY);
    // Feathered edges: a hard step here left visible horizontal seams.
    float feather = thickness * 1.5;
    float inside = smoothstep(lo - feather, lo + feather, uv.y) * (1.0 - smoothstep(hi - feather, hi + feather, uv.y));
    float body = inside * 0.22 * smoothstep(0.0, 0.05, hi - lo);
    return (core + halo + body) * (0.30 + 0.70 * envelope);
}

[[ stitchable ]] half4 voiceAurora(float2 position, half4 color, float4 bounds, float time,
                                   float level, float energy, float dark,
                                   device const float *bands, int bandCount) {
    float2 size = max(bounds.zw, float2(1.0));
    float2 uv = (position - bounds.xy) / size;
    float aspect = size.x / size.y;
    float centerY = 0.46;

    float x = uv.x;
    float spectral = bandCount > 0 ? bandAt(x, bands, bandCount) : 0.0;

    // Breathing floor when quiet, so the view never looks dead.
    float breathe = 0.5 + 0.5 * sin(time * 1.4);
    float quiet = 0.030 + 0.018 * breathe;
    float voice = level * 0.34 + spectral * 0.20;
    // Soft ceiling so loud speech swells without reaching the status line.
    float amp = quiet + 0.30 * (1.0 - exp(-voice / 0.30));

    float thick = 0.016 + 0.020 * level;

    float r1 = ribbon(uv, aspect, time, amp * 1.00, 2.1, 2.2, 0.0, thick, centerY);
    float r2 = ribbon(uv, aspect, time, amp * 0.80, 2.9, -1.7, 1.9, thick * 0.9, centerY);
    float r3 = ribbon(uv, aspect, time, amp * 0.62, 3.7, 2.9, 4.1, thick * 0.8, centerY);
    float r4 = ribbon(uv, aspect, time, amp * 0.45, 1.5, -1.1, 2.7, thick * 1.2, centerY);

    // Palette: Obadh teal leads; sky, violet and a warm accent give it life.
    float3 teal   = float3(0.235, 0.749, 0.737);   // #3CBFBC
    float3 sky    = float3(0.310, 0.639, 1.000);   // #4FA3FF
    float3 violet = float3(0.545, 0.424, 1.000);   // #8B6CFF
    float3 coral  = float3(1.000, 0.478, 0.541);   // #FF7A8A

    // Slow hue drift along x so the colours travel with the waves.
    float drift = 0.5 + 0.5 * sin(x * 3.2 - time * 0.6);
    float3 c1 = mix(teal, sky, drift);
    float3 c2 = mix(violet, teal, 1.0 - drift);
    float3 c3 = mix(sky, coral, 0.35 + 0.35 * energy);
    float3 c4 = mix(teal, violet, 0.5);

    float3 rgb = c1 * r1 + c2 * r2 * 0.9 + c3 * r3 * 0.8 + c4 * r4 * 0.55;
    float intensity = r1 + r2 * 0.9 + r3 * 0.8 + r4 * 0.55;

    // Edge light: a soft band along the very top that swells with the voice.
    float edge = exp(-uv.y * (18.0 - 9.0 * level)) * (0.35 + 0.95 * max(level, energy * 0.6));
    float3 edgeColor = mix(mix(teal, violet, x), mix(sky, coral, 1.0 - x), 0.5 + 0.5 * sin(time * 0.8 + x * 4.0));
    rgb += edgeColor * edge;
    intensity += edge;

    // Light mode draws over a pale keyboard, where additive light washes out:
    // deepen the colours and lean on alpha instead.
    float alpha = clamp(intensity * 1.15, 0.0, 1.0);
    float3 outRGB = rgb / max(intensity, 1e-3);
    float grey = dot(outRGB, float3(0.299, 0.587, 0.114));
    outRGB = clamp(mix(float3(grey), outRGB, 1.35), 0.0, 1.0);   // saturation lift
    outRGB = mix(outRGB * 0.80, outRGB, dark);
    alpha *= mix(0.92, 1.0, dark);

    return half4(half3(outRGB * alpha), half(alpha));
}
