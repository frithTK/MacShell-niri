#version 440
// Liquid Glass for the macdock Dock.
//
// Build:  qsb --qt6 -o liquidglass.frag.qsb liquidglass.frag
// (shell.qml runs this automatically on first use and caches the result in ~/.config/macdock/)
//
// The shader treats the Dock as a slab of curved glass sitting on top of a live backdrop texture:
//   * a rounded-rect signed distance field gives the distance to the edge and the edge direction
//   * a convex "squircle" bezel profile turns that into a surface normal
//   * Snell's law (refract) turns the normal into a lateral shift of the sampled backdrop
//   * the backdrop is sampled per colour channel (dispersion) through a small disk blur
//   * saturation / tint / milky lift, then specular rim, inner depth shading and a soft drop shadow

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 itemSize;      // whole shader item in px (glass + pad on every side)
    vec2 glassSize;     // the Dock rectangle in px
    vec2 srcSize;       // backdrop texture size in px
    vec2 srcOffset;     // where the item's top-left sits inside the backdrop texture, px
    float pad;          // item padding around the glass (room for the drop shadow)
    float radius;       // corner radius, px
    float bezel;        // width of the refracting rim, px
    float thickness;    // how far the rim shifts the backdrop, px
    float dispersion;   // chromatic split (0 = none)
    float blurPx;       // backdrop blur radius, px
    float tintMix;      // 0..1 amount of flat tint (the "translucency" slider)
    float saturation;   // backdrop saturation boost
    float dark;         // 0 = light mode, 1 = dark mode
    float debug;        // 1 = show the raw backdrop texture (magenta = texture is empty)
    float rim;          // specular edge highlight strength (1 = original strength)
    float grain;        // fine noise amplitude over the whole glass
    float magnify;      // vertical lens magnification of the whole slab
    float shadowAmt;    // drop-shadow strength (1 = original, 0 = none) - appended last so older layouts stay compatible
    float rimTint;
    float ringW;
    float flatInner;
};

layout(binding = 1) uniform sampler2D src;

const int   TAPS   = 24;
const float GOLDEN = 2.39996323;

// Natural blur, no "duplicated background" ghosts:
//  * every tap reads a pre-blurred mip level sized to the gap between taps, so the taps overlap into one
//    smooth surface instead of showing as separate copies of the content
//  * Gaussian weights give a soft falloff instead of a hard disk edge
//  * the tap pattern is rotated per pixel (interleaved gradient noise), so any leftover gaps turn into
//    fine grain instead of repeating ghost lines
//  * one shared pattern for all three colour channels (dispersion only shifts the centre)
// Needs `mipmap: true` on the ShaderEffectSource (set in MacBar.qml / MacDock.qml).
vec3 backdropLod(vec2 pItem, float lod)
{
    vec2 uv = (pItem + srcOffset) / srcSize;
    return textureLod(src, clamp(uv, vec2(0.001), vec2(0.999)), lod).rgb;
}

float ign(vec2 p)
{
    return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

vec3 blurredDisp(vec2 pItem, vec2 disp, float disperse, float rad)
{
    // A zero blur setting must also skip the residual disk smoothing. Keep
    // refraction/dispersion independent, sampling each colour at base LOD.
    if (rad <= 0.0) {
        return vec3(backdropLod(pItem + disp * (1.0 + disperse), 0.0).r,
                    backdropLod(pItem + disp, 0.0).g,
                    backdropLod(pItem + disp * (1.0 - disperse), 0.0).b);
    }
    float R   = max(rad, 0.5) * 1.5;                       // Gaussian reaches further than a flat disk
    float gap = R * sqrt(3.14159265 / float(TAPS));        // spacing between neighbouring taps, px
    float lod = clamp(log2(max(gap, 1.0)) + 0.35, 0.0, 6.0);
    float rot = ign(gl_FragCoord.xy) * 6.2831853;
    vec3  acc = vec3(0.0);
    float wsum = 0.0;
    for (int i = 0; i < TAPS; ++i) {
        float fi = float(i) + 0.5;
        float r  = sqrt(fi / float(TAPS));
        float a  = fi * GOLDEN + rot;
        float w  = exp(-2.2 * r * r);
        vec2  o  = vec2(cos(a), sin(a)) * r * R;
        vec3  c;
        c.r = backdropLod(pItem + o + disp * (1.0 + disperse), lod).r;
        c.g = backdropLod(pItem + o + disp,                    lod).g;
        c.b = backdropLod(pItem + o + disp * (1.0 - disperse), lod).b;
        acc  += c * w;
        wsum += w;
    }
    return acc / wsum;
}

float hash12(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float roundBox(vec2 q, vec2 hs, float r)
{
    vec2 d = abs(q) - (hs - r);
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - r;
}

void main()
{
    vec2 p  = qt_TexCoord0 * itemSize;
    vec2 hs = glassSize * 0.5;
    vec2 q  = p - vec2(pad) - hs;
    float r = min(radius, min(hs.x, hs.y));

    float sd  = roundBox(q, hs, r);               // < 0 inside the glass
    float cov = clamp(0.5 - sd, 0.0, 1.0);        // anti-aliased coverage

    if (debug > 0.5) {
        vec4 s = texture(src, clamp((p + srcOffset) / srcSize, vec2(0.001), vec2(0.999)));
        fragColor = (s.a < 0.01 ? vec4(1.0, 0.0, 1.0, 1.0) : vec4(s.rgb / max(s.a, 1e-3), 1.0)) * cov * qt_Opacity;
        return;
    }

    // ── soft drop shadow (only visible outside the glass) ──
    float sds    = roundBox(q - vec2(0.0, 3.0), hs, r);
    float shadow = 0.30 * shadowAmt * (1.0 - smoothstep(-2.0, 9.0, sds));
    if (sd > 1.0) {
        fragColor = vec4(0.0, 0.0, 0.0, shadow) * qt_Opacity;
        return;
    }

    // ── distance to edge + outward edge direction ──
    float t = max(-sd, 0.0);
    vec2 d2 = abs(q) - (hs - r);
    vec2 sg = vec2(q.x >= 0.0 ? 1.0 : -1.0, q.y >= 0.0 ? 1.0 : -1.0);
    vec2 m  = max(d2, 0.0);
    vec2 g  = (length(m) > 1e-4) ? normalize(m) * sg
                                 : ((d2.x > d2.y) ? vec2(sg.x, 0.0) : vec2(0.0, sg.y));

    // ── convex squircle bezel → surface normal ──
    float bz   = max(bezel, 1.0) * 1.45;           // wider bezel: the glass reads thicker
    float u    = clamp(t / bz, 0.0, 1.0);
    float om   = 1.0 - u;
    float om4  = om * om * om * om;
    float slope = (om * om * om) / pow(max(1.0 - om4, 1e-3), 0.75);
    slope = min(slope, 7.0);
    vec3 n = normalize(vec3(g * slope, 1.0));

    // ── refraction: glass n≈1.5, ray enters straight down ──
    vec3 rd   = refract(vec3(0.0, 0.0, -1.0), n, 1.0 / 1.52);
    vec2 disp = rd.xy / max(-rd.z, 0.18) * thickness * 1.55;

    // Convex lens: the middle of the slab slightly magnifies, the rim bends more.
    float mag = 1.0 - magnify * (1.0 - 0.28 * clamp(length(q / max(hs, vec2(1.0))), 0.0, 1.0));
    vec2 ps = vec2(pad) + hs + q * mag;
    float rad = blurPx * mix(0.28, 1.0, smoothstep(0.0, bz, t));

    vec3 col = blurredDisp(ps, disp, dispersion * 0.85, rad);

    // Thin film: dark mode keeps a clear lens; light mode keeps a white body
    // so dark ink stays readable. The rim still picks up Fresnel. A heavy
    // tint (Tinted / Frosted looks) fills the body toward an opaque material.
    float l = dot(col, vec3(0.2126, 0.7152, 0.0722));
    col = mix(vec3(l), col, saturation);
    float fres = pow(clamp(1.0 - u, 0.0, 1.0), 1.55);
    float opaque = clamp((tintMix - mix(0.55, 0.20, dark)) / mix(0.35, 0.55, dark), 0.0, 1.0);
    float body = mix(mix(0.68, 0.28, dark), 0.95, opaque);
    float film = clamp(tintMix, 0.0, 1.0) * mix(body, 1.0, fres);
    vec3 tintC = mix(vec3(1.0), mix(vec3(0.08, 0.085, 0.10), vec3(0.19, 0.195, 0.21), opaque), dark);
    col = mix(col, tintC, clamp(film, 0.0, mix(mix(0.72, 0.58, dark), 0.88, opaque)));
    col += mix(0.012, 0.010, dark) * mix(0.4, 1.0, fres);

    // Soft top sheen only — smoked inner edges hide the wallpaper.
    float ty = clamp((q.y + hs.y) / max(glassSize.y, 1.0), 0.0, 1.0);
    col += (1.0 - ty) * mix(0.018, 0.018, dark);
    float innerK = 1.0 - clamp(flatInner, 0.0, 1.0);
    col *= 1.0 - 0.045 * exp(-t / 8.0) * clamp(g.y, 0.0, 1.0) * innerK;
    vec3 rimCol = mix(vec3(0.96, 0.98, 1.0), clamp(col * 1.5 + 0.12, 0.0, 1.0), rimTint);

    // ── specular rim, light from the top-left ──
    vec2  L      = normalize(vec2(-0.55, -0.83));
    float facing = dot(g, L);
    float spec   = pow(max(facing, 0.0), 1.6) + 0.55 * pow(max(-facing, 0.0), 2.2);
    float hair   = exp(-t / 0.95);
    float wide   = exp(-t / 4.2);
    float edgeHi = hair * (0.22 + 0.82 * spec) + wide * 0.12 * (0.32 + spec);
    edgeHi *= rim * mix(0.9, 1.05, dark);
    col += edgeHi * rimCol;

    // meniscus: a soft second highlight inside the rim, like surface tension pulling the liquid together
    float mx  = (t - bz * 0.5) / (bz * 0.2 + 1.0);
    float men = exp(-mx * mx);
    col += men * 0.07 * (0.35 + spec) * rim * rimCol;
    if (ringW > 0.0) {
        float ring = 1.0 - smoothstep(ringW * 0.5, ringW * 0.5 + 1.0, t);
        col = mix(col, rimCol, ring * (0.55 + 0.35 * clamp(facing * 0.5 + 0.5, 0.0, 1.0)));
    }

    // fine triangular-distribution grain, same on every channel so it reads as texture, not colour noise
    float gn = hash12(gl_FragCoord.xy) + hash12(gl_FragCoord.xy * 1.7 + 17.0) - 1.0;
    col += gn * grain;

    col = clamp(col, 0.0, 1.0);

    float a = cov + shadow * (1.0 - cov);
    fragColor = vec4(col * cov, a) * qt_Opacity;   // premultiplied alpha
}
