options gen2
options indenting = 4

// Tutorial 02, present method TWO of two: SAMPLE-AS-TEXTURE. The compute shader writes the fractal into a
// storage image once; here a graphics pass draws a single full-screen triangle whose fragment shader
// SAMPLES that image as a texture (mandelbrot_view_shaders.das). The result lands on the swapchain through
// the ordinary render pass, so this reuses draw_frame, the render pass, the framebuffers and the graphics
// pipeline wholesale -- it adds only a sampler, one combined-image-sampler descriptor, and two tiny
// shaders. Compare show_mandelbrot_blit.das, which instead blits the image straight onto the swapchain.
//
// Needs a display + the glfw module, so it lives in this window/ subfolder the tutorials .das_test skips
// in CI (the lavapipe CI daslang build is -DDAS_GLFW_DISABLED=ON). Run from the daslang root:
//   daslang -load_module <path-to-dasVulkan> <path-to>/tutorials/02_mandelbrot/window/show_mandelbrot_sampled.das
// Close the window to exit.

require glfw/glfw_boost
require vulkan
require vulkan/vulkan_boost
require vulkan/vulkan_window
require ../mandelbrot_tut_shaders.das
require mandelbrot_view_shaders
require mandelbrot_compute
require daslib/defer

[export]
def main {
    if (glfwInit() == 0) {
        panic("can't init glfw")
    }
    defer() { glfwTerminate() }
    if (volkInitialize() != 0) {
        panic("no vulkan loader")
    }
    if (glfwVulkanSupported() == 0) {
        panic("glfw reports no vulkan support")
    }
    glfwWindowHint(int(GLFW_CLIENT_API), GLFW_NO_API)
    glfwWindowHint(int(GLFW_RESIZABLE), GLFW_TRUE)
    var window = glfwCreateWindow(MAND_DIM, MAND_DIM, "dasVulkan tutorial 02 - Mandelbrot (sampled)", null, null)
    if (window == null) {
        panic("can't create window")
    }
    defer() { glfwDestroyWindow(window) }

    var ext_count = 0u
    let glfw_exts = glfwGetRequiredInstanceExtensions(unsafe(addr(ext_count)))
    var inst_exts : array<string>
    inst_exts |> reserve(int(ext_count))
    for (i in range(int(ext_count))) {
        unsafe {
            inst_exts |> push(glfw_exts[i])
        }
    }
    var inscope instance <- create_instance("dasVulkan tutorial 02 (sampled)", make_api_version(1u, 3u, 0u), inst_exts)
    volkLoadInstance(boost_value_to_vk(instance))

    var inscope surface <- create_surface(instance, glfwGetNativeWindow(window), glfwGetNativeDisplay())

    let phys = select_physical_device(instance)
    let gfx = select_graphics_queue_family(phys)
    if (!queue_family_supports_present(phys, gfx, surface)) {
        panic("graphics queue family does not support presentation")
    }
    var inscope device <- create_device(phys, gfx, ["VK_KHR_swapchain"])
    volkLoadDevice(boost_value_to_vk(device))
    let queue = get_device_queue(device, gfx, 0u)

    // run the compute shader once -> a GPU-resident storage image (left in GENERAL)
    var inscope fractal <- run_mandelbrot_compute(device, phys, queue, gfx, mandelbrot_spv, MAND_DIM, MAND_DIM)

    var poolci : CommandPoolCreateInfo
    poolci.queueFamilyIndex = gfx
    var inscope pool <- create_command_pool(device, poolci)

    // GENERAL -> SHADER_READ_ONLY so the fragment shader can sample it
    run_cmd_sync(device, pool, queue) $(cmd) {
        var shader_write : VkAccessFlags
        shader_write.shader_write = true
        var shader_read : VkAccessFlags
        shader_read.shader_read = true
        var comp : VkPipelineStageFlags
        comp.compute_shader = true
        var frag : VkPipelineStageFlags
        frag.fragment_shader = true
        transition_image(cmd, fractal.image, VkImageLayout.GENERAL, VkImageLayout.SHADER_READ_ONLY_OPTIMAL,
            shader_write, shader_read, comp, frag)
    }

    // a sampler to read the fractal with (linear so window scaling is smooth)
    var sci : SamplerCreateInfo
    sci.magFilter = VkFilter.LINEAR
    sci.minFilter = VkFilter.LINEAR
    sci.mipmapMode = VkSamplerMipmapMode.LINEAR
    var inscope sampler <- create_sampler(device, sci)

    // descriptor set layout: binding 0 = combined image sampler, fragment stage
    var dslci : DescriptorSetLayoutCreateInfo
    var b0 : DescriptorSetLayoutBinding
    b0.binding = 0u
    b0.descriptorType = VkDescriptorType.COMBINED_IMAGE_SAMPLER
    b0.descriptorCount = 1u
    b0.stageFlags.fragment = true
    dslci.pBindings |> emplace(b0)
    var inscope set_layout <- create_descriptor_set_layout(device, dslci)

    var dpci : DescriptorPoolCreateInfo
    dpci.maxSets = 1u
    var ps0 : DescriptorPoolSize
    ps0.type_ = VkDescriptorType.COMBINED_IMAGE_SAMPLER
    ps0.descriptorCount = 1u
    dpci.pPoolSizes |> push(ps0)
    var inscope desc_pool <- create_descriptor_pool(device, dpci)

    var dsai = VkDescriptorSetAllocateInfo()
    dsai.descriptorPool = boost_value_to_vk(desc_pool)
    dsai.descriptorSetCount = 1u
    var raw_set_layout = boost_value_to_vk(set_layout)
    var raw_set : VkDescriptorSet
    unsafe {
        dsai.pSetLayouts = addr(raw_set_layout)
        vk_check(vkAllocateDescriptorSets(boost_value_to_vk(device), dsai, addr(raw_set)), null)
    }

    // bind the fractal view + sampler at binding 0 (layout SHADER_READ_ONLY)
    var write : WriteDescriptorSet
    write.dstSet = vk_value_to_boost(raw_set)
    write.dstBinding = 0u
    write.descriptorType = VkDescriptorType.COMBINED_IMAGE_SAMPLER
    write.descriptorCount = 1u
    var iinfo : DescriptorImageInfo
    iinfo.sampler = weak_copy(sampler)
    iinfo.imageView = weak_copy(fractal.view)
    iinfo.imageLayout = VkImageLayout.SHADER_READ_ONLY_OPTIMAL
    write.pImageInfo |> push(iinfo)
    var writes : array<WriteDescriptorSet>
    writes |> emplace(write)
    var no_copies : array<CopyDescriptorSet>
    update_descriptor_sets(device, writes, no_copies)

    // graphics pipeline: full-screen triangle vert + texture-sampling frag, the descriptor set in the layout
    var inscope swap <- create_swapchain(device, phys, surface, MAND_DIM, MAND_DIM)
    var inscope render_pass <- create_render_pass_single_color(device, swap.format, VkImageLayout.PRESENT_SRC_KHR)
    build_swapchain_framebuffers(device, swap, render_pass)
    var inscope vert <- create_shader_module(device, fsq_vert_spv)
    var inscope frag <- create_shader_module(device, fsq_frag_spv)
    var plci : PipelineLayoutCreateInfo
    plci.pSetLayouts <- [weak_copy(set_layout)]
    var inscope layout <- create_pipeline_layout(device, plci)
    var inscope pipeline <- create_graphics_pipeline_simple(device, render_pass, layout, vert, frag, swap.width, swap.height, true)

    var inscope sync <- create_frame_sync(device)
    let clear = clear_color(0.0f, 0.0f, 0.0f, 1.0f)

    while (glfwWindowShouldClose(window) == 0) {
        glfwPollEvents()
        var fbw = 0
        var fbh = 0
        glfwGetFramebufferSize(window, fbw, fbh)
        if (fbw == 0 || fbh == 0) {
            glfwWaitEvents()
            continue
        }
        if (fbw != swap.width || fbh != swap.height) {
            recreate_swapchain(swap, device, phys, surface, render_pass, fbw, fbh)
        }
        let ok = draw_frame(device, queue, swap, render_pass, pool, sync, clear, true) $(cmd) {
            cmd_bind_pipeline(cmd, pipeline)
            var sets : array<DescriptorSet>
            sets |> push(vk_value_to_boost(raw_set))
            var no_dyn : array<uint>
            cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.GRAPHICS, layout, 0u, sets, no_dyn)
            cmd_draw(cmd, 3u)
        }
        if (!ok) {
            recreate_swapchain(swap, device, phys, surface, render_pass, fbw, fbh)
        }
    }
    vkDeviceWaitIdle(boost_value_to_vk(device))
}
