options gen2
options indenting = 4

// Tutorial 14 render path: the GPU-tessellated Utah teapot. No vertex buffer, no index buffer -- a
// single cmd_draw_mesh_tasks_ext dispatches one task workgroup that selects the surviving Bezier
// patches and dispatches a mesh workgroup per patch; each mesh workgroup evaluates its bicubic patch
// on a 7x7 grid (on-GPU tessellation) and emits the triangles. A depth attachment resolves the
// non-convex teapot's self-occlusion. The CI gate (test_teapot.das) asserts the teapot silhouette is
// lit at the center and the corners are background.

module teapot_tut

require vulkan public
require vulkan/vulkan_boost public
require vulkan/vulkan_reflect
require teapot_tut_shaders
require teapot_data
require math

let public TEAPOT_W = 512
let public TEAPOT_H = 512
let TEAPOT_COLOR_FMT = VkFormat.R8G8B8A8_UNORM
let TEAPOT_DEPTH_FMT = VkFormat.D32_SFLOAT
let TEAPOT_UBO_SIZE = 8352ul    // std140: mvp(64)+model(64)+camera(16)+light(16)+cp[512]*16(8192)

// ===== matrix helpers (column-major, m[col] = column vector) =====

def perspective_vk(fov_y, aspect, znear, zfar : float) : float4x4 {
    let f = 1.0f / tan(fov_y * 0.5f)
    let nf = 1.0f / (znear - zfar)
    var m : float4x4
    m[0] = float4(f / aspect, 0.0f, 0.0f, 0.0f)
    m[1] = float4(0.0f, -f, 0.0f, 0.0f)                 // Vulkan NDC has +Y down
    m[2] = float4(0.0f, 0.0f, zfar * nf, -1.0f)
    m[3] = float4(0.0f, 0.0f, znear * zfar * nf, 0.0f)
    return m
}

def v3_sub(a, b : float3) : float3 => float3(a.x - b.x, a.y - b.y, a.z - b.z)
def v3_cross(a, b : float3) : float3 => float3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
def v3_dot(a, b : float3) : float => a.x * b.x + a.y * b.y + a.z * b.z
def v3_norm(v : float3) : float3 {
    let len = sqrt(v3_dot(v, v))
    return float3(v.x / len, v.y / len, v.z / len)
}

def look_at_rh(eye, center, up : float3) : float4x4 {
    let f = v3_norm(v3_sub(center, eye))
    let s = v3_norm(v3_cross(f, up))
    let u = v3_cross(s, f)
    var m : float4x4
    m[0] = float4(s.x, u.x, -f.x, 0.0f)
    m[1] = float4(s.y, u.y, -f.y, 0.0f)
    m[2] = float4(s.z, u.z, -f.z, 0.0f)
    m[3] = float4(-v3_dot(s, eye), -v3_dot(u, eye), v3_dot(f, eye), 1.0f)
    return m
}

def mat_identity : float4x4 {
    var m : float4x4
    m[0] = float4(1.0f, 0.0f, 0.0f, 0.0f)
    m[1] = float4(0.0f, 1.0f, 0.0f, 0.0f)
    m[2] = float4(0.0f, 0.0f, 1.0f, 0.0f)
    m[3] = float4(0.0f, 0.0f, 0.0f, 1.0f)
    return m
}
def mat_translate(t : float3) : float4x4 {
    var m = mat_identity()
    m[3] = float4(t.x, t.y, t.z, 1.0f)
    return m
}
def mat_scale(s : float) : float4x4 {
    var m = mat_identity()
    m[0].x = s; m[1].y = s; m[2].z = s
    return m
}
def mat_rot_x(a : float) : float4x4 {
    let c = cos(a); let s = sin(a)
    var m = mat_identity()
    m[1] = float4(0.0f, c, s, 0.0f)
    m[2] = float4(0.0f, -s, c, 0.0f)
    return m
}
def mat_rot_y(a : float) : float4x4 {
    let c = cos(a); let s = sin(a)
    var m = mat_identity()
    m[0] = float4(c, 0.0f, -s, 0.0f)
    m[2] = float4(s, 0.0f, c, 0.0f)
    return m
}

//! Fit the raw Newell teapot into a unit-ish, Y-up, origin-centered model and spin it about the
//! vertical axis by `angle`. Order (applied right-to-left to a model point): center -> scale ->
//! reorient Z-up to Y-up -> spin.
def teapot_model(angle : float) : float4x4 {
    let fit = mat_scale(2.0f / TEAPOT_EXTENT)
    let center = mat_translate(float3(-TEAPOT_CENTER.x, -TEAPOT_CENTER.y, -TEAPOT_CENTER.z))
    let reorient = mat_rot_x(-PI * 0.5f)              // Newell Z-up -> Y-up
    let spin = mat_rot_y(angle)
    return spin * reorient * fit * center
}

// ===== reusable resources =====

struct public TeapotResources {
    color       : OffscreenTarget
    depth       : OffscreenDepth
    render_pass : RenderPass
    framebuffer : Framebuffer
    ubo         : HostBuffer
    set_layouts : array<DescriptorSetLayout>
    desc_pool   : DescriptorPool
    desc_set    : VkDescriptorSet
    pipe_layout : PipelineLayout
    pipeline    : Pipeline
    readback    : HostBuffer
    buf_size    : uint64
}

def public finalize(var r : TeapotResources) {
    unsafe {
        delete r.readback
        delete r.pipeline
        delete r.pipe_layout
        delete r.desc_pool
        delete r.set_layouts
        delete r.ubo
        delete r.framebuffer
        delete r.render_pass
        delete r.depth
        delete r.color
    }
}

struct public TeapotContext {
    instance : Instance
    device   : Device
    queue    : VkQueue
    pool     : CommandPool
    res      : TeapotResources
}

def public finalize(var ctx : TeapotContext) {
    unsafe {
        delete ctx.res
        delete ctx.pool
        delete ctx.device
        delete ctx.instance
    }
}

//! Build the teapot render resources against a caller-owned (device, phys, queue, pool). Uploads the
//! Newell control net into the UBO's cp[] once; the per-frame transform is restamped each frame.
def public build_teapot_resources(device : Device; phys : VkPhysicalDevice) : TeapotResources {
    var inscope color <- build_offscreen_target(device, phys, TEAPOT_W, TEAPOT_H, TEAPOT_COLOR_FMT)
    var inscope depth <- build_offscreen_depth(device, phys, TEAPOT_W, TEAPOT_H, TEAPOT_DEPTH_FMT)
    var inscope render_pass <- create_render_pass_color_depth(device, TEAPOT_COLOR_FMT, TEAPOT_DEPTH_FMT)
    var inscope framebuffer <- create_framebuffer(device, FramebufferCreateInfo(
        renderPass = weak_copy(render_pass),
        pAttachments <- [weak_copy(color.view), weak_copy(depth.view)],
        width = uint(TEAPOT_W),
        height = uint(TEAPOT_H),
        layers = 1u))

    var ubo_usage : VkBufferUsageFlags
    ubo_usage.uniform_buffer = true
    var inscope ubo_buf <- create_host_buffer(device, phys, TEAPOT_UBO_SIZE, ubo_usage)

    // upload the static control net into the UBO global's cp[] once (persists across frames)
    var cps <- teapot_control_points()
    for (i in range(length(cps))) {
        ubo.cp[i] = float4(cps[i].x, cps[i].y, cps[i].z, 0.0f)
    }
    delete cps

    // reflection-driven descriptor + pipeline layout (UBO reached by task + mesh + fragment)
    var reflections <- [decode_reflection(teapot_task_spv_reflect),
                        decode_reflection(teapot_mesh_spv_reflect),
                        decode_reflection(teapot_frag_spv_reflect)]
    var inscope set_layouts <- build_descriptor_set_layouts(device, reflections)

    var dpci : DescriptorPoolCreateInfo
    dpci.maxSets = 1u
    var ps0 : DescriptorPoolSize
    ps0.type_ = VkDescriptorType.UNIFORM_BUFFER
    ps0.descriptorCount = 1u
    dpci.pPoolSizes |> push(ps0)
    var inscope desc_pool <- create_descriptor_pool(device, dpci)

    var dsai = VkDescriptorSetAllocateInfo()
    dsai.descriptorPool = boost_value_to_vk(desc_pool)
    dsai.descriptorSetCount = 1u
    var raw_set_layout = boost_value_to_vk(set_layouts[0])
    var raw_set : VkDescriptorSet
    unsafe {
        dsai.pSetLayouts = addr(raw_set_layout)
        vk_check(vkAllocateDescriptorSets(boost_value_to_vk(device), dsai, addr(raw_set)), null)
    }

    var writes : array<WriteDescriptorSet>
    var w0 : WriteDescriptorSet
    w0.dstSet = vk_value_to_boost(raw_set)
    w0.dstBinding = 0u
    w0.descriptorType = VkDescriptorType.UNIFORM_BUFFER
    w0.descriptorCount = 1u
    var binfo : DescriptorBufferInfo
    binfo.buffer = weak_copy(ubo_buf.buffer)
    binfo.range_ = TEAPOT_UBO_SIZE
    w0.pBufferInfo |> push(binfo)
    writes |> emplace(w0)
    var no_copies : array<CopyDescriptorSet>
    update_descriptor_sets(device, writes, no_copies)

    var inscope pipe_layout <- build_pipeline_layout(device, set_layouts, reflections)
    delete reflections

    var inscope task <- create_shader_module(device, teapot_task_spv)
    var inscope mesh <- create_shader_module(device, teapot_mesh_spv)
    var inscope frag <- create_shader_module(device, teapot_frag_spv)
    var inscope pipeline <- create_mesh_pipeline(device, render_pass, pipe_layout, task, mesh, frag,
        TEAPOT_W, TEAPOT_H, false, true)        // dynamic_viewport=false, enable_depth=true

    let buf_size = uint64(TEAPOT_W * TEAPOT_H * 4)
    var inscope readback <- create_host_buffer(device, phys, buf_size)

    return <- TeapotResources(
        color <- color, depth <- depth, render_pass <- render_pass, framebuffer <- framebuffer,
        ubo <- ubo_buf, set_layouts <- set_layouts, desc_pool <- desc_pool, desc_set = raw_set,
        pipe_layout <- pipe_layout, pipeline <- pipeline, readback <- readback, buf_size = buf_size)
}

//! Probe whether this machine's Vulkan device supports VK_EXT_mesh_shader (extension + meshShader/
//! taskShader feature bits), so the pixel-oracle can skip cleanly on a driver that lacks it instead of
//! panicking in create_device_mesh_shader. Creates and tears down a throwaway instance + physical device.
def public mesh_shader_available() : bool {
    if (volkInitialize() != 0) {
        return false
    }
    var inscope instance <- create_instance("dasVulkan tutorial 14 probe", make_api_version(1u, 3u, 0u))
    volkLoadInstance(boost_value_to_vk(instance))
    var count = 0u
    vkEnumeratePhysicalDevices(boost_value_to_vk(instance), count, null)
    if (count == 0u) {
        return false
    }
    let phys = select_physical_device(instance)
    return mesh_shader_supported(phys)
}

def public build_teapot_context() : TeapotContext {
    if (volkInitialize() != 0) {
        panic("no Vulkan loader")
    }
    var inscope instance <- create_instance("dasVulkan tutorial 14", make_api_version(1u, 3u, 0u))
    volkLoadInstance(boost_value_to_vk(instance))
    let phys = select_physical_device(instance)
    let gfx = select_graphics_queue_family(phys)
    var inscope device <- create_device_mesh_shader(phys, gfx)
    volkLoadDevice(boost_value_to_vk(device))
    var queue = get_device_queue(device, gfx, 0u)
    var poolci : CommandPoolCreateInfo
    poolci.queueFamilyIndex = gfx
    var inscope pool <- create_command_pool(device, poolci)
    var inscope res <- build_teapot_resources(device, phys)
    return <- TeapotContext(
        instance <- instance, device <- device, queue = queue, pool <- pool, res <- res)
}

//! Per-frame uniform prep: spin the teapot by `time`, set the camera + light + debug flag, upload.
def public update_teapot_uniforms(res : TeapotResources; device : Device; time : float; debug_tint : bool) {
    let eye = float3(0.0f, 0.55f, 3.8f)
    let model = teapot_model(time * 0.6f)
    let view = look_at_rh(eye, float3(0.0f, 0.05f, 0.0f), float3(0.0f, 1.0f, 0.0f))
    let proj = perspective_vk(45.0f * PI / 180.0f, float(TEAPOT_W) / float(TEAPOT_H), 0.1f, 100.0f)
    ubo.mvp = proj * view * model
    ubo.model = model
    ubo.camera = float4(eye.x, eye.y, eye.z, debug_tint ? 1.0f : 0.0f)
    ubo.light = float4(v3_norm(float3(0.4f, 0.9f, 0.5f)), 0.0f)
    teapot_mesh_bind_uniform(device, res.ubo.memory)
}

def public record_teapot_render_pass(res : TeapotResources; cmd : CommandBuffer) {
    var clears <- [clear_color(0.06f, 0.07f, 0.10f, 1.0f), clear_depth(1.0f)]
    record_render_pass(cmd, res.render_pass, res.framebuffer, full_area(TEAPOT_W, TEAPOT_H), clears) {
        cmd_bind_pipeline(cmd, res.pipeline)
        let sets <- [vk_value_to_boost(res.desc_set)]
        var no_dyn : array<uint>
        cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.GRAPHICS, res.pipe_layout, 0u, sets, no_dyn)
        cmd_draw_mesh_tasks_e_x_t(cmd, 1u, 1u, 1u)
    }
    delete clears
}

def public render_teapot_frame(var ctx : TeapotContext; time : float; debug_tint : bool) : array<uint8> {
    update_teapot_uniforms(ctx.res, ctx.device, time, debug_tint)
    var pixels : array<uint8>
    run_cmd_sync(ctx.device, ctx.pool, ctx.queue) $(cmd) {
        record_teapot_render_pass(ctx.res, cmd)
        copy_image_to_buffer(cmd, ctx.res.color.image, ctx.res.readback, TEAPOT_W, TEAPOT_H)
    }
    map_memory_to_array(ctx.device, ctx.res.readback.memory, ctx.res.buf_size) $(m) {
        pixels := m
    }
    return <- pixels
}

//! One-shot: build a context and render one frame (the [test] uses this).
def public render_teapot(time : float; debug_tint : bool = false) : array<uint8> {
    var inscope ctx <- build_teapot_context()
    return <- render_teapot_frame(ctx, time, debug_tint)
}

//! Sample the RGB of pixel (x,y) from a TEAPOT_W*TEAPOT_H RGBA8 buffer.
def public px(pixels : array<uint8>; x, y : int) : int3 {
    let p = (y * TEAPOT_W + x) * 4
    return int3(int(pixels[p]), int(pixels[p + 1]), int(pixels[p + 2]))
}
