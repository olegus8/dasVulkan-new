options gen2
options indenting = 4

// A graphics pipeline built ENTIRELY from #53's boost view structs -- every
// pipeline state through vulkan_structs (no create_graphics_pipeline_* helper, no
// raw Vk*CreateInfo) -- batch-created via create_graphics_pipelines and proven by
// exact pixels. The two batch entries differ only in color-blend state:
//   [0] CONSTANT_COLOR blend whose blendConstants are exact UNORM8 values -- a
//       correct render proves the float[4] fixed-array member copy reached the
//       driver (the load-bearing check for the fixed-array view path)
//   [1] blend disabled -- pure white, proving batch entry order is preserved
// The fullscreen white triangle covers every pixel, so both frames are
// exact-analytic over the full target.

require dastest/testing_boost public
require scene_helpers
require flat_shaders

[test]
def test_pipeline_boost_structs(t : T?) {
    if (volkInitialize() != 0) {
        t |> failure("no Vulkan loader")
        return
    }
    var inscope instance <- create_instance("dasVulkan test", make_api_version(1u, 3u, 0u))
    volkLoadInstance(boost_value_to_vk(instance))
    let phys = select_physical_device(instance)
    let gfx = select_graphics_queue_family(phys)
    var inscope device <- create_device(phys, gfx)
    volkLoadDevice(boost_value_to_vk(device))
    let queue = get_device_queue(device, gfx, 0u)
    let fmt = VkFormat.R8G8B8A8_UNORM

    var inscope target <- build_offscreen_target(device, phys, TRI_W, TRI_H, fmt)
    var inscope render_pass <- create_render_pass_single_color(device, fmt)
    var fbci = FramebufferCreateInfo(renderPass = weak_copy(render_pass),
        pAttachments <- [weak_copy(target.view)],
        width = uint(TRI_W), height = uint(TRI_H), layers = 1u)
    var inscope framebuffer <- create_framebuffer(device, fbci)

    var inscope vert <- create_shader_module(device, flat_vert_spv)
    var inscope frag <- create_shader_module(device, flat_frag_spv)
    var inscope layout <- create_pipeline_layout(device)

    // shared fixed-function state, one local per boost view struct; the opt-ptr
    // fields below point at these locals (each view clone-copies its pointee)
    var st_vert = PipelineShaderStageCreateInfo(module_ = weak_copy(vert), pName = "main")
    st_vert.stage.vertex = true
    var st_frag = PipelineShaderStageCreateInfo(module_ = weak_copy(frag), pName = "main")
    st_frag.stage.fragment = true

    var vin_a : PipelineVertexInputStateCreateInfo
    var vin_b : PipelineVertexInputStateCreateInfo
    var ia = PipelineInputAssemblyStateCreateInfo(topology = VkPrimitiveTopology.TRIANGLE_LIST)
    var vp : PipelineViewportStateCreateInfo
    var vport = Viewport(width = float(TRI_W), height = float(TRI_H), maxDepth = 1.0f)
    vp.pViewports |> push(vport)
    var scissor : Rect2D
    scissor.extent.width = uint(TRI_W)
    scissor.extent.height = uint(TRI_H)
    vp.pScissors |> push(scissor)
    var rs = PipelineRasterizationStateCreateInfo(polygonMode = VkPolygonMode.FILL, lineWidth = 1.0f)
    var ms : PipelineMultisampleStateCreateInfo
    ms.rasterizationSamples._1 = true

    // exact-UNORM8 blend constants: 255 * (64/255, 128/255, 192/255) is integral,
    // so the blended pixel must be exactly (64, 128, 192) on any conformant driver
    var att_const = PipelineColorBlendAttachmentState(blendEnable = 1u,
        srcColorBlendFactor = VkBlendFactor.CONSTANT_COLOR,
        dstColorBlendFactor = VkBlendFactor.ZERO,
        colorBlendOp = VkBlendOp.ADD,
        srcAlphaBlendFactor = VkBlendFactor.ONE,
        dstAlphaBlendFactor = VkBlendFactor.ZERO,
        alphaBlendOp = VkBlendOp.ADD)
    att_const.colorWriteMask.r = true
    att_const.colorWriteMask.g = true
    att_const.colorWriteMask.b = true
    att_const.colorWriteMask.a = true
    var cb_const : PipelineColorBlendStateCreateInfo
    cb_const.pAttachments |> push(att_const)
    cb_const.blendConstants = fixed_array(64.0f / 255.0f, 128.0f / 255.0f, 192.0f / 255.0f, 1.0f)

    var att_plain : PipelineColorBlendAttachmentState
    att_plain.colorWriteMask.r = true
    att_plain.colorWriteMask.g = true
    att_plain.colorWriteMask.b = true
    att_plain.colorWriteMask.a = true
    var cb_plain : PipelineColorBlendStateCreateInfo
    cb_plain.pAttachments |> push(att_plain)

    var gp_const = GraphicsPipelineCreateInfo(layout = weak_copy(layout),
        renderPass = weak_copy(render_pass))
    gp_const.pStages <- [st_vert, st_frag]
    unsafe {
        gp_const.pVertexInputState = addr(vin_a)
        gp_const.pInputAssemblyState = addr(ia)
        gp_const.pViewportState = addr(vp)
        gp_const.pRasterizationState = addr(rs)
        gp_const.pMultisampleState = addr(ms)
        gp_const.pColorBlendState = addr(cb_const)
    }
    var gp_plain = GraphicsPipelineCreateInfo(layout = weak_copy(layout),
        renderPass = weak_copy(render_pass))
    gp_plain.pStages <- [st_vert, st_frag]
    unsafe {
        gp_plain.pVertexInputState = addr(vin_b)
        gp_plain.pInputAssemblyState = addr(ia)
        gp_plain.pViewportState = addr(vp)
        gp_plain.pRasterizationState = addr(rs)
        gp_plain.pMultisampleState = addr(ms)
        gp_plain.pColorBlendState = addr(cb_plain)
    }
    var gpcis <- [ <- gp_const, <- gp_plain]
    let no_cache : PipelineCache
    var inscope pipelines <- create_graphics_pipelines(device, no_cache, gpcis)
    t |> equal(length(pipelines), 2)
    t |> success(pipelines[0]._vk != 0ul && pipelines[1]._vk != 0ul, "both graphics pipelines are non-null")
    t |> success(pipelines[0]._vk != pipelines[1]._vk, "batch-created graphics pipelines are distinct")

    let buf_size = uint64(TRI_W * TRI_H * 4)
    var inscope readback <- create_host_buffer(device, phys, buf_size)
    var poolci : CommandPoolCreateInfo
    poolci.queueFamilyIndex = gfx
    var inscope pool <- create_command_pool(device, poolci)

    var pixels_const : array<uint8>
    run_cmd_sync(device, pool, queue) $(cmd) {
        record_render_pass(cmd, render_pass, framebuffer, full_area(TRI_W, TRI_H), clear_color(0.1f, 0.1f, 0.15f, 1.0f)) {
            cmd_bind_pipeline(cmd, pipelines[0])
            cmd_draw(cmd, 3u)
        }
        copy_image_to_buffer(cmd, target.image, readback, TRI_W, TRI_H)
    }
    map_memory_to_array(device, readback.memory, buf_size) $(m) {
        pixels_const := m
    }
    t |> assert_pixels_exact(pixels_const, TRI_W, TRI_H, "CONSTANT_COLOR blend (blendConstants float[4])") $(_x, _y) {
        return int4(64, 128, 192, 255)
    }
    delete pixels_const

    var pixels_plain : array<uint8>
    run_cmd_sync(device, pool, queue) $(cmd) {
        record_render_pass(cmd, render_pass, framebuffer, full_area(TRI_W, TRI_H), clear_color(0.1f, 0.1f, 0.15f, 1.0f)) {
            cmd_bind_pipeline(cmd, pipelines[1])
            cmd_draw(cmd, 3u)
        }
        copy_image_to_buffer(cmd, target.image, readback, TRI_W, TRI_H)
    }
    map_memory_to_array(device, readback.memory, buf_size) $(m) {
        pixels_plain := m
    }
    t |> assert_pixels_exact(pixels_plain, TRI_W, TRI_H, "blend-disabled entry (batch order preserved)") $(_x, _y) {
        return int4(255, 255, 255, 255)
    }
    delete pixels_plain
}
