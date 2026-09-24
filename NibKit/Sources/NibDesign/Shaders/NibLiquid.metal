#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

// Nib's water (docs/DESIGN.md §10.9). Light from the top-left: azimuth 225°, elevation 40°; screen y points down.
constant float3 kLight = float3(-0.5417, -0.5417, 0.6428);

static inline half4 over(half4 src, half4 dst) {
    return src + dst * (1.0h - src.a);
}

// d: signed distance to the surface in points (+ inside). dRim / dCaustic: the same at p − (1.1, 1.5) and p + (4, 6).
// n2: unit vector pointing into the droplet. Height = smoothstep(0, 8 pt, d): a flat puddle with a rounded rim.
// Edge and caustic come in already scaled by how much there is to lens (light paper) and by 1 − tinted.
static inline half4 waterOptics(half4 body, float d, float dRim, float dCaustic, float2 n2,
                                half4 edge, half4 caustic, half4 rim, half4 line, float specular) {
    float cover = saturate(d + 0.5);
    float edgeK = 1.0 - smoothstep(0.0, 2.6, d);
    float lineK = 1.0 - smoothstep(0.3, 1.1, d);
    float rimK = saturate(0.5 - dRim) * cover;
    float causticK = (1.0 - smoothstep(-2.0, 2.0, dCaustic)) * smoothstep(0.0, 3.0, d);
    float t = saturate(d / 8.0);
    float slope = 6.0 * t * (1.0 - t) / 8.0 * 6.5;
    float3 n = normalize(float3(-n2 * slope, 1.0));
    float3 h = normalize(kLight + float3(0.0, 0.0, 1.0));
    float spec = pow(saturate(dot(n, h)), 40.0) * specular * cover;
    half hs = half(spec);

    half4 o = body;
    o = over(edge * half(edgeK), o);
    o = over(caustic * half(causticK), o);
    o = over(half4(hs, hs, hs, hs), o);
    o = over(rim * half(rimK), o);
    o = over(line * half(lineK), o);
    return o * half(cover);
}

// Layer effect over a cluster's blurred field. Alpha = union coverage; r, g, b = clear, deep, tinted coverage, scaled
// by k = 0.5 + 0.5 × the share over light paper, so (r + g + b) / a recovers that share.
[[ stitchable ]] half4 nibWaterField(float2 position, SwiftUI::Layer layer, float iso,
                                     half4 clearBody, half4 clearBodyPaper, half4 deepBody, half4 tintBody,
                                     half4 waterBody, half4 edge, half4 caustic, half4 rim, half4 tintRim,
                                     half4 line, float specular) {
    half4 c = layer.sample(position);
    float f = float(c.a);
    if (f < iso * 0.35) {
        return half4(0.0h);
    }
    float fx = float(layer.sample(position + float2(1.0, 0.0)).a - layer.sample(position - float2(1.0, 0.0)).a) * 0.5;
    float fy = float(layer.sample(position + float2(0.0, 1.0)).a - layer.sample(position - float2(0.0, 1.0)).a) * 0.5;
    float2 g = float2(fx, fy);
    float gl = max(length(g), 0.0001);
    float d = (f - iso) / gl;
    if (d < -0.5) {
        return half4(0.0h);
    }
    float dRim = (float(layer.sample(position - float2(1.1, 1.5)).a) - iso) / gl;
    float dCaustic = (float(layer.sample(position + float2(4.0, 6.0)).a) - iso) / gl;

    float kinds = max(float(c.r) + float(c.g) + float(c.b), 0.0001);
    float paper = saturate((kinds / max(f, 0.0001) - 0.5) * 2.0);
    float tinted = float(c.b) / kinds;
    half4 clear = mix(clearBody, clearBodyPaper, half4(half(paper)));
    half4 body = clear * half(float(c.r) / kinds) + deepBody * half(float(c.g) / kinds) + tintBody * half(tinted);
    body = over(waterBody * half(1.0 - tinted), body);
    // Edge and caustic only where there is something to lens; Tinted gets its rim and the outline, nothing else.
    half optics = half(paper * (1.0 - tinted));
    half4 r = mix(rim, tintRim, half4(half(tinted)));
    return waterOptics(body, d, dRim, dCaustic, g / gl, edge * optics, caustic * optics, r, line,
                       specular * (1.0 - tinted));
}

static inline float roundedBoxSDF(float2 p, float2 halfSize, float radius) {
    float2 q = abs(p) - halfSize + radius;
    return length(max(q, float2(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

// Colour effect for one static shape drawn with a 1 pt outset (nibGlass on iOS 17–25, folder films, frames). The
// material underneath provides the body; this adds the optics. `optics` 0 = rim and outline only.
[[ stitchable ]] half4 nibWaterRim(float2 position, half4 color, float4 bounds, float radius, float optics,
                                   half4 edge, half4 caustic, half4 rim, half4 line, float specular) {
    float2 halfSize = bounds.zw * 0.5 - 1.0;
    float2 centre = bounds.xy + bounds.zw * 0.5;
    float r = min(radius, min(halfSize.x, halfSize.y));
    float2 p = position - centre;
    float d = -roundedBoxSDF(p, halfSize, r);
    if (d < -0.5) {
        return half4(0.0h);
    }
    float dRim = -roundedBoxSDF(p - float2(1.1, 1.5), halfSize, r);
    float dCaustic = -roundedBoxSDF(p + float2(4.0, 6.0), halfSize, r);
    float e = 0.5;
    float2 g = float2(roundedBoxSDF(p - float2(e, 0.0), halfSize, r) - roundedBoxSDF(p + float2(e, 0.0), halfSize, r),
                      roundedBoxSDF(p - float2(0.0, e), halfSize, r) - roundedBoxSDF(p + float2(0.0, e), halfSize, r));
    float gl = max(length(g), 0.0001);
    half o = half(optics);
    return waterOptics(half4(0.0h), d, dRim, dCaustic, g / gl, edge * o, caustic * o, rim, line, specular * optics);
}
