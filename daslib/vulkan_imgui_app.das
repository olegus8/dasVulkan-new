options gen2
options indenting = 4

// A windowed Dear ImGui application harness on Vulkan -- the Vulkan-backed mirror of dasImgui's
// imgui_harness. It absorbs all the GLFW + Vulkan boilerplate (window, instance/device/swapchain,
// render pass, sync, the ImGui context + daslang theme + the vulkan_imgui_driver renderer) behind the
// same five lifecycle calls dasImgui apps already use:
//
//   harness_init / harness_begin_frame / harness_new_frame / harness_end_frame / harness_shutdown
//
// so a backend-agnostic dasImgui app ports to Vulkan by swapping `require imgui/imgui_harness` for
// `require vulkan/vulkan_imgui_app`. Apps that draw their own geometry behind the UI use the
// `harness_end_frame(scene)` overload to record into the same render pass as the UI.
//
// Standalone-windowed only for now (no headless / no live-host reload wiring yet); input is the GLFW
// backend (ImGui_ImplGlfw) -- mouse, keyboard, and scroll.

module vulkan_imgui_app shared public

require imgui public
require imgui_app
require glfw/glfw_boost
require vulkan public
require vulkan/vulkan_boost public
require vulkan/vulkan_window public
require vulkan/vulkan_imgui_driver public
require vulkan/vulkan_live public
require imgui/imgui_theme_daslang
require live_host public

// ===== app state (one owning heap struct, held by a single pointer so teardown is explicit) =====

struct private VulkanApp {
    window        : GLFWwindow?
    instance      : Instance
    surface       : SurfaceKHR
    phys          : VkPhysicalDevice
    gfx           : uint
    device        : Device
    queue         : VkQueue
    pool          : CommandPool
    swap          : Swapchain
    render_pass   : RenderPass
    sync          : FrameSync
    igvk          : ImguiVkRenderer
    ctx           : ImGuiContext?
    shot_was_down : bool
}

def private finalize(var a : VulkanApp) {
    unsafe {
        vkDeviceWaitIdle(boost_value_to_vk(a.device))
    }
    if (a.ctx != null) {
        ImGui_ImplGlfw_Shutdown()
        DestroyContext(a.ctx)
        a.ctx = null
    }
    unsafe {
        delete a.igvk           // GPU renderer (uses device)
        delete a.sync
        delete a.swap           // framebuffers + views + handle
        delete a.render_pass
        delete a.pool
        delete a.device
        delete a.surface
        delete a.instance
    }
    if (a.window != null) {
        glfwDestroyWindow(a.window)
        a.window = null
    }
}

var private g_app : VulkanApp?

// ===== lifecycle =====

def public harness_init(title : string; width : int = 800; height : int = 600) {
    //! Create the window + Vulkan device/swapchain + ImGui context (daslang theme + JetBrains Mono) +
    //! the vulkan_imgui_driver renderer, and register the swapchain with vulkan_live. Idempotent.
    //! Call from your script's init().
    if (g_app != null) {
        return
    }
    if (volkInitialize() != 0) {
        panic("vulkan_imgui_app: no vulkan loader")
    }
    glfwInitVulkanLoader(vk_get_instance_proc_addr())
    if (glfwInit() == 0) {
        panic("vulkan_imgui_app: can't init glfw")
    }
    if (glfwVulkanSupported() == 0) {
        panic("vulkan_imgui_app: glfw reports no vulkan support")
    }
    glfwWindowHint(int(GLFW_CLIENT_API), GLFW_NO_API)
    glfwWindowHint(int(GLFW_RESIZABLE), GLFW_TRUE)
    var window = glfwCreateWindow(width, height, title, null, null)
    if (window == null) {
        panic("vulkan_imgui_app: can't create window")
    }

    var ext_count = 0u
    let glfw_exts = glfwGetRequiredInstanceExtensions(unsafe(addr(ext_count)))
    var inst_exts : array<string>
    inst_exts |> reserve(int(ext_count))
    for (i in range(int(ext_count))) {
        unsafe {
            inst_exts |> push(glfw_exts[i])
        }
    }
    var inscope instance <- create_instance(title, make_api_version(1u, 3u, 0u), inst_exts)
    volkLoadInstance(boost_value_to_vk(instance))
    var inscope surface <- create_surface(instance, glfwGetNativeWindow(window), glfwGetNativeDisplay())
    var phys = select_physical_device(instance)   // var: keep the handle pointee non-const for the struct field
    let gfx = select_graphics_queue_family(phys)
    if (!queue_family_supports_present(phys, gfx, surface)) {
        panic("vulkan_imgui_app: graphics queue family can't present")
    }
    var inscope device <- create_device(phys, gfx, ["VK_KHR_swapchain"])
    volkLoadDevice(boost_value_to_vk(device))
    var queue = get_device_queue(device, gfx, 0u)
    var poolci : CommandPoolCreateInfo
    poolci.queueFamilyIndex = gfx
    var inscope pool <- create_command_pool(device, poolci)

    // UNORM (pass-through) swapchain: a UI outputs already-sRGB colors, so the GPU must not sRGB-encode
    // them again (matches how the GL tools render).
    var inscope swap <- create_swapchain(device, phys, surface, width, height, VkFormat.B8G8R8A8_UNORM)
    var inscope render_pass <- create_render_pass_single_color(device, swap.format, VkImageLayout.PRESENT_SRC_KHR)
    build_swapchain_framebuffers(device, swap, render_pass)
    var inscope sync <- create_frame_sync(device)

    var ctx = CreateContext(null)
    load_daslang_font()
    apply_daslang_theme()
    var io & = unsafe(GetIO())
    io.BackendFlags |= ImGuiBackendFlags.RendererHasTextures
    io.BackendFlags |= ImGuiBackendFlags.RendererHasVtxOffset
    // GLFW platform backend: installs mouse/keyboard/scroll/char callbacks and feeds DisplaySize +
    // DisplayFramebufferScale each frame (replaces the hand-rolled mouse-only polling).
    ImGui_ImplGlfw_InitForVulkan(window, true)
    var inscope igvk <- imgui_vk_create(device, render_pass)

    g_app = new VulkanApp(window = window, instance <- instance, surface <- surface, phys = phys,
        gfx = gfx, device <- device, queue = queue, pool <- pool, swap <- swap, render_pass <- render_pass,
        sync <- sync, igvk <- igvk, ctx = ctx, shot_was_down = false)

    // register on the app's OWN swapchain field (not the moved-out local), so an in-place resize is seen
    vk_live_set_target(g_app.device, g_app.phys, g_app.queue, g_app.pool, g_app.swap)
}

def public harness_begin_frame() : bool {
    //! Poll events, handle minimize/resize, feed ImGui input. Returns false to skip this update
    //! (window closed -> request_exit; or minimized). Call from update().
    if (g_app == null) {
        return false
    }
    glfwPollEvents()
    if (glfwWindowShouldClose(g_app.window) != 0) {
        request_exit()
        return false
    }
    var fbw = 0
    var fbh = 0
    glfwGetFramebufferSize(g_app.window, fbw, fbh)
    if (fbw == 0 || fbh == 0) {
        glfwWaitEvents()
        return false
    }
    if (fbw != g_app.swap.width || fbh != g_app.swap.height) {
        recreate_swapchain(g_app.swap, g_app.device, g_app.phys, g_app.surface, g_app.render_pass, fbw, fbh)  // waits idle internally
    }
    // Feeds DisplaySize/DisplayFramebufferScale, DeltaTime, and the polled mouse/keyboard/scroll events
    // (callbacks installed by InitForVulkan) into io.
    ImGui_ImplGlfw_NewFrame()
    // The GLFW backend advances its frame clock only inside NewFrame, which we skip while minimized,
    // so the first frame after a restore would otherwise see a huge DeltaTime. Clamp it (also absorbs
    // debugger-pause / long-hitch spikes).
    var io & = unsafe(GetIO())
    if (io.DeltaTime > 0.1f) {
        io.DeltaTime = 0.1f
    }
    return true
}

def public harness_new_frame() {
    //! ImGui::NewFrame(). Call after harness_begin_frame() and before building the UI.
    NewFrame()
}

// recreate-on-out-of-date + the press-P screenshot, shared by both end_frame overloads
def private after_present(ok : bool) {
    if (!ok) {
        var fbw = 0
        var fbh = 0
        glfwGetFramebufferSize(g_app.window, fbw, fbh)
        if (fbw > 0 && fbh > 0) {
            recreate_swapchain(g_app.swap, g_app.device, g_app.phys, g_app.surface, g_app.render_pass, fbw, fbh)  // waits idle internally
        }
    }
    let down = glfwGetKey(g_app.window, GLFW_KEY_P) == GLFW_PRESS
    if (down && !g_app.shot_was_down) {
        vk_live_save_screenshot("screenshot.png")
    }
    g_app.shot_was_down = down
}

def public harness_end_frame() {
    //! Render the UI and present. Call after building the UI.
    Render()
    imgui_vk_update_textures(g_app.igvk, g_app.device, g_app.phys, g_app.queue, g_app.pool)
    let ok = vk_live_draw_frame(g_app.render_pass, g_app.sync,
                                clear_color(0.10f, 0.11f, 0.14f, 1.0f), true) $(cmd) {
        imgui_vk_render(g_app.igvk, g_app.device, g_app.phys, cmd)
    }
    after_present(ok)
}

def public harness_end_frame(scene : block<(cmd : CommandBuffer) : void>) {
    //! Render `scene` (custom geometry) then the UI on top, into one render pass, and present. Use this
    //! when the app draws its own Vulkan geometry behind the ImGui UI.
    Render()
    imgui_vk_update_textures(g_app.igvk, g_app.device, g_app.phys, g_app.queue, g_app.pool)
    let ok = vk_live_draw_frame(g_app.render_pass, g_app.sync,
                                clear_color(0.10f, 0.11f, 0.14f, 1.0f), true) $(cmd) {
        invoke(scene, cmd)
        imgui_vk_render(g_app.igvk, g_app.device, g_app.phys, cmd)
    }
    after_present(ok)
}

def public harness_shutdown() {
    //! Tear down everything (waits for the device to idle first). Call from shutdown().
    if (g_app == null) {
        return
    }
    unsafe {
        delete g_app
    }
    g_app = null
    glfwTerminate()
}

// ===== compatibility shims (match imgui_harness so apps port unchanged) =====

def public harness_is_headless() : bool {
    //! Always false -- the Vulkan harness is windowed-only for now.
    return false
}

def public harness_frame_count() : int {
    //! ImGui's frame counter.
    return GetFrameCount()
}
