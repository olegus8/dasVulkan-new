options gen2
options indenting = 4

// Tutorial 10 -- deferred shading "putting it all together". Four shader pairs sharing one cube +
// floor scene:
//
//   * SHADOW PASS  (shadow_vs, no fragment shader) -- depth-only render from a directional light's
//     POV into a 1024x1024 D32_SFLOAT image. Lifted from tutorial 08's shadow rail. The output is
//     sampled in the LIGHTING pass via `sampler2DShadow` + `textureCompare` (hardware PCF).
//
//   * G-BUFFER PASS  (gbuffer_vs + gbuffer_fs) -- writes THREE @location outputs simultaneously
//     (MRT, the dasSpirv rail PR #3195 enables): albedo+specular (RGBA8 with spec in .a), perturbed
//     world-space normal (RGBA16F with shininess in .a), world position (RGBA16F with material tag
//     in .a). Material is branched by the per-draw push constant `op.material` (0 = cube, 1 =
//     floor) with tri-planar UVs derived from world position -- no per-vertex UVs. NORMAL MAPPING
//     via derivative-based TBN (Schueler 2010): tangent + bitangent reconstructed from dFdx/dFdy
//     of world-pos and tri-planar UV, then a tangent-space normal sample is rotated into world
//     space and written to the G-buffer.
//
//   * SSAO PASS  (ssao_vs fullscreen tri + ssao_fs) -- reads normal + world-pos subpassInputs
//     (subpass dependency 0 -> 1 orders the reads behind the G-buffer writes), uses a
//     curvature-based AO approximation (the input-attachment surface only sees the CURRENT
//     fragment, so true screen-space sampling needs sampled images instead; the curvature-AO is a
//     pedagogical-clarity choice that keeps the multi-subpass rail in focus).
//
//   * LIGHTING PASS  (lighting_vs fullscreen tri + lighting_fs) -- reads ALL FOUR subpassInputs
//     (albedo+spec, normal, world-pos, ssao), samples the shadow map (sampler2DShadow + 5x5 PCF),
//     accumulates contributions from ONE directional sun + NUM_LIGHTS orbiting colored point
//     lights packed in the scene UBO. A 6-mode `debug_mode` push constant flips between the
//     composed lit result and the raw G-buffer / SSAO / lighting-only visualizations.
//
// UBO LAYOUT (two UBOs because set 0 on the SSAO + lighting pipelines is taken by subpassInputs):
//   * `xform : XformCam` at set 0 / binding 0  -- view + proj + light_vp (gbuffer + shadow passes)
//   * `scene : SceneCam` at set 1 / binding 1  -- duplicated light_vp + light_dir + camera_pos +
//     point lights array (SSAO + lighting passes). Slight duplication is the cost of avoiding a
//     descriptor-set-index conflict with the input attachments at set 0.

module deferred_tut_shaders public

require vulkan/vulkan_boost public
require vulkan/spirv_vulkan_shader public
require spirv/spirv_builtins public
require math

let NUM_LIGHTS = 3

// ===== shared UBO data structures =====
// Point lights are unrolled into pos0/col0..pos2/col2 float4 fields rather than a struct-array,
// because dasSpirv's compute_block_layout currently rejects fixed-array and nested-struct fields
// in @uniform/@push_constant blocks (only scalars/vectors/matrices on the leaves).

struct XformCam {
    view     : float4x4
    proj     : float4x4
    light_vp : float4x4
}
var @uniform @set = 0 @binding = 0 xform : XformCam

struct SceneCam {
    light_vp   : float4x4
    light_dir  : float4    // xyz = direction TO the sun (normalised); w unused
    camera_pos : float4    // xyz = world camera position; w = time (seconds)
    // Point lights: each takes two float4 -- pos (xyz=pos, w=range) + col (xyz=color, w=falloff).
    pos0 : float4
    col0 : float4
    pos1 : float4
    col1 : float4
    pos2 : float4
    col2 : float4
}
var @uniform @set = 1 @binding = 1 scene : SceneCam

//! Per-draw push constant: 64-byte model matrix + 4-byte material tag (0 = cube, 1 = floor).
//! Material drives the gbuffer fragment's albedo+normal branch and is mirrored into the G-buffer
//! world-pos.w so the lighting pass can read it without a 5th attachment.
struct ObjectPush {
    model    : float4x4
    material : int
}
var @push_constant op : ObjectPush

// ===== shared vertex inputs (cube + floor share pos+normal, stride 24, no UV) =====

var @in @location = 0 a_pos    : float3
var @in @location = 1 a_normal : float3

// ===== shadow pass =====

//! Pass 1: depth-only render from the sun's POV. No color attachment, no fragment shader -- just
//! gl_Position = light_vp * model * pos. After this pass the D32_SFLOAT image holds, per light-
//! space (x, y), the depth of the closest caster.
[vulkan_vertex_shader(name="shadow_vert_spv")]
def shadow_vs {
    gl_Position = xform.light_vp * op.model * float4(a_pos, 1.0)
}

// ===== G-buffer pass =====

var @out @location = 0 v_world_pos     : float3
var @out @location = 1 v_world_normal  : float3
var @flat @out @location = 2 v_material : int

[vulkan_vertex_shader(name="gbuffer_vert_spv")]
def gbuffer_vs {
    let world4 = op.model * float4(a_pos, 1.0)
    v_world_pos = float3(world4.x, world4.y, world4.z)
    let n_world4 = op.model * float4(a_normal, 0.0)
    v_world_normal = normalize(float3(n_world4.x, n_world4.y, n_world4.z))
    v_material = op.material
    gl_Position = xform.proj * xform.view * world4
}

var @in @location = 0 f_world_pos    : float3
var @in @location = 1 f_world_normal : float3
var @flat @in @location = 2 f_material : int

var @out @location = 0 g_albedo_out   : float4   // rgb = albedo, a = specular intensity
var @out @location = 1 g_normal_out   : float4   // rgb = perturbed world-space normal, a = shininess (Blinn exp)
var @out @location = 2 g_worldpos_out : float4   // rgb = world pos, a = material tag

// ----- procedural pattern helpers (all from world position; no UV vertex attribute) -----

def private brick_pattern(uv : float2) : float3 {
    let row = floor(uv.y * 2.0)
    let row_offset = (int(row) % 2 == 0) ? 0.0 : 0.5
    let bx = fract(uv.x + row_offset)
    let by = fract(uv.y * 2.0)
    let grout = 0.06
    let in_brick_x = bx > grout && bx < 1.0 - grout
    let in_brick_y = by > grout && by < 1.0 - grout
    if (in_brick_x && in_brick_y) {
        let noise = sin(uv.x * 23.7 + uv.y * 41.3) * 0.05
        return float3(0.55 + noise, 0.28 + noise * 0.5, 0.20 + noise * 0.3)
    }
    return float3(0.16, 0.15, 0.14)               // mortar
}

def private brick_bump(uv : float2) : float {
    let row = floor(uv.y * 2.0)
    let row_offset = (int(row) % 2 == 0) ? 0.0 : 0.5
    let bx = fract(uv.x + row_offset)
    let by = fract(uv.y * 2.0)
    let grout = 0.06
    let ex = smoothstep(0.0, grout, bx) * smoothstep(0.0, grout, 1.0 - bx)
    let ey = smoothstep(0.0, grout, by) * smoothstep(0.0, grout, 1.0 - by)
    return ex * ey
}

def private brushed_albedo(uv : float2) : float3 {
    // Subtle hairline + grain. Was too high-contrast (visible barcode); now a soft micro-tint.
    let hair = sin(uv.x * 24.0) * 0.5 + 0.5
    let grain = sin(uv.y * 6.0 + sin(uv.x * 2.7) * 0.4) * 0.5 + 0.5
    let v = 0.55 + 0.06 * (hair * 0.6 + grain * 0.4)
    return float3(v * 0.92, v * 0.97, v * 1.10)
}

def private brushed_bump(uv : float2) : float {
    let hair = sin(uv.x * 24.0) * 0.5 + 0.5
    let grain = sin(uv.y * 6.0 + sin(uv.x * 2.7) * 0.4) * 0.5 + 0.5
    return 0.5 + 0.1 * (hair * 0.6 + grain * 0.4)
}

//! Derivative-based TBN reconstruction (Schueler 2010). NO per-vertex tangent buffer required.
def private perturb_normal(n : float3; p : float3; uv : float2; tn : float3) : float3 {
    let dp1 = dFdx(p)
    let dp2 = dFdy(p)
    let duv1 = dFdx(uv)
    let duv2 = dFdy(uv)
    let dp2perp = cross(dp2, n)
    let dp1perp = cross(n, dp1)
    let T = dp2perp * duv1.x + dp1perp * duv2.x
    let B = dp2perp * duv1.y + dp1perp * duv2.y
    let invmax = 1.0 / sqrt(max(dot(T, T), dot(B, B)))
    return normalize(T * (tn.x * invmax) + B * (tn.y * invmax) + n * tn.z)
}

def private sample_floor_normal(uv : float2) : float3 {
    let eps = 0.01
    let dx = (brick_bump(uv + float2(eps, 0.0)) - brick_bump(uv - float2(eps, 0.0))) * 0.5 / eps
    let dy = (brick_bump(uv + float2(0.0, eps)) - brick_bump(uv - float2(0.0, eps))) * 0.5 / eps
    return normalize(float3(-dx * 0.5, -dy * 0.5, 1.0))
}

def private sample_cube_normal(uv : float2) : float3 {
    let eps = 0.01
    let dx = (brushed_bump(uv + float2(eps, 0.0)) - brushed_bump(uv - float2(eps, 0.0))) * 0.5 / eps
    let dy = (brushed_bump(uv + float2(0.0, eps)) - brushed_bump(uv - float2(0.0, eps))) * 0.5 / eps
    return normalize(float3(-dx * 0.2, -dy * 0.2, 1.0))
}

[vulkan_fragment_shader(name="gbuffer_frag_spv")]
def gbuffer_fs {
    let n = normalize(f_world_normal)
    var albedo = float3(0.0, 0.0, 0.0)
    var spec_intensity = 0.0
    var perturbed_normal = float3(0.0, 1.0, 0.0)

    // Material branch by world_pos.y — floor sits at y=0, cube at y=0.5..1.5. The natural form
    // `f_material == 1` (push-constant routed via the @flat int varying) requires the SPIR-V emitter
    // to emit the Flat decoration on integer varyings (Vulkan spec mandate); once that ships we'll
    // switch this to a push-constant branch.
    if (f_world_pos.y < 0.5) {
        // Floor: brick pattern, low specularity, bumpy normal from mortar grooves.
        let uv = float2(f_world_pos.x, f_world_pos.z) * 0.5
        albedo = brick_pattern(uv)
        spec_intensity = 0.1
        let tn = sample_floor_normal(uv)
        perturbed_normal = perturb_normal(n, f_world_pos, uv, tn)
    } else {
        // Cube: tri-planar brushed-metal albedo, glossy.
        let abs_n = float3(abs(n.x), abs(n.y), abs(n.z))
        let wsum = max(abs_n.x + abs_n.y + abs_n.z, 0.001)
        let wn = abs_n / float3(wsum, wsum, wsum)
        let uvx = float2(f_world_pos.y, f_world_pos.z)
        let uvy = float2(f_world_pos.x, f_world_pos.z)
        let uvz = float2(f_world_pos.x, f_world_pos.y)
        albedo = brushed_albedo(uvx) * wn.x + brushed_albedo(uvy) * wn.y + brushed_albedo(uvz) * wn.z
        spec_intensity = 0.7
        var dom_uv = uvy
        if (abs_n.x >= abs_n.y && abs_n.x >= abs_n.z) {
            dom_uv = uvx
        } elif (abs_n.z >= abs_n.x && abs_n.z >= abs_n.y) {
            dom_uv = uvz
        }
        let tn = sample_cube_normal(dom_uv)
        perturbed_normal = perturb_normal(n, f_world_pos, dom_uv, tn)
    }

    g_albedo_out   = float4(albedo, spec_intensity)
    g_normal_out   = float4(perturbed_normal, 32.0)             // .a = Blinn shininess
    g_worldpos_out = float4(f_world_pos, float(f_material))
}

// ===== SSAO pass (subpass 1) =====

var @out @location = 0 v_uv_ssao : float2

[vulkan_vertex_shader(name="ssao_vert_spv")]
def ssao_vs {
    let xs = fixed_array(-1.0,  3.0, -1.0)
    let ys = fixed_array(-1.0, -1.0,  3.0)
    let idx = gl_VertexIndex
    let x = xs[idx]
    let y = ys[idx]
    gl_Position = float4(x, y, 0.0, 1.0)
    v_uv_ssao = float2((x + 1.0) * 0.5, (y + 1.0) * 0.5)
}

var @set = 0 @binding = 0 @input_attachment_index = 0 ssao_in_normal   : subpassInput
var @set = 0 @binding = 1 @input_attachment_index = 1 ssao_in_worldpos : subpassInput

var @in @location = 0 f_uv_ssao : float2
var @out @location = 0 ssao_out : float4

//! Curvature-based AO. Pure input-attachment surfaces can only sample the CURRENT fragment, so
//! true SSAO that reads neighbours needs sampled images instead. We use a |n . view| curvature
//! darkening: surfaces facing the camera = bright, grazing-angle = darker. Pedagogically this
//! teaches "G-buffer reads + post-pass write" cleanly; a production SSAO would attach the G-buffer
//! as sampled images and randomly sample a hemisphere of offsets around the world position.
[vulkan_fragment_shader(name="ssao_frag_spv")]
def ssao_fs {
    let n = subpassLoad(ssao_in_normal).xyz
    let p = subpassLoad(ssao_in_worldpos).xyz
    if (dot(n, n) < 0.01) {
        ssao_out = float4(1.0, 1.0, 1.0, 1.0)   // background -> no AO darkening
        return
    }
    let view = normalize(scene.camera_pos.xyz - p)
    let facing = max(dot(normalize(n), view), 0.0)
    let ao = 0.55 + 0.45 * pow(facing, 0.6)
    ssao_out = float4(ao, ao, ao, 1.0)
}

// ===== lighting pass (subpass 2) =====

var @out @location = 0 v_uv_lit : float2

[vulkan_vertex_shader(name="lighting_vert_spv")]
def lighting_vs {
    let xs = fixed_array(-1.0,  3.0, -1.0)
    let ys = fixed_array(-1.0, -1.0,  3.0)
    let idx = gl_VertexIndex
    let x = xs[idx]
    let y = ys[idx]
    gl_Position = float4(x, y, 0.0, 1.0)
    v_uv_lit = float2((x + 1.0) * 0.5, (y + 1.0) * 0.5)
}

struct DebugPC {
    debug_mode : int
}
var @push_constant dbg : DebugPC

var @set = 0 @binding = 0 @input_attachment_index = 0 lit_in_albedo   : subpassInput
var @set = 0 @binding = 1 @input_attachment_index = 1 lit_in_normal   : subpassInput
var @set = 0 @binding = 2 @input_attachment_index = 2 lit_in_worldpos : subpassInput
var @set = 0 @binding = 3 @input_attachment_index = 3 lit_in_ssao     : subpassInput

var @uniform @set = 1 @binding = 0 shadow_map : sampler2DShadow

let SHADOW_MAP_PX = 1024.0

def private pcf_shadow(uv : float2; ref : float) : float {
    let texel = 1.0 / SHADOW_MAP_PX
    var sum = 0.0
    for (j in range(-2, 3)) {
        for (i in range(-2, 3)) {
            let off = float2(float(i), float(j)) * texel
            sum += textureCompare(shadow_map, uv + off, ref)
        }
    }
    return sum * (1.0 / 25.0)
}

var @in @location = 0 f_uv_lit : float2
var @out @location = 0 frag_color : float4

//! One point-light's contribution. Branchless: when distance > range, atten clamps to 0 so the
//! light naturally drops off. `pos.w` = range; `col.w` = falloff exponent on (1 - d/range).
def private point_light_contrib(pos : float4; col : float4; p : float3; n : float3; view_dir : float3;
                                shininess : float; spec_intensity : float) : float3 {
    let lvec = pos.xyz - p
    let ld = max(length(lvec), 0.0001)
    let ldir = lvec / float3(ld, ld, ld)
    let ndotl = max(dot(n, ldir), 0.0)
    let atten = pow(max(1.0 - ld / pos.w, 0.0), col.w)
    let hp = normalize(ldir + view_dir)
    let spec_pt = pow(max(dot(n, hp), 0.0), shininess) * spec_intensity
    return col.xyz * (ndotl + spec_pt) * atten
}

[vulkan_fragment_shader(name="lighting_frag_spv")]
def lighting_fs {
    // 16-row mode-indicator strip (drawn in shader, so window + recording + test all see it).
    if (gl_FragCoord.y < 16.0) {
        if (dbg.debug_mode == 1) {
            frag_color = float4(0.95, 0.45, 0.45, 1.0)         // albedo = warm red
        } elif (dbg.debug_mode == 2) {
            frag_color = float4(0.45, 0.95, 0.55, 1.0)         // normal = green
        } elif (dbg.debug_mode == 3) {
            frag_color = float4(0.45, 0.55, 0.95, 1.0)         // world-pos = blue
        } elif (dbg.debug_mode == 4) {
            frag_color = float4(0.80, 0.80, 0.80, 1.0)         // ssao = grey
        } elif (dbg.debug_mode == 5) {
            frag_color = float4(0.95, 0.55, 0.95, 1.0)         // lighting-only = magenta
        } else {
            frag_color = float4(0.95, 0.85, 0.45, 1.0)         // lit = yellow
        }
        return
    }

    let albedo_spec = subpassLoad(lit_in_albedo)
    let normal_mat  = subpassLoad(lit_in_normal)
    let worldpos_mt = subpassLoad(lit_in_worldpos)
    let ssao_factor = subpassLoad(lit_in_ssao).x

    let albedo = albedo_spec.rgb
    let spec_intensity = albedo_spec.a
    let n = normalize(normal_mat.xyz)
    let shininess = normal_mat.a
    let p = worldpos_mt.xyz

    if (dbg.debug_mode == 1) {
        frag_color = float4(albedo, 1.0)
        return
    }
    if (dbg.debug_mode == 2) {
        frag_color = float4(n * 0.5 + float3(0.5, 0.5, 0.5), 1.0)
        return
    }
    if (dbg.debug_mode == 3) {
        frag_color = float4(p * 0.15 + float3(0.5, 0.5, 0.5), 1.0)
        return
    }
    if (dbg.debug_mode == 4) {
        frag_color = float4(ssao_factor, ssao_factor, ssao_factor, 1.0)
        return
    }

    // Background pixels (normal is zero) -> sunset gradient.
    if (dot(n, n) < 0.01) {
        let sky_top = float3(0.06, 0.08, 0.18)
        let sky_bot = float3(0.36, 0.22, 0.30)
        let t = clamp(f_uv_lit.y, 0.0, 1.0)
        let bg = lerp(sky_top, sky_bot, float3(t, t, t))
        frag_color = float4(bg, 1.0)
        return
    }

    let view_dir = normalize(scene.camera_pos.xyz - p)

    // ----- Sun (shadowed directional) -----
    let sun_dir = normalize(scene.light_dir.xyz)
    let sun_color = float3(1.25, 1.10, 0.80)
    let ndotl_sun = max(dot(n, sun_dir), 0.0)

    let lc = scene.light_vp * float4(p, 1.0)
    let lw = max(lc.w, 0.0001)
    let ndc = float3(lc.x / lw, lc.y / lw, lc.z / lw)
    let shadow_uv = float2(ndc.x * 0.5 + 0.5, ndc.y * 0.5 + 0.5)
    let ref_depth = clamp(ndc.z, 0.0, 1.0)
    // Larger bias than tutorial 8 -- the deferred path's normal-mapped surfaces vary normal at
    // sub-pixel scale, which amplifies depth-bias quantization into the banding you saw.
    let frag_bias = max(0.003 * (1.0 - ndotl_sun), 0.001)
    let lit_ref = clamp(ref_depth - frag_bias, 0.0, 1.0)
    var shadow = pcf_shadow(shadow_uv, lit_ref)
    if (ndotl_sun < 0.05) { shadow = 0.0 }

    let half_sun = normalize(sun_dir + view_dir)
    let spec_sun = pow(max(dot(n, half_sun), 0.0), shininess) * spec_intensity

    let sun_contrib = sun_color * (ndotl_sun + spec_sun) * shadow

    // ----- Point lights ----- (unrolled because UBO field array isn't supported by dasSpirv)
    var pt_contrib = float3(0.0, 0.0, 0.0)
    pt_contrib = pt_contrib + point_light_contrib(scene.pos0, scene.col0, p, n, view_dir, shininess, spec_intensity)
    pt_contrib = pt_contrib + point_light_contrib(scene.pos1, scene.col1, p, n, view_dir, shininess, spec_intensity)
    pt_contrib = pt_contrib + point_light_contrib(scene.pos2, scene.col2, p, n, view_dir, shininess, spec_intensity)

    // ----- Hemisphere ambient (modulated by SSAO) -----
    let sky_color = float3(0.22, 0.24, 0.36)
    let ground_color = float3(0.08, 0.06, 0.05)
    let amb_t = n.y * 0.5 + 0.5
    let ambient = lerp(ground_color, sky_color, float3(amb_t, amb_t, amb_t))

    let ao = clamp(ssao_factor, 0.0, 1.0)
    let lighting = (ambient * ao) + (sun_contrib + pt_contrib) * (0.65 + 0.35 * ao)

    if (dbg.debug_mode == 5) {
        frag_color = float4(lighting, 1.0)
        return
    }

    let col = albedo * lighting
    frag_color = float4(col, 1.0)
}
