// Iris — protetor de tela do Mac (Metal).
// PORT de caina.design/src/shaders/iridescent.frag.glsl (fonte da verdade).
// Mudança de aparência se faz no .glsl do site, confere-se no ?debug, e só depois desce para cá.
//
// Divergências deliberadas deste port (mesma lista do port WGSL do Figma, iris-shader/README.md):
//   - pow(x, 2.0) em distâncias virou e * e (base negativa dentro do raio do bojo)
//   - pointer fixo em (0.5, 0.5) com força 0: protetor de tela não tem ponteiro vivo
//   - uniforms em struct de floats (sem vec2 para evitar padding entre Swift e MSL)

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
  float resX, resY;
  float time;
  float pointerX, pointerY;
  float pointerStrength;
  float amplitude;
  float scale;
  float speed;
  float bandFreq;
  float hueOffset;
  float saturation;
  float highlight;
  float gate;
  float pressDepth;
  float pressRadius;
  float facing;
  float gravity;
  float flow;
  float anchor;
};

struct VOut {
  float4 pos [[position]];
  float2 uv;
};

// Triângulo de tela cheia, uv com y para cima (igual ao Triangle do OGL).
vertex VOut iris_vertex(uint vid [[vertex_id]]) {
  float2 p = float2((vid << 1) & 2, vid & 2);  // (0,0) (2,0) (0,2)
  VOut o;
  o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0);
  o.uv = p;
  return o;
}

static inline float sq(float x) { return x * x; }

static float hash21(float2 p) {
  p = fract(p * float2(234.34, 435.345));
  p += dot(p, p + 34.23);
  return fract(p.x * p.y);
}

static float noise2(float2 p) {
  float2 i = floor(p);
  float2 f = fract(p);
  float2 u = f * f * (3.0 - 2.0 * f);
  float a = hash21(i);
  float b = hash21(i + float2(1.0, 0.0));
  float c = hash21(i + float2(0.0, 1.0));
  float d = hash21(i + float2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Campo de altura do tecido: ondas direcionais em camadas + domain warp.
static float heightField(float2 p, float t, float2 vUv, constant Uniforms& U) {
  float2 pg = float2(p.x, p.y * mix(1.0, 0.32, U.gravity));

  float drift = mix(0.25, 1.0, U.flow);
  float2 warp = float2(
    noise2(pg * 0.75 + float2(t * 0.06 * drift, 0.0)),
    noise2(pg * 0.75 + float2(0.0, -t * 0.05 * drift) + 17.3)
  );
  float2 q = pg + (warp - 0.5) * 1.25;

  // Líquido: ondas viajantes
  float trav = 0.0;
  trav += sin(q.x * 1.9 + t * 0.8 + sin(q.y * 0.5 + t * 0.34) * 2.3) * 0.62;
  trav += sin(q.x * 0.72 - q.y * 0.33 + t * 0.52) * 0.26;
  trav += sin(dot(q, float2(1.45, 0.85)) + t * 1.05) * 0.12;

  // Tecido: dobras ancoradas balançando no lugar
  float stand = 0.0;
  stand += sin(q.x * 1.9 + sin(q.y * 0.42) * 1.3) * sin(t * 0.85 + q.x * 0.6) * 0.58;
  stand += sin(q.x * 0.85 + 1.7) * sin(t * 0.52 + q.y * 0.3 + 1.3) * 0.3;
  stand += sin(q.y * 2.1 - t * 1.5 + q.x * 0.8) * 0.13;

  float h = mix(stand, trav, U.flow);

  // Ancoragem: topo preso, amplitude cresce rumo à barra
  float hem = mix(1.0, mix(0.22, 1.3, 1.0 - vUv.y), U.anchor);
  h *= hem;

  // Toque (inerte no protetor: pointerStrength = 0, mantido por fidelidade à fonte)
  float2 aspect = float2(U.resX / U.resY, 1.0);
  float2 pa = (vUv - 0.5) * aspect;
  float2 ca = (float2(U.pointerX, U.pointerY) - 0.5) * aspect;
  float d = length(pa - ca);
  float r = max(U.pressRadius, 0.03);

  float grip = clamp(U.pointerStrength, 0.0, 1.0);
  h *= 1.0 - grip * 0.85 * exp(-sq(d / (r * 1.6)));

  float dent = exp(-sq(d / r));
  float bulge = exp(-sq((d - r * 1.8) / (r * 0.9)));
  h += (-dent + bulge * 0.75) * U.pressDepth * U.pointerStrength;

  return h * U.amplitude;
}

// Rampa espectral (paleta cosseno)
static float3 spectral(float x, float saturation) {
  float3 rainbow = 0.5 + 0.5 * cos(6.2831853 * (x + float3(0.0, 0.33, 0.67)));
  rainbow = pow(rainbow, float3(0.82));
  rainbow *= float3(0.92, 0.84, 1.18);
  float lum = dot(rainbow, float3(0.299, 0.587, 0.114));
  return mix(float3(lum), rainbow, saturation);
}

fragment float4 iris_fragment(VOut in [[stage_in]], constant Uniforms& U [[buffer(0)]]) {
  float2 vUv = in.uv;
  float2 aspect = float2(U.resX / U.resY, 1.0);
  float2 p = (vUv - 0.5) * aspect * U.scale;
  float t = U.time * U.speed;

  float e = 0.012 * U.scale;
  float h  = heightField(p, t, vUv, U);
  float hx = heightField(p + float2(e, 0.0), t, vUv, U) - heightField(p - float2(e, 0.0), t, vUv, U);
  float hy = heightField(p + float2(0.0, e), t, vUv, U) - heightField(p - float2(0.0, e), t, vUv, U);
  float2 grad = float2(hx, hy) / (2.0 * e);

  float slope = length(grad);
  float3 N = normalize(float3(-grad, 1.0));
  float3 V = float3(0.0, 0.0, 1.0);
  float3 L = normalize(float3(0.35, 0.55, 0.72));
  float3 Hv = normalize(L + V);

  float spec = pow(max(dot(N, Hv), 0.0), 64.0);
  float sheen = pow(max(dot(N, Hv), 0.0), 5.0);

  float gateLo = mix(0.12, 0.55, U.gate);
  float gate = smoothstep(gateLo, gateLo + 0.85, slope);

  float phase = dot(normalize(grad + 1e-5), float2(0.82, 0.57)) * 0.35
              + slope * U.bandFreq
              + h * 1.7
              + U.hueOffset;
  float3 fringe = spectral(phase, U.saturation);

  float facing = mix(1.0, smoothstep(-0.42, 0.34, h), U.facing);

  float3 col = fringe * gate * (sheen * 1.25 + spec * 2.1) * facing;
  col += float3(0.92, 0.95, 1.0) * spec * U.highlight * gate * facing * 1.4;

  col = col / (1.0 + col * 0.4);
  col = pow(col, float3(0.9));

  return float4(col, 1.0);
}
