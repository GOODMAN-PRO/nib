#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Nib's water on iOS 17–25 (docs/DESIGN.md §10.9, Liquid Glass v2). Every optic lives in the outer 4.5 pt: a 0.8 pt rim
// lit by the top-left key light with a counter-rim half as bright opposite it, a sheen inside the lit edge and, over
// light paper, a body that thins toward the silhouette where the glass would bend the page. The core is the body tint
// alone. The numbers arrive from NibOptics (NibShaders.swift); the argument lists there and here match one for one.

static inline half4 over(half4 src, half4 dst) {
    return src + dst * (1.0h - src.a);
}

// `c` (premultiplied) at `k` times its own alpha, the result's alpha capped at 1.
static inline half4 scaled(half4 c, float k) {
    float a = float(c.a);
    if (a <= 0.0 || k <= 0.0) {
        return half4(0.0h);
    }
    return c * half(min(k, 1.0 / a));
}

// body: premultiplied body colour. d: distance inside the silhouette in points. outward: unit normal pointing out of
// the water. light: unit vector toward the key light (screen space, y down). strength: rim strength (1 at rest, 1.5
// held). counter: the counter-rim's peak relative to the key rim's. sheen: the sheen's share of the rim colour.
static inline half4 waterOptics(half4 body, float d, float2 outward, float2 light, half4 rim, half4 line,
                                float strength, float counter, float sheen) {
    float lambda = dot(outward, light);
    float k = max(lambda, 0.0);
    float c = max(-lambda, 0.0);
    float key = k * sqrt(k);                                  // max(λ, 0)^1.5
    float lit = key + counter * c * c;                        // + counter · max(−λ, 0)^2
    float band = 1.0 - smoothstep(0.3, 1.1, d);               // the 0.8 pt edge: outline and rim
    float glow = 1.0 - smoothstep(0.8, 4.5, d);               // the sheen inside the lit edge

    half4 o = body;
    o = over(scaled(rim, sheen * key * key * glow * strength), o);
    o = over(line * half(band), o);                           // under the rim: it shows where the rim is dim
    o = over(scaled(rim, lit * band * strength), o);
    return o;
}

// Layer effect over a cluster's blurred field. Alpha = union coverage; r, g, b = clear, deep, tinted coverage, scaled
// by k = 0.5 + 0.5 × the share over light paper, so (r + g + b) / a recovers that share. strength: rim strength.
// shadowK: shadow opacity multiplier (0 = none, 1 at rest, 1.6 held). shadowY: shadow offset downward in points.
[[ stitchable ]] half4 nibWaterField(float2 position, SwiftUI::Layer layer, float iso, float strength, float shadowK,
                                     float shadowY, float lightX, float lightY, float counter, float sheen, float lens,
                                     half4 clearBody, half4 clearBodyPaper, half4 deepBody, half4 tintBody,
                                     half4 waterBody, half4 rim, half4 tintRim, half4 line,
                                     half4 shadowDesk, half4 shadowPaper) {
    half4 c = layer.sample(position);
    float f = float(c.a);
    float cover = 0.0;
    half4 o = half4(0.0h);
    if (f >= iso * 0.35) {
        const float e = 1.5;
        float fx = (float(layer.sample(position + float2(e, 0.0)).a) - float(layer.sample(position - float2(e, 0.0)).a))
                   / (2.0 * e);
        float fy = (float(layer.sample(position + float2(0.0, e)).a) - float(layer.sample(position - float2(0.0, e)).a))
                   / (2.0 * e);
        float2 g = float2(fx, fy);
        float gl = max(length(g), 0.0001);
        float d = (f - iso) / gl;
        if (d >= -0.5) {
            cover = saturate(d + 0.5);
            float kinds = max(float(c.r) + float(c.g) + float(c.b), 0.0001);
            float paper = saturate((kinds / max(f, 0.0001) - 0.5) * 2.0);
            float tinted = float(c.b) / kinds;
            half4 clear = mix(clearBody, clearBodyPaper, half4(half(paper)));
            half4 body = clear * half(float(c.r) / kinds) + deepBody * half(float(c.g) / kinds) + tintBody * half(tinted);
            body = over(waterBody * half(1.0 - tinted), body);
            // Edge lens: only where there is a page to bend, never on Tinted.
            body = body * half(1.0 - lens * paper * (1.0 - tinted) * (1.0 - smoothstep(0.0, 4.0, d)));
            half4 r = mix(rim, tintRim, half4(half(tinted)));
            // The field grows inward, so −∇f points out of the water.
            o = waterOptics(body, d, -g / gl, float2(lightX, lightY), r, line, strength, counter,
                            sheen * (1.0 - tinted)) * half(cover);
        }
    }
    // The shadow: the field is the silhouette blurred at σ, so the field `shadowY` points higher is the water's soft
    // shadow. It is drawn only where the water is not, so it never shows through the translucent body.
    if (cover < 1.0 && shadowK > 0.0) {
        half4 s = layer.sample(position - float2(0.0, shadowY));
        float fs = float(s.a);
        if (fs > 0.002) {
            float sk = max(float(s.r) + float(s.g) + float(s.b), 0.0001);
            float sp = saturate((sk / fs - 0.5) * 2.0);
            half4 shadow = scaled(mix(shadowDesk, shadowPaper, half4(half(sp))), shadowK * saturate(fs / iso));
            o = o + shadow * half(1.0 - cover);
        }
    }
    return o;
}

static inline float roundedBoxSDF(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

// Colour effect for one static shape drawn with a 1 pt outset (nibGlass on iOS 17–25, beads, folder films, frames, the
// held rim over iOS 26 glass). The body underneath is drawn by SwiftUI; this adds the optics. counter 0 drops the
// counter-rim, sheen 0 the sheen, lineOn 0 the outline.
[[ stitchable ]] half4 nibWaterRim(float2 position, half4 color, float4 bounds, float radius, float strength,
                                   float lightX, float lightY, float counter, float sheen, float lineOn,
                                   half4 rim, half4 line) {
    float2 halfSize = bounds.zw * 0.5 - 1.0;
    float2 centre = bounds.xy + bounds.zw * 0.5;
    float r = min(radius, min(halfSize.x, halfSize.y));
    float2 p = position - centre;
    float d = -roundedBoxSDF(p, halfSize, r);
    if (d < -0.5 || d > 5.0) {
        return half4(0.0h);
    }
    const float e = 0.5;
    float2 g = float2(roundedBoxSDF(p + float2(e, 0.0), halfSize, r) - roundedBoxSDF(p - float2(e, 0.0), halfSize, r),
                      roundedBoxSDF(p + float2(0.0, e), halfSize, r) - roundedBoxSDF(p - float2(0.0, e), halfSize, r));
    float2 outward = g / max(length(g), 0.0001);
    half4 o = waterOptics(half4(0.0h), d, outward, float2(lightX, lightY), rim, line * half(lineOn), strength, counter,
                          sheen);
    return o * half(saturate(d + 0.5));
}
