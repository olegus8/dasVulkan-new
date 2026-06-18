options gen2
options indenting = 4

// Tutorial 10 -- deferred shading "putting it all together". Reuses the shadow rail from tutorial
// 08 and adds the deferred multi-subpass machinery on top:
//
//   * SHADOW pass: single-subpass depth-only render pass (lifted from tutorial 08), targets a
//     1024x1024 D32_SFLOAT image. Runs ONCE per frame; the depth image transitions to
//     DEPTH_STENCIL_READ_ONLY_OPTIMAL at end-of-pass so the lighting pass can sample it as
//     `sampler2DShadow`.
//
//   * DEFERRED pass: ONE render pass, THREE subpasses, SIX attachments, TWO dependencies:
//       attachment 0 = g_albedo   (RGBA8,  COLOR_ATTACHMENT | INPUT_ATTACHMENT)
//       attachment 1 = g_normal   (RGBA16F, ... )
//       attachment 2 = g_worldpos (RGBA16F, ... )
//       attachment 3 = depth      (D32_SFLOAT, DEPTH_STENCIL_ATTACHMENT)
//       attachment 4 = ssao_img   (R8_UNORM, COLOR_ATTACHMENT | INPUT_ATTACHMENT)
//       attachment 5 = final_color(RGBA8,   COLOR_ATTACHMENT | TRANSFER_SRC -- the blit target)
//
//       subpass 0 (gbuffer):  writes (0, 1, 2) + depth
//       subpass 1 (ssao):     reads  (1, 2)        writes (4)
//       subpass 2 (lighting): reads  (0, 1, 2, 4)  writes (5)
//
//       dep 0->1, dep 1->2:  COLOR_ATTACHMENT_OUTPUT,COLOR_ATTACHMENT_WRITE
//                         -> FRAGMENT_SHADER,INPUT_ATTACHMENT_READ
//
// FOUR pipelines on these render passes (one per shader pair):
//   * shadow_pipeline   (depth-only, vertex-only, rp_shadow / subpass 0)
//   * gbuffer_pipeline  (vertex+fragment, vertex input pos+normal, 3 color blends, rp_deferred / subpass 0)
//   * ssao_pipeline     (vertex+fragment, no vertex input, 1 color blend, rp_deferred / subpass 1)
//   * lighting_pipeline (vertex+fragment, no vertex input, 1 color blend, rp_deferred / subpass 2)
//
// SCENE: a cube + a brick floor, lit by ONE shadowed directional sun + THREE orbiting colored
// point lights packed in the scene UBO. Normal-mapping (derivative-based TBN -> brick mortar
// grooves on the floor, brushed micro-grain on the cube) makes the surfaces look like surfaces.
// SSAO darkens grazing-angle edges via a |n.view| curvature term -- a pedagogical simplification
// of full screen-space AO, kept honest in the shader docstring.

module deferred_tut

require vulkan public
require vulkan/vulkan_boost public
require vulkan/vulkan_reflect
require deferred_tut_shaders public
require math

let public DEFERRED_W = 768
let public DEFERRED_H = 768
let public SHADOW_W = 1024
let public SHADOW_H = 1024

let DEPTH_FMT    = VkFormat.D32_SFLOAT
let ALBEDO_FMT   = VkFormat.R8G8B8A8_UNORM
let NORMAL_FMT   = VkFormat.R16G16B16A16_SFLOAT
let WORLDPOS_FMT = VkFormat.R16G16B16A16_SFLOAT
let SSAO_FMT     = VkFormat.R8_UNORM
let FINAL_FMT    = VkFormat.R8G8B8A8_UNORM

let XFORM_SIZE = 192ul                                     // 3 * float4x4
let SCENE_SIZE = 192ul                                     // 4*float4 + 3*float4x4? no: 1 mat (64) + 2 vec (32) + 6 vec (96) = 192

// debug_mode push-constant labels (host-visible -- the shader treats the int symbolically).
let public DBG_LIT       = 0
let public DBG_ALBEDO    = 1
let public DBG_NORMAL    = 2
let public DBG_WORLDPOS  = 3
let public DBG_SSAO      = 4
let public DBG_LIGHT     = 5
let public DBG_MODE_COUNT = 6

// ===== cube geometry (24 verts, 36 indices; stride 24 = pos + normal) =====

let private cube_vertices : array<float> <- [
    // +Z face
    -0.5, -0.5, 0.5,   0.0, 0.0, 1.0,
     0.5, -0.5, 0.5,   0.0, 0.0, 1.0,
     0.5,  0.5, 0.5,   0.0, 0.0, 1.0,
    -0.5,  0.5, 0.5,   0.0, 0.0, 1.0,
    // -Z face
     0.5, -0.5, -0.5,  0.0, 0.0, -1.0,
    -0.5, -0.5, -0.5,  0.0, 0.0, -1.0,
    -0.5,  0.5, -0.5,  0.0, 0.0, -1.0,
     0.5,  0.5, -0.5,  0.0, 0.0, -1.0,
    // +X face
     0.5, -0.5,  0.5,  1.0, 0.0, 0.0,
     0.5, -0.5, -0.5,  1.0, 0.0, 0.0,
     0.5,  0.5, -0.5,  1.0, 0.0, 0.0,
     0.5,  0.5,  0.5,  1.0, 0.0, 0.0,
    // -X face
    -0.5, -0.5, -0.5, -1.0, 0.0, 0.0,
    -0.5, -0.5,  0.5, -1.0, 0.0, 0.0,
    -0.5,  0.5,  0.5, -1.0, 0.0, 0.0,
    -0.5,  0.5, -0.5, -1.0, 0.0, 0.0,
    // +Y face
    -0.5,  0.5,  0.5,  0.0, 1.0, 0.0,
     0.5,  0.5,  0.5,  0.0, 1.0, 0.0,
     0.5,  0.5, -0.5,  0.0, 1.0, 0.0,
    -0.5,  0.5, -0.5,  0.0, 1.0, 0.0,
    // -Y face
    -0.5, -0.5, -0.5,  0.0, -1.0, 0.0,
     0.5, -0.5, -0.5,  0.0, -1.0, 0.0,
     0.5, -0.5,  0.5,  0.0, -1.0, 0.0,
    -0.5, -0.5,  0.5,  0.0, -1.0, 0.0
]

let private cube_indices : array<uint16> <- [
    uint16(0), uint16(1), uint16(2),  uint16(0), uint16(2), uint16(3),
    uint16(4), uint16(5), uint16(6),  uint16(4), uint16(6), uint16(7),
    uint16(8), uint16(9), uint16(10), uint16(8), uint16(10), uint16(11),
    uint16(12), uint16(13), uint16(14), uint16(12), uint16(14), uint16(15),
    uint16(16), uint16(17), uint16(18), uint16(16), uint16(18), uint16(19),
    uint16(20), uint16(21), uint16(22), uint16(20), uint16(22), uint16(23)
]

// Floor quad: 4 verts pos + (normal = 0, 1, 0). Big enough to catch the sun's shadow at all
// camera angles. Triangle winding matches the +Y face above (CCW from above).
let private floor_vertices : array<float> <- [
    -6.0, 0.0,  6.0,  0.0, 1.0, 0.0,
     6.0, 0.0,  6.0,  0.0, 1.0, 0.0,
     6.0, 0.0, -6.0,  0.0, 1.0, 0.0,
    -6.0, 0.0, -6.0,  0.0, 1.0, 0.0
]

let private floor_indices : array<uint16> <- [
    uint16(0), uint16(1), uint16(2),  uint16(0), uint16(2), uint16(3)
]

let public N_CUBE_INDICES = 36
let public N_FLOOR_INDICES = 6

// ===== matrix builders (column-major) =====

def perspective_vk(fov_y, aspect, znear, zfar : float) : float4x4 {
    let f = 1.0f / tan(fov_y * 0.5f)
    let nf = 1.0f / (znear - zfar)
    var m : float4x4
    m[0] = float4(f / aspect, 0.0f, 0.0f, 0.0f)
    m[1] = float4(0.0f, -f, 0.0f, 0.0f)
    m[2] = float4(0.0f, 0.0f, zfar * nf, -1.0f)
    m[3] = float4(0.0f, 0.0f, znear * zfar * nf, 0.0f)
    return m
}

def ortho_vk(left, right, bottom, top, znear, zfar : float) : float4x4 {
    let rl = 1.0f / (right - left)
    let tb = 1.0f / (top - bottom)
    let fn = 1.0f / (znear - zfar)
    var m : float4x4
    m[0] = float4(2.0f * rl, 0.0f, 0.0f, 0.0f)
    m[1] = float4(0.0f, -2.0f * tb, 0.0f, 0.0f)
    m[2] = float4(0.0f, 0.0f, fn, 0.0f)
    m[3] = float4(-(right + left) * rl, (top + bottom) * tb, znear * fn, 1.0f)
    return m
}

def vec3_sub(a, b : float3) : float3 => float3(a.x - b.x, a.y - b.y, a.z - b.z)
def vec3_cross(a, b : float3) : float3 => float3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
def vec3_dot(a, b : float3) : float => a.x * b.x + a.y * b.y + a.z * b.z
def vec3_normalize(v : float3) : float3 {
    let len = sqrt(vec3_dot(v, v))
    return float3(v.x / len, v.y / len, v.z / len)
}

def look_at_rh(eye, center, up : float3) : float4x4 {
    let f = vec3_normalize(vec3_sub(center, eye))
    let s = vec3_normalize(vec3_cross(f, up))
    let u = vec3_cross(s, f)
    var m : float4x4
    m[0] = float4(s.x, u.x, -f.x, 0.0f)
    m[1] = float4(s.y, u.y, -f.y, 0.0f)
    m[2] = float4(s.z, u.z, -f.z, 0.0f)
    m[3] = float4(-vec3_dot(s, eye), -vec3_dot(u, eye), vec3_dot(f, eye), 1.0f)
    return m
}

def translate_m4(t : float3) : float4x4 {
    var m : float4x4
    m[0] = float4(1.0f, 0.0f, 0.0f, 0.0f)
    m[1] = float4(0.0f, 1.0f, 0.0f, 0.0f)
    m[2] = float4(0.0f, 0.0f, 1.0f, 0.0f)
    m[3] = float4(t.x, t.y, t.z, 1.0f)
    return m
}

def rotate_y_m4(angle : float) : float4x4 {
    let c = cos(angle)
    let s = sin(angle)
    var m : float4x4
    m[0] = float4(c, 0.0f, -s, 0.0f)
    m[1] = float4(0.0f, 1.0f, 0.0f, 0.0f)
    m[2] = float4(s, 0.0f, c, 0.0f)
    m[3] = float4(0.0f, 0.0f, 0.0f, 1.0f)
    return m
}

def identity_m4 : float4x4 {
    var m : float4x4
    m[0] = float4(1.0f, 0.0f, 0.0f, 0.0f)
    m[1] = float4(0.0f, 1.0f, 0.0f, 0.0f)
    m[2] = float4(0.0f, 0.0f, 1.0f, 0.0f)
    m[3] = float4(0.0f, 0.0f, 0.0f, 1.0f)
    return m
}

def mat4_mul(a, b : float4x4) : float4x4 {
    var r : float4x4
    for (col in range(4)) {
        let bc = b[col]
        r[col] = a[0] * bc.x + a[1] * bc.y + a[2] * bc.z + a[3] * bc.w
    }
    return r
}

// ===== resources =====

struct public DeferredResources {
    g_albedo      : OffscreenTarget
    g_normal      : OffscreenTarget
    g_worldpos    : OffscreenTarget
    ssao_img      : OffscreenTarget
    final_color   : OffscreenTarget
    depth         : OffscreenDepth
    shadow_map    : OffscreenDepth
    shadow_sampler : Sampler

    rp_shadow     : RenderPass
    rp_deferred   : RenderPass
    fb_shadow     : Framebuffer
    fb_deferred   : Framebuffer

    cube_vb : HostBuffer
    cube_ib : HostBuffer
    floor_vb : HostBuffer
    floor_ib : HostBuffer
    xform_ubo : HostBuffer
    scene_ubo : HostBuffer

    shadow_set_layouts : array<DescriptorSetLayout>
    shadow_pipe_layout : PipelineLayout
    shadow_pipeline    : Pipeline
    shadow_set         : VkDescriptorSet

    gbuffer_set_layouts : array<DescriptorSetLayout>
    gbuffer_pipe_layout : PipelineLayout
    gbuffer_pipeline    : Pipeline
    gbuffer_set         : VkDescriptorSet

    ssao_set_layouts : array<DescriptorSetLayout>
    ssao_pipe_layout : PipelineLayout
    ssao_pipeline    : Pipeline
    ssao_set_input   : VkDescriptorSet     // set 0: input attachments
    ssao_set_scene   : VkDescriptorSet     // set 1: scene UBO

    lighting_set_layouts : array<DescriptorSetLayout>
    lighting_pipe_layout : PipelineLayout
    lighting_pipeline    : Pipeline
    lighting_set0        : VkDescriptorSet  // 4 subpassInputs
    lighting_set1        : VkDescriptorSet  // shadow_map + scene UBO

    desc_pool : DescriptorPool

    readback : HostBuffer
    buf_size : uint64
}

def public finalize(var r : DeferredResources) {
    unsafe {
        delete r.readback
        delete r.desc_pool
        delete r.lighting_pipeline
        delete r.lighting_pipe_layout
        delete r.lighting_set_layouts
        delete r.ssao_pipeline
        delete r.ssao_pipe_layout
        delete r.ssao_set_layouts
        delete r.gbuffer_pipeline
        delete r.gbuffer_pipe_layout
        delete r.gbuffer_set_layouts
        delete r.shadow_pipeline
        delete r.shadow_pipe_layout
        delete r.shadow_set_layouts
        delete r.fb_deferred
        delete r.fb_shadow
        delete r.rp_deferred
        delete r.rp_shadow
        delete r.shadow_sampler
        delete r.scene_ubo
        delete r.xform_ubo
        delete r.floor_ib
        delete r.floor_vb
        delete r.cube_ib
        delete r.cube_vb
        delete r.shadow_map
        delete r.depth
        delete r.final_color
        delete r.ssao_img
        delete r.g_worldpos
        delete r.g_normal
        delete r.g_albedo
    }
}

struct public DeferredContext {
    instance : Instance
    device   : Device
    queue    : VkQueue
    pool     : CommandPool
    res      : DeferredResources
}

def public finalize(var ctx : DeferredContext) {
    unsafe {
        delete ctx.res
        delete ctx.pool
        delete ctx.device
        delete ctx.instance
    }
}

// ===== build =====

def public build_deferred_resources(device : Device; phys : VkPhysicalDevice; queue : VkQueue; pool : CommandPool) : DeferredResources {
    let dev = boost_value_to_vk(device)

    // ----- offscreen images -----
    var samples1 : VkSampleCountFlags
    samples1._1 = true
    var gbuf_extra : VkImageUsageFlags
    gbuf_extra.input_attachment = true
    var inscope g_albedo   <- build_offscreen_target(device, phys, DEFERRED_W, DEFERRED_H, ALBEDO_FMT,   samples1, gbuf_extra)
    var inscope g_normal   <- build_offscreen_target(device, phys, DEFERRED_W, DEFERRED_H, NORMAL_FMT,   samples1, gbuf_extra)
    var inscope g_worldpos <- build_offscreen_target(device, phys, DEFERRED_W, DEFERRED_H, WORLDPOS_FMT, samples1, gbuf_extra)
    var inscope ssao_img   <- build_offscreen_target(device, phys, DEFERRED_W, DEFERRED_H, SSAO_FMT,     samples1, gbuf_extra)

    var depth_extra : VkImageUsageFlags
    var inscope depth <- build_offscreen_depth(device, phys, DEFERRED_W, DEFERRED_H, DEPTH_FMT, depth_extra)

    var sm_extra : VkImageUsageFlags
    sm_extra.sampled = true
    var inscope shadow_map <- build_offscreen_depth(device, phys, SHADOW_W, SHADOW_H, DEPTH_FMT, sm_extra)

    var final_extra : VkImageUsageFlags
    final_extra.transfer_src = true
    var inscope final_color <- build_offscreen_target(device, phys, DEFERRED_W, DEFERRED_H, FINAL_FMT, samples1, final_extra)

    var inscope shadow_sampler <- create_sampler_shadow(device)

    // ----- render passes -----
    var inscope rp_shadow   <- create_render_pass_depth_only(device, DEPTH_FMT)
    var inscope rp_deferred <- build_deferred_render_pass(device)

    // ----- framebuffers -----
    var sm_attach : array<ImageView>
    sm_attach |> push(weak_copy(shadow_map.view))
    var sm_fbci : FramebufferCreateInfo
    sm_fbci.renderPass = weak_copy(rp_shadow)
    sm_fbci.pAttachments <- sm_attach
    sm_fbci.width = uint(SHADOW_W)
    sm_fbci.height = uint(SHADOW_H)
    sm_fbci.layers = 1u
    var inscope fb_shadow <- create_framebuffer(device, sm_fbci)

    var def_attach : array<ImageView>
    def_attach |> push(weak_copy(g_albedo.view))
    def_attach |> push(weak_copy(g_normal.view))
    def_attach |> push(weak_copy(g_worldpos.view))
    def_attach |> push(weak_copy(depth.view))
    def_attach |> push(weak_copy(ssao_img.view))
    def_attach |> push(weak_copy(final_color.view))
    var def_fbci : FramebufferCreateInfo
    def_fbci.renderPass = weak_copy(rp_deferred)
    def_fbci.pAttachments <- def_attach
    def_fbci.width = uint(DEFERRED_W)
    def_fbci.height = uint(DEFERRED_H)
    def_fbci.layers = 1u
    var inscope fb_deferred <- create_framebuffer(device, def_fbci)

    // ----- geometry + UBO buffers -----
    var vb_usage : VkBufferUsageFlags
    vb_usage.vertex_buffer = true
    var ib_usage : VkBufferUsageFlags
    ib_usage.index_buffer = true
    var ubo_usage : VkBufferUsageFlags
    ubo_usage.uniform_buffer = true

    var cube_v_copy : array<float>
    cube_v_copy |> push_from(cube_vertices)
    var inscope cube_vb <- create_host_buffer_from_bytes(device, phys, vb_usage, cube_v_copy)
    delete cube_v_copy
    var cube_i_copy : array<uint16>
    cube_i_copy |> push_from(cube_indices)
    var inscope cube_ib <- create_host_buffer_from_bytes(device, phys, ib_usage, cube_i_copy)
    delete cube_i_copy

    var floor_v_copy : array<float>
    floor_v_copy |> push_from(floor_vertices)
    var inscope floor_vb <- create_host_buffer_from_bytes(device, phys, vb_usage, floor_v_copy)
    delete floor_v_copy
    var floor_i_copy : array<uint16>
    floor_i_copy |> push_from(floor_indices)
    var inscope floor_ib <- create_host_buffer_from_bytes(device, phys, ib_usage, floor_i_copy)
    delete floor_i_copy

    var inscope xform_ubo <- create_host_buffer(device, phys, XFORM_SIZE, ubo_usage)
    var inscope scene_ubo <- create_host_buffer(device, phys, SCENE_SIZE, ubo_usage)

    // ----- pipeline layouts via reflection -----
    var shadow_refl <- [decode_reflection(shadow_vert_spv_reflect)]
    var inscope shadow_set_layouts <- build_descriptor_set_layouts(device, shadow_refl)
    var inscope shadow_pipe_layout <- build_pipeline_layout(device, shadow_set_layouts, shadow_refl)
    delete shadow_refl

    var gbuf_refl <- [decode_reflection(gbuffer_vert_spv_reflect), decode_reflection(gbuffer_frag_spv_reflect)]
    var inscope gbuffer_set_layouts <- build_descriptor_set_layouts(device, gbuf_refl)
    var inscope gbuffer_pipe_layout <- build_pipeline_layout(device, gbuffer_set_layouts, gbuf_refl)
    delete gbuf_refl

    var ssao_refl <- [decode_reflection(ssao_vert_spv_reflect), decode_reflection(ssao_frag_spv_reflect)]
    var inscope ssao_set_layouts <- build_descriptor_set_layouts(device, ssao_refl)
    var inscope ssao_pipe_layout <- build_pipeline_layout(device, ssao_set_layouts, ssao_refl)
    delete ssao_refl

    var light_refl <- [decode_reflection(lighting_vert_spv_reflect), decode_reflection(lighting_frag_spv_reflect)]
    var inscope lighting_set_layouts <- build_descriptor_set_layouts(device, light_refl)
    var inscope lighting_pipe_layout <- build_pipeline_layout(device, lighting_set_layouts, light_refl)
    delete light_refl

    // ----- descriptor pool sized for ALL sets -----
    var dpci : DescriptorPoolCreateInfo
    dpci.maxSets = 6u                                              // shadow + gbuffer + ssao_input + ssao_scene + lighting_set0 + lighting_set1
    var p_ubo : DescriptorPoolSize
    p_ubo.type_ = VkDescriptorType.UNIFORM_BUFFER
    p_ubo.descriptorCount = 4u                                     // shadow + gbuffer (xform) + ssao_scene + lighting_set1 (scene)
    dpci.pPoolSizes |> push(p_ubo)
    var p_ia : DescriptorPoolSize
    p_ia.type_ = VkDescriptorType.INPUT_ATTACHMENT
    p_ia.descriptorCount = 6u                                      // ssao(2) + lighting(4)
    dpci.pPoolSizes |> push(p_ia)
    var p_smp : DescriptorPoolSize
    p_smp.type_ = VkDescriptorType.COMBINED_IMAGE_SAMPLER
    p_smp.descriptorCount = 1u                                     // shadow_map for lighting
    dpci.pPoolSizes |> push(p_smp)
    var inscope desc_pool <- create_descriptor_pool(device, dpci)

    // ----- allocate descriptor sets -----
    var shadow_set   = alloc_one_set(device, desc_pool, shadow_set_layouts[0])
    var gbuffer_set  = alloc_one_set(device, desc_pool, gbuffer_set_layouts[0])
    var ssao_set     = alloc_one_set(device, desc_pool, ssao_set_layouts[1])     // ssao's set 1 = scene UBO
    var lighting_set0 = alloc_one_set(device, desc_pool, lighting_set_layouts[0]) // 4 subpassInputs
    var lighting_set1 = alloc_one_set(device, desc_pool, lighting_set_layouts[1]) // shadow_map + scene UBO

    // ssao set 0 = input attachments (g_normal + g_worldpos). Allocated AFTER set 1 below.
    var ssao_set_input = alloc_one_set(device, desc_pool, ssao_set_layouts[0])

    // ----- writes -----
    var writes : array<WriteDescriptorSet>
    writes |> emplace(write_ubo(shadow_set, 0u, xform_ubo.buffer, XFORM_SIZE))
    writes |> emplace(write_ubo(gbuffer_set, 0u, xform_ubo.buffer, XFORM_SIZE))
    writes |> emplace(write_ubo(ssao_set, 1u, scene_ubo.buffer, SCENE_SIZE))
    writes |> emplace(write_input_attachment(ssao_set_input, 0u, g_normal.view))
    writes |> emplace(write_input_attachment(ssao_set_input, 1u, g_worldpos.view))
    writes |> emplace(write_input_attachment(lighting_set0, 0u, g_albedo.view))
    writes |> emplace(write_input_attachment(lighting_set0, 1u, g_normal.view))
    writes |> emplace(write_input_attachment(lighting_set0, 2u, g_worldpos.view))
    writes |> emplace(write_input_attachment(lighting_set0, 3u, ssao_img.view))
    writes |> emplace(write_shadow_sampler(lighting_set1, 0u, shadow_map.view, shadow_sampler))
    writes |> emplace(write_ubo(lighting_set1, 1u, scene_ubo.buffer, SCENE_SIZE))

    var no_copies : array<CopyDescriptorSet>
    update_descriptor_sets(device, writes, no_copies)

    // ----- shaders + pipelines -----
    var inscope sh_shadow   <- create_shader_module(device, shadow_vert_spv)
    var inscope sh_gbuf_v   <- create_shader_module(device, gbuffer_vert_spv)
    var inscope sh_gbuf_f   <- create_shader_module(device, gbuffer_frag_spv)
    var inscope sh_ssao_v   <- create_shader_module(device, ssao_vert_spv)
    var inscope sh_ssao_f   <- create_shader_module(device, ssao_frag_spv)
    var inscope sh_light_v  <- create_shader_module(device, lighting_vert_spv)
    var inscope sh_light_f  <- create_shader_module(device, lighting_frag_spv)

    var inscope shadow_pipeline   <- build_shadow_pipeline_d(device, rp_shadow, shadow_pipe_layout, sh_shadow)
    var inscope gbuffer_pipeline  <- build_gbuffer_pipeline(device, rp_deferred, gbuffer_pipe_layout, sh_gbuf_v, sh_gbuf_f)
    var inscope ssao_pipeline     <- build_fullscreen_pipeline(device, rp_deferred, ssao_pipe_layout, sh_ssao_v, sh_ssao_f, 1u, false)
    var inscope lighting_pipeline <- build_fullscreen_pipeline(device, rp_deferred, lighting_pipe_layout, sh_light_v, sh_light_f, 2u, false)

    // ----- readback -----
    let buf_size = uint64(DEFERRED_W * DEFERRED_H * 4)
    var inscope readback <- create_host_buffer(device, phys, buf_size)

    // ----- (queue + pool are passed in so the caller can record/submit later) -----
    let _unused_queue = queue
    let _unused_pool = pool

    // ssao set 1 binding 1: handled above via ssao_set; ssao set 0: handled via ssao_set0 (we
    // store ssao_set0 in the same field as ssao_set is meant for set 1 -- but we have TWO ssao
    // sets (set 0 = input atts, set 1 = scene UBO). Need to track both. Adjusting the struct.)

    var r : DeferredResources
    r.g_albedo <- g_albedo
    r.g_normal <- g_normal
    r.g_worldpos <- g_worldpos
    r.ssao_img <- ssao_img
    r.final_color <- final_color
    r.depth <- depth
    r.shadow_map <- shadow_map
    r.shadow_sampler <- shadow_sampler
    r.rp_shadow <- rp_shadow
    r.rp_deferred <- rp_deferred
    r.fb_shadow <- fb_shadow
    r.fb_deferred <- fb_deferred
    r.cube_vb <- cube_vb
    r.cube_ib <- cube_ib
    r.floor_vb <- floor_vb
    r.floor_ib <- floor_ib
    r.xform_ubo <- xform_ubo
    r.scene_ubo <- scene_ubo
    r.shadow_set_layouts <- shadow_set_layouts
    r.shadow_pipe_layout <- shadow_pipe_layout
    r.shadow_pipeline <- shadow_pipeline
    r.shadow_set = shadow_set
    r.gbuffer_set_layouts <- gbuffer_set_layouts
    r.gbuffer_pipe_layout <- gbuffer_pipe_layout
    r.gbuffer_pipeline <- gbuffer_pipeline
    r.gbuffer_set = gbuffer_set
    r.ssao_set_layouts <- ssao_set_layouts
    r.ssao_pipe_layout <- ssao_pipe_layout
    r.ssao_pipeline <- ssao_pipeline
    r.ssao_set_input = ssao_set_input
    r.ssao_set_scene = ssao_set
    r.lighting_set_layouts <- lighting_set_layouts
    r.lighting_pipe_layout <- lighting_pipe_layout
    r.lighting_pipeline <- lighting_pipeline
    r.lighting_set0 = lighting_set0
    r.lighting_set1 = lighting_set1
    r.desc_pool <- desc_pool
    r.readback <- readback
    r.buf_size = buf_size
    return <- r
}

// ===== helpers =====

def private alloc_one_set(device : Device; pool : DescriptorPool; layout : DescriptorSetLayout) : VkDescriptorSet {
    let dev = boost_value_to_vk(device)
    var dsai = VkDescriptorSetAllocateInfo()
    dsai.descriptorPool = boost_value_to_vk(pool)
    dsai.descriptorSetCount = 1u
    var raw_layout = boost_value_to_vk(layout)
    var raw_set : VkDescriptorSet
    unsafe {
        dsai.pSetLayouts = addr(raw_layout)
        vk_check(vkAllocateDescriptorSets(dev, dsai, addr(raw_set)), null)
    }
    return raw_set
}

def private write_ubo(set : VkDescriptorSet; binding : uint; buf : Buffer; size : uint64) : WriteDescriptorSet {
    var w : WriteDescriptorSet
    w.dstSet = vk_value_to_boost(set)
    w.dstBinding = binding
    w.descriptorType = VkDescriptorType.UNIFORM_BUFFER
    w.descriptorCount = 1u
    var bi : DescriptorBufferInfo
    bi.buffer = weak_copy(buf)
    bi.range_ = size
    w.pBufferInfo |> push(bi)
    return <- w
}

def private write_input_attachment(set : VkDescriptorSet; binding : uint; view : ImageView) : WriteDescriptorSet {
    var w : WriteDescriptorSet
    w.dstSet = vk_value_to_boost(set)
    w.dstBinding = binding
    w.descriptorType = VkDescriptorType.INPUT_ATTACHMENT
    w.descriptorCount = 1u
    var ii : DescriptorImageInfo
    ii.imageView = weak_copy(view)
    ii.imageLayout = VkImageLayout.SHADER_READ_ONLY_OPTIMAL
    w.pImageInfo |> push(ii)
    return <- w
}

def private write_shadow_sampler(set : VkDescriptorSet; binding : uint; view : ImageView; sampler : Sampler) : WriteDescriptorSet {
    var w : WriteDescriptorSet
    w.dstSet = vk_value_to_boost(set)
    w.dstBinding = binding
    w.descriptorType = VkDescriptorType.COMBINED_IMAGE_SAMPLER
    w.descriptorCount = 1u
    var ii : DescriptorImageInfo
    ii.sampler = weak_copy(sampler)
    ii.imageView = weak_copy(view)
    ii.imageLayout = VkImageLayout.DEPTH_STENCIL_READ_ONLY_OPTIMAL
    w.pImageInfo |> push(ii)
    return <- w
}

// ===== multi-subpass deferred render pass (6 attachments, 3 subpasses, 2 deps) =====

def private build_deferred_render_pass(device : Device) : RenderPass {
    var attaches : array<VkAttachmentDescription>

    var a_albedo : VkAttachmentDescription
    a_albedo.format = ALBEDO_FMT
    a_albedo.samples._1 = true
    a_albedo.loadOp = VkAttachmentLoadOp.CLEAR
    a_albedo.storeOp = VkAttachmentStoreOp.DONT_CARE
    a_albedo.stencilLoadOp = VkAttachmentLoadOp.DONT_CARE
    a_albedo.stencilStoreOp = VkAttachmentStoreOp.DONT_CARE
    a_albedo.initialLayout = VkImageLayout.UNDEFINED
    a_albedo.finalLayout = VkImageLayout.SHADER_READ_ONLY_OPTIMAL
    attaches |> push(a_albedo)

    var a_normal : VkAttachmentDescription
    a_normal.format = NORMAL_FMT
    a_normal.samples._1 = true
    a_normal.loadOp = VkAttachmentLoadOp.CLEAR
    a_normal.storeOp = VkAttachmentStoreOp.DONT_CARE
    a_normal.stencilLoadOp = VkAttachmentLoadOp.DONT_CARE
    a_normal.stencilStoreOp = VkAttachmentStoreOp.DONT_CARE
    a_normal.initialLayout = VkImageLayout.UNDEFINED
    a_normal.finalLayout = VkImageLayout.SHADER_READ_ONLY_OPTIMAL
    attaches |> push(a_normal)

    var a_worldpos : VkAttachmentDescription
    a_worldpos.format = WORLDPOS_FMT
    a_worldpos.samples._1 = true
    a_worldpos.loadOp = VkAttachmentLoadOp.CLEAR
    a_worldpos.storeOp = VkAttachmentStoreOp.DONT_CARE
    a_worldpos.stencilLoadOp = VkAttachmentLoadOp.DONT_CARE
    a_worldpos.stencilStoreOp = VkAttachmentStoreOp.DONT_CARE
    a_worldpos.initialLayout = VkImageLayout.UNDEFINED
    a_worldpos.finalLayout = VkImageLayout.SHADER_READ_ONLY_OPTIMAL
    attaches |> push(a_worldpos)

    var a_depth : VkAttachmentDescription
    a_depth.format = DEPTH_FMT
    a_depth.samples._1 = true
    a_depth.loadOp = VkAttachmentLoadOp.CLEAR
    a_depth.storeOp = VkAttachmentStoreOp.DONT_CARE
    a_depth.stencilLoadOp = VkAttachmentLoadOp.DONT_CARE
    a_depth.stencilStoreOp = VkAttachmentStoreOp.DONT_CARE
    a_depth.initialLayout = VkImageLayout.UNDEFINED
    a_depth.finalLayout = VkImageLayout.DEPTH_STENCIL_ATTACHMENT_OPTIMAL
    attaches |> push(a_depth)

    var a_ssao : VkAttachmentDescription
    a_ssao.format = SSAO_FMT
    a_ssao.samples._1 = true
    a_ssao.loadOp = VkAttachmentLoadOp.CLEAR
    a_ssao.storeOp = VkAttachmentStoreOp.DONT_CARE
    a_ssao.stencilLoadOp = VkAttachmentLoadOp.DONT_CARE
    a_ssao.stencilStoreOp = VkAttachmentStoreOp.DONT_CARE
    a_ssao.initialLayout = VkImageLayout.UNDEFINED
    a_ssao.finalLayout = VkImageLayout.SHADER_READ_ONLY_OPTIMAL
    attaches |> push(a_ssao)

    var a_final : VkAttachmentDescription
    a_final.format = FINAL_FMT
    a_final.samples._1 = true
    a_final.loadOp = VkAttachmentLoadOp.CLEAR
    a_final.storeOp = VkAttachmentStoreOp.STORE
    a_final.stencilLoadOp = VkAttachmentLoadOp.DONT_CARE
    a_final.stencilStoreOp = VkAttachmentStoreOp.DONT_CARE
    a_final.initialLayout = VkImageLayout.UNDEFINED
    a_final.finalLayout = VkImageLayout.TRANSFER_SRC_OPTIMAL
    attaches |> push(a_final)

    // Subpass 0: writes (0, 1, 2) + depth
    var s0_color : array<VkAttachmentReference>
    s0_color |> push(att_ref(0u, VkImageLayout.COLOR_ATTACHMENT_OPTIMAL))
    s0_color |> push(att_ref(1u, VkImageLayout.COLOR_ATTACHMENT_OPTIMAL))
    s0_color |> push(att_ref(2u, VkImageLayout.COLOR_ATTACHMENT_OPTIMAL))
    var s0_depth = att_ref(3u, VkImageLayout.DEPTH_STENCIL_ATTACHMENT_OPTIMAL)

    // Subpass 1: reads (1, 2), writes (4)
    var s1_input : array<VkAttachmentReference>
    s1_input |> push(att_ref(1u, VkImageLayout.SHADER_READ_ONLY_OPTIMAL))
    s1_input |> push(att_ref(2u, VkImageLayout.SHADER_READ_ONLY_OPTIMAL))
    var s1_color : array<VkAttachmentReference>
    s1_color |> push(att_ref(4u, VkImageLayout.COLOR_ATTACHMENT_OPTIMAL))

    // Subpass 2: reads (0, 1, 2, 4), writes (5)
    var s2_input : array<VkAttachmentReference>
    s2_input |> push(att_ref(0u, VkImageLayout.SHADER_READ_ONLY_OPTIMAL))
    s2_input |> push(att_ref(1u, VkImageLayout.SHADER_READ_ONLY_OPTIMAL))
    s2_input |> push(att_ref(2u, VkImageLayout.SHADER_READ_ONLY_OPTIMAL))
    s2_input |> push(att_ref(4u, VkImageLayout.SHADER_READ_ONLY_OPTIMAL))
    var s2_color : array<VkAttachmentReference>
    s2_color |> push(att_ref(5u, VkImageLayout.COLOR_ATTACHMENT_OPTIMAL))

    var s0 : VkSubpassDescription
    s0.pipelineBindPoint = VkPipelineBindPoint.GRAPHICS
    s0.colorAttachmentCount = 3u

    var s1 : VkSubpassDescription
    s1.pipelineBindPoint = VkPipelineBindPoint.GRAPHICS
    s1.inputAttachmentCount = 2u
    s1.colorAttachmentCount = 1u

    var s2 : VkSubpassDescription
    s2.pipelineBindPoint = VkPipelineBindPoint.GRAPHICS
    s2.inputAttachmentCount = 4u
    s2.colorAttachmentCount = 1u

    var subpasses : array<VkSubpassDescription>
    subpasses |> push(s0)
    subpasses |> push(s1)
    subpasses |> push(s2)

    var deps : array<VkSubpassDependency>
    var dep01 : VkSubpassDependency
    dep01.srcSubpass = 0u
    dep01.dstSubpass = 1u
    dep01.srcStageMask.color_attachment_output = true
    dep01.dstStageMask.fragment_shader = true
    dep01.srcAccessMask.color_attachment_write = true
    dep01.dstAccessMask.input_attachment_read = true
    dep01.dependencyFlags.by_region = true
    deps |> push(dep01)
    var dep12 : VkSubpassDependency
    dep12.srcSubpass = 1u
    dep12.dstSubpass = 2u
    dep12.srcStageMask.color_attachment_output = true
    dep12.dstStageMask.fragment_shader = true
    dep12.srcAccessMask.color_attachment_write = true
    dep12.dstAccessMask.input_attachment_read = true
    dep12.dependencyFlags.by_region = true
    deps |> push(dep12)

    var ci = VkRenderPassCreateInfo()
    ci.attachmentCount = uint(length(attaches))
    ci.subpassCount = uint(length(subpasses))
    ci.dependencyCount = uint(length(deps))
    var h : VkRenderPass
    unsafe {
        subpasses[0].pColorAttachments = addr(s0_color[0])
        subpasses[0].pDepthStencilAttachment = addr(s0_depth)
        subpasses[1].pInputAttachments = addr(s1_input[0])
        subpasses[1].pColorAttachments = addr(s1_color[0])
        subpasses[2].pInputAttachments = addr(s2_input[0])
        subpasses[2].pColorAttachments = addr(s2_color[0])
        ci.pAttachments = addr(attaches[0])
        ci.pSubpasses = addr(subpasses[0])
        ci.pDependencies = addr(deps[0])
        vk_check(vkCreateRenderPass(boost_value_to_vk(device), ci, null, h), null)
    }
    delete attaches
    delete subpasses
    delete deps
    delete s0_color
    delete s1_input
    delete s1_color
    delete s2_input
    delete s2_color
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    b._device = unsafe(reinterpret<uint64>(boost_value_to_vk(device)))
    return <- b
}

def private att_ref(att : uint; layout : VkImageLayout) : VkAttachmentReference {
    var r : VkAttachmentReference
    r.attachment = att
    r.layout = layout
    return r
}

// ===== pipeline builders =====

def private build_shadow_pipeline_d(device : Device; rp : RenderPass; layout : PipelineLayout; vert : ShaderModule) : Pipeline {
    var stages : array<VkPipelineShaderStageCreateInfo>
    stages |> resize(1)
    stages[0] = VkPipelineShaderStageCreateInfo()
    stages[0].stage.vertex = true
    stages[0].module_ = boost_value_to_vk(vert)
    stages[0].pName = "main"

    var vbindings : array<VkVertexInputBindingDescription>
    var vb_desc : VkVertexInputBindingDescription
    vb_desc.binding = 0u
    vb_desc.stride = 24u                                            // pos + normal (stride 24, normal unused in shadow pass)
    vb_desc.inputRate = VkVertexInputRate.VERTEX
    vbindings |> push(vb_desc)
    var vattrs : array<VkVertexInputAttributeDescription>
    var ap : VkVertexInputAttributeDescription
    ap.location = 0u
    ap.binding = 0u
    ap.format = VkFormat.R32G32B32_SFLOAT
    ap.offset = 0u
    vattrs |> push(ap)
    var an : VkVertexInputAttributeDescription
    an.location = 1u
    an.binding = 0u
    an.format = VkFormat.R32G32B32_SFLOAT
    an.offset = 12u
    vattrs |> push(an)

    var vinput = VkPipelineVertexInputStateCreateInfo()
    var iasm = VkPipelineInputAssemblyStateCreateInfo()
    iasm.topology = VkPrimitiveTopology.TRIANGLE_LIST

    var viewport : VkViewport
    viewport.width = float(SHADOW_W)
    viewport.height = float(SHADOW_H)
    viewport.maxDepth = 1.0f
    var scissor : VkRect2D
    scissor.extent.width = uint(SHADOW_W)
    scissor.extent.height = uint(SHADOW_H)
    var vpstate = VkPipelineViewportStateCreateInfo()
    vpstate.viewportCount = 1u
    vpstate.scissorCount = 1u

    var raster = VkPipelineRasterizationStateCreateInfo()
    raster.polygonMode = VkPolygonMode.FILL
    raster.cullMode.back = true
    raster.frontFace = VkFrontFace.COUNTER_CLOCKWISE
    raster.lineWidth = 1.0f
    raster.depthBiasEnable = 1u
    raster.depthBiasConstantFactor = 4.0f
    raster.depthBiasSlopeFactor = 4.0f
    var msaa = VkPipelineMultisampleStateCreateInfo()
    msaa.rasterizationSamples._1 = true

    var depth = VkPipelineDepthStencilStateCreateInfo()
    depth.depthTestEnable = 1u
    depth.depthWriteEnable = 1u
    depth.depthCompareOp = VkCompareOp.LESS

    // No color attachments, but Vulkan still needs a valid blend struct (count=0).
    var blend = VkPipelineColorBlendStateCreateInfo()
    blend.attachmentCount = 0u

    var gp = VkGraphicsPipelineCreateInfo()
    gp.stageCount = uint(length(stages))
    var h : VkPipeline
    unsafe {
        vinput.vertexBindingDescriptionCount = 1u
        vinput.pVertexBindingDescriptions = addr(vbindings[0])
        vinput.vertexAttributeDescriptionCount = uint(length(vattrs))
        vinput.pVertexAttributeDescriptions = addr(vattrs[0])
        vpstate.pViewports = addr(viewport)
        vpstate.pScissors = addr(scissor)
        gp.pStages = addr(stages[0])
        gp.pVertexInputState = addr(vinput)
        gp.pInputAssemblyState = addr(iasm)
        gp.pViewportState = addr(vpstate)
        gp.pRasterizationState = addr(raster)
        gp.pMultisampleState = addr(msaa)
        gp.pDepthStencilState = addr(depth)
        gp.pColorBlendState = addr(blend)
        gp.layout = boost_value_to_vk(layout)
        gp.renderPass = boost_value_to_vk(rp)
        gp.subpass = 0u
        var pci : array<VkGraphicsPipelineCreateInfo>
        pci |> push(gp)
        vk_check(vkCreateGraphicsPipelines(boost_value_to_vk(device), null, 1u, addr(pci[0]), null, addr(h)), null)
        delete pci
    }
    delete stages
    delete vbindings
    delete vattrs
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    b._device = unsafe(reinterpret<uint64>(boost_value_to_vk(device)))
    return <- b
}

def private build_gbuffer_pipeline(device : Device; rp : RenderPass; layout : PipelineLayout;
                                   vert : ShaderModule; frag : ShaderModule) : Pipeline {
    var stages : array<VkPipelineShaderStageCreateInfo>
    stages |> resize(2)
    stages[0] = VkPipelineShaderStageCreateInfo()
    stages[0].stage.vertex = true
    stages[0].module_ = boost_value_to_vk(vert)
    stages[0].pName = "main"
    stages[1] = VkPipelineShaderStageCreateInfo()
    stages[1].stage.fragment = true
    stages[1].module_ = boost_value_to_vk(frag)
    stages[1].pName = "main"

    var vbindings : array<VkVertexInputBindingDescription>
    var vb_desc : VkVertexInputBindingDescription
    vb_desc.binding = 0u
    vb_desc.stride = 24u
    vb_desc.inputRate = VkVertexInputRate.VERTEX
    vbindings |> push(vb_desc)
    var vattrs : array<VkVertexInputAttributeDescription>
    var ap : VkVertexInputAttributeDescription
    ap.location = 0u
    ap.binding = 0u
    ap.format = VkFormat.R32G32B32_SFLOAT
    ap.offset = 0u
    vattrs |> push(ap)
    var an : VkVertexInputAttributeDescription
    an.location = 1u
    an.binding = 0u
    an.format = VkFormat.R32G32B32_SFLOAT
    an.offset = 12u
    vattrs |> push(an)

    var vinput = VkPipelineVertexInputStateCreateInfo()
    var iasm = VkPipelineInputAssemblyStateCreateInfo()
    iasm.topology = VkPrimitiveTopology.TRIANGLE_LIST

    var viewport : VkViewport
    viewport.width = float(DEFERRED_W)
    viewport.height = float(DEFERRED_H)
    viewport.maxDepth = 1.0f
    var scissor : VkRect2D
    scissor.extent.width = uint(DEFERRED_W)
    scissor.extent.height = uint(DEFERRED_H)
    var vpstate = VkPipelineViewportStateCreateInfo()
    vpstate.viewportCount = 1u
    vpstate.scissorCount = 1u

    var raster = VkPipelineRasterizationStateCreateInfo()
    raster.polygonMode = VkPolygonMode.FILL
    raster.cullMode.back = true
    raster.frontFace = VkFrontFace.COUNTER_CLOCKWISE
    raster.lineWidth = 1.0f
    var msaa = VkPipelineMultisampleStateCreateInfo()
    msaa.rasterizationSamples._1 = true

    var depth = VkPipelineDepthStencilStateCreateInfo()
    depth.depthTestEnable = 1u
    depth.depthWriteEnable = 1u
    depth.depthCompareOp = VkCompareOp.LESS

    var blend_atts : array<VkPipelineColorBlendAttachmentState>
    for (i in range(3)) {
        var att : VkPipelineColorBlendAttachmentState
        att.colorWriteMask.r = true
        att.colorWriteMask.g = true
        att.colorWriteMask.b = true
        att.colorWriteMask.a = true
        blend_atts |> push(att)
    }
    var blend = VkPipelineColorBlendStateCreateInfo()
    blend.attachmentCount = 3u

    var gp = VkGraphicsPipelineCreateInfo()
    gp.stageCount = 2u
    var h : VkPipeline
    unsafe {
        vinput.vertexBindingDescriptionCount = 1u
        vinput.pVertexBindingDescriptions = addr(vbindings[0])
        vinput.vertexAttributeDescriptionCount = uint(length(vattrs))
        vinput.pVertexAttributeDescriptions = addr(vattrs[0])
        vpstate.pViewports = addr(viewport)
        vpstate.pScissors = addr(scissor)
        blend.pAttachments = addr(blend_atts[0])
        gp.pStages = addr(stages[0])
        gp.pVertexInputState = addr(vinput)
        gp.pInputAssemblyState = addr(iasm)
        gp.pViewportState = addr(vpstate)
        gp.pRasterizationState = addr(raster)
        gp.pMultisampleState = addr(msaa)
        gp.pDepthStencilState = addr(depth)
        gp.pColorBlendState = addr(blend)
        gp.layout = boost_value_to_vk(layout)
        gp.renderPass = boost_value_to_vk(rp)
        gp.subpass = 0u
        var pci : array<VkGraphicsPipelineCreateInfo>
        pci |> push(gp)
        vk_check(vkCreateGraphicsPipelines(boost_value_to_vk(device), null, 1u, addr(pci[0]), null, addr(h)), null)
        delete pci
    }
    delete stages
    delete vbindings
    delete vattrs
    delete blend_atts
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    b._device = unsafe(reinterpret<uint64>(boost_value_to_vk(device)))
    return <- b
}

//! Build a fullscreen-triangle pipeline (no vertex input, no depth, one color attachment).
//! `_depth` is reserved for future depth-test-on use.
def private build_fullscreen_pipeline(device : Device; rp : RenderPass; layout : PipelineLayout;
                                      vert : ShaderModule; frag : ShaderModule; subpass : uint;
                                      _depth : bool) : Pipeline {
    var stages : array<VkPipelineShaderStageCreateInfo>
    stages |> resize(2)
    stages[0] = VkPipelineShaderStageCreateInfo()
    stages[0].stage.vertex = true
    stages[0].module_ = boost_value_to_vk(vert)
    stages[0].pName = "main"
    stages[1] = VkPipelineShaderStageCreateInfo()
    stages[1].stage.fragment = true
    stages[1].module_ = boost_value_to_vk(frag)
    stages[1].pName = "main"

    var vinput = VkPipelineVertexInputStateCreateInfo()
    var iasm = VkPipelineInputAssemblyStateCreateInfo()
    iasm.topology = VkPrimitiveTopology.TRIANGLE_LIST

    var viewport : VkViewport
    viewport.width = float(DEFERRED_W)
    viewport.height = float(DEFERRED_H)
    viewport.maxDepth = 1.0f
    var scissor : VkRect2D
    scissor.extent.width = uint(DEFERRED_W)
    scissor.extent.height = uint(DEFERRED_H)
    var vpstate = VkPipelineViewportStateCreateInfo()
    vpstate.viewportCount = 1u
    vpstate.scissorCount = 1u

    var raster = VkPipelineRasterizationStateCreateInfo()
    raster.polygonMode = VkPolygonMode.FILL
    raster.frontFace = VkFrontFace.COUNTER_CLOCKWISE
    raster.lineWidth = 1.0f
    var msaa = VkPipelineMultisampleStateCreateInfo()
    msaa.rasterizationSamples._1 = true

    var depth_state = VkPipelineDepthStencilStateCreateInfo()

    var blend_att : VkPipelineColorBlendAttachmentState
    blend_att.colorWriteMask.r = true
    blend_att.colorWriteMask.g = true
    blend_att.colorWriteMask.b = true
    blend_att.colorWriteMask.a = true
    var blend = VkPipelineColorBlendStateCreateInfo()
    blend.attachmentCount = 1u

    var gp = VkGraphicsPipelineCreateInfo()
    gp.stageCount = 2u
    var h : VkPipeline
    unsafe {
        vpstate.pViewports = addr(viewport)
        vpstate.pScissors = addr(scissor)
        blend.pAttachments = addr(blend_att)
        gp.pStages = addr(stages[0])
        gp.pVertexInputState = addr(vinput)
        gp.pInputAssemblyState = addr(iasm)
        gp.pViewportState = addr(vpstate)
        gp.pRasterizationState = addr(raster)
        gp.pMultisampleState = addr(msaa)
        gp.pDepthStencilState = addr(depth_state)
        gp.pColorBlendState = addr(blend)
        gp.layout = boost_value_to_vk(layout)
        gp.renderPass = boost_value_to_vk(rp)
        gp.subpass = subpass
        var pci : array<VkGraphicsPipelineCreateInfo>
        pci |> push(gp)
        vk_check(vkCreateGraphicsPipelines(boost_value_to_vk(device), null, 1u, addr(pci[0]), null, addr(h)), null)
        delete pci
    }
    delete stages
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    b._device = unsafe(reinterpret<uint64>(boost_value_to_vk(device)))
    return <- b
}

// ===== per-frame UBO updates =====

//! Set the shader-side xform + scene globals from time + camera_t, then marshal them into the two
//! UBOs. Lights orbit on a tilted circle around the scene origin; the sun direction is fixed.
def public update_deferred_uniforms(res : DeferredResources; device : Device; time, camera_t : float) {
    let camera_angle = camera_t * 2.0f * PI
    let camera_r = 5.0f
    let cam_x = camera_r * cos(camera_angle)
    let cam_z = camera_r * sin(camera_angle)
    let cam_y = 2.0f + sin(camera_angle * 2.0f) * 0.6f
    let cam_pos = float3(cam_x, cam_y, cam_z)

    let sun_dir = vec3_normalize(float3(-0.4f, 1.0f, 0.3f))
    let sun_eye = float3(sun_dir.x * 8.0f, sun_dir.y * 8.0f, sun_dir.z * 8.0f)
    let sun_view = look_at_rh(sun_eye, float3(0.0f, 0.0f, 0.0f), float3(0.0f, 1.0f, 0.0f))
    let sun_proj = ortho_vk(-4.0f, 4.0f, -4.0f, 4.0f, 0.1f, 20.0f)
    let light_vp = mat4_mul(sun_proj, sun_view)

    xform.view = look_at_rh(cam_pos, float3(0.0f, 1.0f, 0.0f), float3(0.0f, 1.0f, 0.0f))
    xform.proj = perspective_vk(60.0f * PI / 180.0f, float(DEFERRED_W) / float(DEFERRED_H), 0.1f, 50.0f)
    xform.light_vp = light_vp
    gbuffer_vs_bind_uniform(device, res.xform_ubo.memory)

    scene.light_vp = light_vp
    scene.light_dir = float4(sun_dir.x, sun_dir.y, sun_dir.z, 0.0f)
    scene.camera_pos = float4(cam_pos.x, cam_pos.y, cam_pos.z, time)
    // Three colored point lights orbit at radius 2.5, height 1.2 (just above the floor and below
    // the cube's centre). Range 6, falloff 1.5 -- gives a wide, soft, visible coloured pool. The
    // 4x intensity bump (vs the original 1.0) is what makes them visibly punch through the sun.
    let lt = time * 0.5f
    let lr = 2.5f
    let lh = 1.2f
    scene.pos0 = float4(lr * cos(lt),          lh, lr * sin(lt),          6.0f)
    scene.col0 = float4(4.0f, 0.8f, 0.6f, 1.5f)
    scene.pos1 = float4(lr * cos(lt + 2.094f), lh, lr * sin(lt + 2.094f), 6.0f)
    scene.col1 = float4(0.6f, 3.6f, 1.0f, 1.5f)
    scene.pos2 = float4(lr * cos(lt + 4.188f), lh, lr * sin(lt + 4.188f), 6.0f)
    scene.col2 = float4(0.8f, 1.2f, 4.0f, 1.5f)
    lighting_fs_bind_uniform(device, res.scene_ubo.memory)
}

// ===== per-frame recording =====

//! Record shadow pass (depth-only, casters) + deferred multi-subpass pass (G-buffer + SSAO +
//! lighting). The caller must have set `dbg.debug_mode` before invoking; lighting_fs_push_constants
//! pushes that.
def public record_deferred_render(res : DeferredResources; cmd : CommandBuffer) {
    // ---- shadow pass (depth-only) ----
    var sh_clears <- [clear_depth(1.0f)]
    record_render_pass(cmd, res.rp_shadow, res.fb_shadow, full_area(SHADOW_W, SHADOW_H), sh_clears) {
        cmd_bind_pipeline(cmd, res.shadow_pipeline)
        let s_sets <- [vk_value_to_boost(res.shadow_set)]
        var no_dyn : array<uint>
        cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.GRAPHICS, res.shadow_pipe_layout, 0u, s_sets, no_dyn)
        draw_casters(res, cmd, res.shadow_pipe_layout)
    }
    delete sh_clears

    // ---- deferred pass (G-buffer -> SSAO -> lighting) ----
    var def_clears <- [
        clear_color(0.0f, 0.0f, 0.0f, 1.0f),     // 0: albedo bg
        clear_color(0.0f, 0.0f, 0.0f, 0.0f),     // 1: normal bg (zero vec)
        clear_color(0.0f, 0.0f, 0.0f, 0.0f),     // 2: world-pos bg
        clear_depth(1.0f),                        // 3: depth
        clear_color(1.0f, 0.0f, 0.0f, 0.0f),     // 4: ssao bg (1 = no darkening)
        clear_color(0.05f, 0.05f, 0.08f, 1.0f)   // 5: final colour bg (will be overwritten by lighting)
    ]
    record_render_pass(cmd, res.rp_deferred, res.fb_deferred, full_area(DEFERRED_W, DEFERRED_H), def_clears) {
        // subpass 0: G-buffer (draw all geometry)
        cmd_bind_pipeline(cmd, res.gbuffer_pipeline)
        let g_sets <- [vk_value_to_boost(res.gbuffer_set)]
        var no_dyn : array<uint>
        cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.GRAPHICS, res.gbuffer_pipe_layout, 0u, g_sets, no_dyn)
        draw_casters(res, cmd, res.gbuffer_pipe_layout)

        // subpass 1: SSAO
        cmd_next_subpass(cmd, VkSubpassContents.INLINE)
        cmd_bind_pipeline(cmd, res.ssao_pipeline)
        let ssao_s0 <- [vk_value_to_boost(res.ssao_set_input)]
        cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.GRAPHICS, res.ssao_pipe_layout, 0u, ssao_s0, no_dyn)
        let ssao_s1 <- [vk_value_to_boost(res.ssao_set_scene)]
        cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.GRAPHICS, res.ssao_pipe_layout, 1u, ssao_s1, no_dyn)
        cmd_draw(cmd, 3u)

        // subpass 2: lighting
        cmd_next_subpass(cmd, VkSubpassContents.INLINE)
        cmd_bind_pipeline(cmd, res.lighting_pipeline)
        let l_sets0 <- [vk_value_to_boost(res.lighting_set0)]
        cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.GRAPHICS, res.lighting_pipe_layout, 0u, l_sets0, no_dyn)
        let l_sets1 <- [vk_value_to_boost(res.lighting_set1)]
        cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.GRAPHICS, res.lighting_pipe_layout, 1u, l_sets1, no_dyn)
        lighting_fs_push_constants(cmd, res.lighting_pipe_layout)
        cmd_draw(cmd, 3u)
    }
    delete def_clears
}

//! Draw cube + floor with the appropriate ObjectPush per object. Used by BOTH the shadow pass and
//! the gbuffer pass; the only difference is the bound pipeline.
def private draw_casters(res : DeferredResources; cmd : CommandBuffer; pipe_layout : PipelineLayout) {
    // Cube: rotates around Y, hovers at y=1
    op.model = mat4_mul(translate_m4(float3(0.0f, 1.0f, 0.0f)), rotate_y_m4(scene.camera_pos.w * 0.6f))
    op.material = 0
    let cube_vbufs <- [weak_copy(res.cube_vb.buffer)]
    var cube_offs : array<uint64>
    cube_offs |> push(0ul)
    cmd_bind_vertex_buffers(cmd, 0u, cube_vbufs, cube_offs)
    cmd_bind_index_buffer(cmd, weak_copy(res.cube_ib.buffer), 0ul, VkIndexType.UINT16)
    push_object_pc(cmd, pipe_layout)
    cmd_draw_indexed(cmd, uint(N_CUBE_INDICES), 1u, 0u, 0, 0u)

    // Floor: identity transform
    op.model = identity_m4()
    op.material = 1
    let floor_vbufs <- [weak_copy(res.floor_vb.buffer)]
    var floor_offs : array<uint64>
    floor_offs |> push(0ul)
    cmd_bind_vertex_buffers(cmd, 0u, floor_vbufs, floor_offs)
    cmd_bind_index_buffer(cmd, weak_copy(res.floor_ib.buffer), 0ul, VkIndexType.UINT16)
    push_object_pc(cmd, pipe_layout)
    cmd_draw_indexed(cmd, uint(N_FLOOR_INDICES), 1u, 0u, 0, 0u)
}

def private push_object_pc(cmd : CommandBuffer; pipe_layout : PipelineLayout) {
    // ObjectPush is in shadow_vs + gbuffer_vs; daslang reflection gives us the per-pipeline range.
    // Use the gbuffer-derived helper (which writes the full 68-byte range covering both fields).
    gbuffer_vs_push_constants(cmd, pipe_layout)
}

// ===== one-shot render (pixel oracle entry) =====

def public render_deferred_cube(time, camera_t : float; debug_mode : int) : array<uint8> {
    var inscope ctx <- build_deferred_context()
    return <- render_deferred_frame(ctx, time, camera_t, debug_mode)
}

def public render_deferred_frame(var ctx : DeferredContext; time, camera_t : float; debug_mode : int) : array<uint8> {
    update_deferred_uniforms(ctx.res, ctx.device, time, camera_t)
    dbg.debug_mode = debug_mode
    var pixels : array<uint8>
    run_cmd_sync(ctx.device, ctx.pool, ctx.queue) $(cmd) {
        record_deferred_render(ctx.res, cmd)
        copy_image_to_buffer(cmd, ctx.res.final_color.image, ctx.res.readback, DEFERRED_W, DEFERRED_H)
    }
    map_memory_to_array(ctx.device, ctx.res.readback.memory, ctx.res.buf_size) $(m) {
        pixels := m
    }
    return <- pixels
}

def public build_deferred_context() : DeferredContext {
    if (volkInitialize() != 0) {
        panic("no Vulkan loader")
    }
    var inscope instance <- create_instance("dasVulkan tutorial 10", make_api_version(1u, 3u, 0u))
    volkLoadInstance(boost_value_to_vk(instance))
    let phys = select_physical_device(instance)
    let gfx = select_graphics_queue_family(phys)
    var inscope device <- create_device(phys, gfx)
    volkLoadDevice(boost_value_to_vk(device))
    var queue = get_device_queue(device, gfx, 0u)
    var poolci : CommandPoolCreateInfo
    poolci.queueFamilyIndex = gfx
    var inscope pool <- create_command_pool(device, poolci)
    var inscope res <- build_deferred_resources(device, phys, queue, pool)
    return <- DeferredContext(
        instance <- instance, device <- device, queue = queue, pool <- pool, res <- res)
}

// ===== UI helpers =====

def public px(pixels : array<uint8>; x, y : int) : int3 {
    let p = (y * DEFERRED_W + x) * 4
    return int3(int(pixels[p]), int(pixels[p + 1]), int(pixels[p + 2]))
}

def public debug_mode_label(m : int) : string {
    if (m == DBG_ALBEDO)   return "albedo"
    if (m == DBG_NORMAL)   return "normal"
    if (m == DBG_WORLDPOS) return "world-pos"
    if (m == DBG_SSAO)     return "ssao"
    if (m == DBG_LIGHT)    return "lighting-only"
    return "lit"
}

def public next_debug_mode(m : int) : int {
    return (m + 1) % DBG_MODE_COUNT
}

// ===== 7-state UX toggle (auto-cycle + 6 fixed modes) =====

enum public DeferredToggle {
    auto_toggle
    force_lit
    force_albedo
    force_normal
    force_worldpos
    force_ssao
    force_light
}

let public AUTO_PERIOD = 2.5f

def public deferred_active_mode(toggle : DeferredToggle; t : float) : int {
    if (toggle == DeferredToggle.force_lit)      return DBG_LIT
    if (toggle == DeferredToggle.force_albedo)   return DBG_ALBEDO
    if (toggle == DeferredToggle.force_normal)   return DBG_NORMAL
    if (toggle == DeferredToggle.force_worldpos) return DBG_WORLDPOS
    if (toggle == DeferredToggle.force_ssao)     return DBG_SSAO
    if (toggle == DeferredToggle.force_light)    return DBG_LIGHT
    return int(floor(t / AUTO_PERIOD)) % DBG_MODE_COUNT
}

def public deferred_toggle_label(toggle : DeferredToggle) : string {
    if (toggle == DeferredToggle.force_lit)      return "FORCE LIT"
    if (toggle == DeferredToggle.force_albedo)   return "FORCE ALBEDO"
    if (toggle == DeferredToggle.force_normal)   return "FORCE NORMAL"
    if (toggle == DeferredToggle.force_worldpos) return "FORCE WORLD-POS"
    if (toggle == DeferredToggle.force_ssao)     return "FORCE SSAO"
    if (toggle == DeferredToggle.force_light)    return "FORCE LIGHT"
    return "AUTO"
}

def public next_deferred_toggle(toggle : DeferredToggle) : DeferredToggle {
    if (toggle == DeferredToggle.auto_toggle)    return DeferredToggle.force_lit
    if (toggle == DeferredToggle.force_lit)      return DeferredToggle.force_albedo
    if (toggle == DeferredToggle.force_albedo)   return DeferredToggle.force_normal
    if (toggle == DeferredToggle.force_normal)   return DeferredToggle.force_worldpos
    if (toggle == DeferredToggle.force_worldpos) return DeferredToggle.force_ssao
    if (toggle == DeferredToggle.force_ssao)     return DeferredToggle.force_light
    return DeferredToggle.auto_toggle
}
