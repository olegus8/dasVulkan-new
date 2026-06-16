options gen2
options indenting = 4

// Tutorial 02, present method ONE of two: BLIT. The compute shader writes the fractal into a storage
// image once; each frame we vkCmdBlitImage that image straight onto the acquired swapchain image (scaled
// to the window, linear filter) and present. No graphics pipeline, no render pass, no fragment shader --
// just a transfer. The blit is recorded through vulkan_window's present_frame helper (acquire -> record
// -> submit -> present, the non-render-pass sibling of draw_frame); the transitions + blit below are the
// whole teaching point. Compare show_mandelbrot_sampled.das, which instead samples the image as a texture.
//
// Needs a display + the glfw module, so it lives in this window/ subfolder the tutorials .das_test skips
// in CI (the lavapipe CI daslang build is -DDAS_GLFW_DISABLED=ON). Run from the daslang root:
//   daslang -load_module <path-to-dasVulkan> <path-to>/tutorials/02_mandelbrot/window/show_mandelbrot_blit.das
// Close the window to exit.

require glfw/glfw_boost
require vulkan
require vulkan/vulkan_boost
require vulkan/vulkan_window
require ../mandelbrot_tut_shaders.das
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
    var window = glfwCreateWindow(MAND_DIM, MAND_DIM, "dasVulkan tutorial 02 - Mandelbrot (blit)", null, null)
    if (window == null) {
        panic("can't create window")
    }
    defer() { glfwDestroyWindow(window) }

    // instance with the surface extensions glfw needs on this platform
    var ext_count = 0u
    let glfw_exts = glfwGetRequiredInstanceExtensions(unsafe(addr(ext_count)))
    var inst_exts : array<string>
    inst_exts |> reserve(int(ext_count))
    for (i in range(int(ext_count))) {
        unsafe {
            inst_exts |> push(glfw_exts[i])
        }
    }
    var inscope instance <- create_instance("dasVulkan tutorial 02 (blit)", make_api_version(1u, 3u, 0u), inst_exts)
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

    // run the compute shader once -> a GPU-resident storage image (left in GENERAL, a legal blit source)
    var inscope fractal <- run_mandelbrot_compute(device, phys, queue, gfx, mandelbrot_spv, MAND_DIM, MAND_DIM)

    // the blit path needs no render pass or framebuffers, only the swapchain images themselves
    var inscope swap <- create_swapchain(device, phys, surface, MAND_DIM, MAND_DIM)

    var poolci : CommandPoolCreateInfo
    poolci.queueFamilyIndex = gfx
    var inscope pool <- create_command_pool(device, poolci)
    var inscope sync <- create_frame_sync(device)

    while (glfwWindowShouldClose(window) == 0) {
        glfwPollEvents()
        var fbw = 0
        var fbh = 0
        glfwGetFramebufferSize(window, fbw, fbh)
        if (fbw == 0 || fbh == 0) {
            glfwWaitEvents()
            continue
        }
        // match the window: the blit path has no framebuffers, so just remake the swapchain in place
        if (fbw != swap.width || fbh != swap.height) {
            vkDeviceWaitIdle(boost_value_to_vk(device))
            delete swap
            swap <- create_swapchain(device, phys, surface, fbw, fbh)
        }
        let ok = present_frame(device, queue, swap, pool, sync) $(cmd; target; idx) {
            var none : VkAccessFlags
            var transfer_write : VkAccessFlags
            transfer_write.transfer_write = true
            var top : VkPipelineStageFlags
            top.top_of_pipe = true
            var xfer : VkPipelineStageFlags
            xfer.transfer = true
            var bottom : VkPipelineStageFlags
            bottom.bottom_of_pipe = true
            let dst = vk_value_to_boost(target)
            // swapchain image: UNDEFINED -> TRANSFER_DST (we overwrite the whole image)
            transition_image(cmd, dst, VkImageLayout.UNDEFINED, VkImageLayout.TRANSFER_DST_OPTIMAL,
                none, transfer_write, top, xfer)
            // blit the fractal (GENERAL) onto the swapchain image, scaling MAND_DIM -> window, linear filter
            var region : VkImageBlit
            region.srcSubresource.aspectMask.color = true
            region.srcSubresource.layerCount = 1u
            region.srcOffsets[1].x = fractal.width
            region.srcOffsets[1].y = fractal.height
            region.srcOffsets[1].z = 1
            region.dstSubresource.aspectMask.color = true
            region.dstSubresource.layerCount = 1u
            region.dstOffsets[1].x = swap.width
            region.dstOffsets[1].y = swap.height
            region.dstOffsets[1].z = 1
            unsafe {
                vkCmdBlitImage(boost_value_to_vk(cmd), boost_value_to_vk(fractal.image), VkImageLayout.GENERAL,
                    target, VkImageLayout.TRANSFER_DST_OPTIMAL, 1u, addr(region), VkFilter.LINEAR)
            }
            // TRANSFER_DST -> PRESENT_SRC for the present
            transition_image(cmd, dst, VkImageLayout.TRANSFER_DST_OPTIMAL, VkImageLayout.PRESENT_SRC_KHR,
                transfer_write, none, xfer, bottom)
        }
        if (!ok) {
            vkDeviceWaitIdle(boost_value_to_vk(device))
            delete swap
            swap <- create_swapchain(device, phys, surface, fbw, fbh)
        }
    }
    vkDeviceWaitIdle(boost_value_to_vk(device))
}
