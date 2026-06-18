options gen2
options indenting = 4

// Hand-written ergonomic top of the boost: selection helpers, block brackets,
// combined builders, and the composite creators whose CreateInfo the generator
// skips (instance/device/render-pass/shader-module/pipeline). Re-exports the
// generated boost so users `require vulkan/vulkan_boost` and get everything.

module vulkan_boost

require vulkan public
require vulkan/vulkan_runtime public
require vulkan/vulkan_ctors public
require vulkan/vulkan_handles public
require vulkan/vulkan_structs public
require vulkan/vulkan_commands public
require vulkan/vulkan_cmds public
require daslib/defer

// ===== selection =====

def public select_physical_device(instance : Instance) : VkPhysicalDevice {
    var count = 0u
    vkEnumeratePhysicalDevices(boost_value_to_vk(instance), count, null)
    if (count == 0u) {
        panic("no Vulkan physical devices")
    }
    var devices : array<VkPhysicalDevice>
    devices |> resize(int(count))
    unsafe {
        vkEnumeratePhysicalDevices(boost_value_to_vk(instance), count, addr(devices[0]))
    }
    // prefer a discrete GPU
    var best = devices[0]
    for (d in devices) {
        var props : VkPhysicalDeviceProperties
        vkGetPhysicalDeviceProperties(d, props)
        if (props.deviceType == VkPhysicalDeviceType.DISCRETE_GPU) {
            best = d
            break
        }
    }
    return best
}

def public select_graphics_queue_family(phys : VkPhysicalDevice) : uint {
    var count = 0u
    vkGetPhysicalDeviceQueueFamilyProperties(phys, count, null)
    var props : array<VkQueueFamilyProperties>
    props |> resize(int(count))
    unsafe {
        vkGetPhysicalDeviceQueueFamilyProperties(phys, count, addr(props[0]))
    }
    for (i in range(int(count))) {
        if (props[i].queueFlags.graphics) {
            return uint(i)
        }
    }
    panic("no graphics queue family")
    return 0u
}

def public find_memory_type(phys : VkPhysicalDevice; type_bits : uint; want : VkMemoryPropertyFlags) : uint {
    var mp : VkPhysicalDeviceMemoryProperties
    vkGetPhysicalDeviceMemoryProperties(phys, mp)
    for (i in range(int(mp.memoryTypeCount))) {
        let supported = (type_bits & (1u << uint(i))) != 0u
        let has = (uint(mp.memoryTypes[i].propertyFlags) & uint(want)) == uint(want)
        if (supported && has) {
            return uint(i)
        }
    }
    panic("no suitable memory type")
    return 0u
}

// ===== composite creators (CreateInfo skipped by the generator) =====

//! is `name` advertised among the loader's available instance extensions?
def public instance_extension_available(name : string) : bool {
    var count = 0u
    if (vkEnumerateInstanceExtensionProperties("", count, null) != VkResult.SUCCESS || count == 0u) {
        return false
    }
    var props : array<VkExtensionProperties>
    props |> resize(int(count))
    let rc = vkEnumerateInstanceExtensionProperties("", count, unsafe(addr(props[0])))
    if (rc != VkResult.SUCCESS) {
        return false
    }
    var found = false
    for (p in props) {
        unsafe {
            if ("{reinterpret<string>(addr(p.extensionName[0]))}" == name) {
                found = true
                break
            }
        }
    }
    return found
}

def public create_instance(application_name : string; api_version : uint; extensions : array<string>) : Instance {
    var ai = VkApplicationInfo()
    ai.apiVersion = api_version
    if (application_name != "") {
        ai.pApplicationName = application_name
    }
    var ci = VkInstanceCreateInfo()
    unsafe {
        ci.pApplicationInfo = addr(ai)
    }
    // On portability drivers (MoltenVK on macOS) the loader rejects vkCreateInstance
    // with ERROR_INCOMPATIBLE_DRIVER unless VK_KHR_portability_enumeration is enabled
    // and the matching create flag is set. Add it transparently when the loader
    // advertises it, so the same user code runs unchanged on every platform.
    var exts <- [for (e in extensions); e]
    if (instance_extension_available("VK_KHR_portability_enumeration")) {
        if (find_index(exts, "VK_KHR_portability_enumeration") < 0) {
            exts |> push("VK_KHR_portability_enumeration")
        }
        ci.flags.enumerate_portability_khr = true
    }
    // array<string> is contiguous `const char*` pointers == const char* const* (what
    // Vulkan wants); ppEnabledExtensionNames is bound as void? so reinterpret to it.
    if (!empty(exts)) {
        ci.enabledExtensionCount = uint(length(exts))
        unsafe {
            ci.ppEnabledExtensionNames = reinterpret<void?>(addr(exts[0]))
        }
    }
    var h : VkInstance
    vk_check(vkCreateInstance(ci, null, h), null)
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    return <- b
}

def public create_instance(application_name : string = ""; api_version : uint = 0u) : Instance {
    let no_ext : array<string>
    return <- create_instance(application_name, api_version, no_ext)
}

def public create_device(phys : VkPhysicalDevice; queue_family : uint; extensions : array<string>) : Device {
    var no_features : VkPhysicalDeviceFeatures
    return <- create_device(phys, queue_family, extensions, no_features)
}

def public create_device(phys : VkPhysicalDevice; queue_family : uint) : Device {
    let no_ext : array<string>
    var no_features : VkPhysicalDeviceFeatures
    return <- create_device(phys, queue_family, no_ext, no_features)
}

//! Create a device with a caller-supplied ``VkPhysicalDeviceFeatures`` block. Use this when the
//! pipeline needs an opt-in feature -- e.g. ``largePoints`` so a vertex shader's ``gl_PointSize``
//! takes effect (POINT_LIST topology), or ``wideLines`` for line-list topology. Verify the device
//! actually advertises the feature via ``vkGetPhysicalDeviceFeatures`` before passing it in;
//! enabling an unsupported feature fails ``vkCreateDevice``. The other two overloads pass a
//! zero-initialised features block, identical to the prior behaviour.
def public create_device(phys : VkPhysicalDevice; queue_family : uint; extensions : array<string>; var features : VkPhysicalDeviceFeatures) : Device {
    var prio = 1.0f
    var qci = VkDeviceQueueCreateInfo()
    qci.queueFamilyIndex = queue_family
    qci.queueCount = 1u
    unsafe {
        qci.pQueuePriorities = addr(prio)
    }
    var ci = VkDeviceCreateInfo()
    ci.queueCreateInfoCount = 1u
    unsafe {
        ci.pQueueCreateInfos = addr(qci)
        ci.pEnabledFeatures = addr(features)
    }
    if (!empty(extensions)) {
        ci.enabledExtensionCount = uint(length(extensions))
        unsafe {
            ci.ppEnabledExtensionNames = reinterpret<void?>(addr(extensions[0]))
        }
    }
    var h : VkDevice
    vk_check(vkCreateDevice(phys, ci, null, h), null)
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    return <- b
}

def public get_device_queue(device : Device; queue_family, index : uint) : VkQueue {
    var q : VkQueue
    vkGetDeviceQueue(boost_value_to_vk(device), queue_family, index, q)
    return q
}

def public create_shader_module(device : Device; var code : array<uint8>) : ShaderModule {
    var ci = VkShaderModuleCreateInfo()
    ci.codeSize = uint64(length(code))
    unsafe {
        ci.pCode = reinterpret<uint?>(addr(code[0]))
    }
    var h : VkShaderModule
    vk_check(vkCreateShaderModule(boost_value_to_vk(device), ci, null, h), null)
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    b._device = unsafe(reinterpret<uint64>(boost_value_to_vk(device)))
    return <- b
}

//! SPIR-V words overload — the form emitted by dasSpirv (`array<uint>`). codeSize is the byte
//! count (4 per word); pCode points straight at the word data, no uint8->uint reinterpret.
def public create_shader_module(device : Device; var code : array<uint>) : ShaderModule {
    var ci = VkShaderModuleCreateInfo()
    ci.codeSize = uint64(length(code) * 4)
    unsafe {
        ci.pCode = addr(code[0])
    }
    var h : VkShaderModule
    vk_check(vkCreateShaderModule(boost_value_to_vk(device), ci, null, h), null)
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    b._device = unsafe(reinterpret<uint64>(boost_value_to_vk(device)))
    return <- b
}

def public create_pipeline_layout(device : Device) : PipelineLayout {
    var ci = VkPipelineLayoutCreateInfo()
    var h : VkPipelineLayout
    vk_check(vkCreatePipelineLayout(boost_value_to_vk(device), ci, null, h), null)
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    b._device = unsafe(reinterpret<uint64>(boost_value_to_vk(device)))
    return <- b
}

def public create_render_pass_single_color(device : Device; format : VkFormat;
                                           final_layout : VkImageLayout = VkImageLayout.TRANSFER_SRC_OPTIMAL) : RenderPass {
    var attach : VkAttachmentDescription
    attach.format = format
    attach.samples._1 = true
    attach.loadOp = VkAttachmentLoadOp.CLEAR
    attach.storeOp = VkAttachmentStoreOp.STORE
    attach.stencilLoadOp = VkAttachmentLoadOp.DONT_CARE
    attach.stencilStoreOp = VkAttachmentStoreOp.DONT_CARE
    attach.initialLayout = VkImageLayout.UNDEFINED
    attach.finalLayout = final_layout
    var ref : VkAttachmentReference
    ref.layout = VkImageLayout.COLOR_ATTACHMENT_OPTIMAL
    var subpass : VkSubpassDescription
    subpass.pipelineBindPoint = VkPipelineBindPoint.GRAPHICS
    subpass.colorAttachmentCount = 1u
    var ci = VkRenderPassCreateInfo()
    ci.attachmentCount = 1u
    ci.subpassCount = 1u
    var h : VkRenderPass
    unsafe {
        subpass.pColorAttachments = addr(ref)
        ci.pAttachments = addr(attach)
        ci.pSubpasses = addr(subpass)
        vk_check(vkCreateRenderPass(boost_value_to_vk(device), ci, null, h), null)
    }
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    b._device = unsafe(reinterpret<uint64>(boost_value_to_vk(device)))
    return <- b
}

//! Depth-only render pass for the shadow-mapping pattern. One attachment: depth, loadOp=CLEAR,
//! storeOp=STORE, finalLayout=DEPTH_STENCIL_READ_ONLY_OPTIMAL so the main pass can sample the
//! produced depth without a manual barrier. Vertex-only pipelines (no fragment) are valid against
//! this pass — there are no color attachments to write.
def public create_render_pass_depth_only(device : Device; depth_format : VkFormat;
                                         final_layout : VkImageLayout = VkImageLayout.DEPTH_STENCIL_READ_ONLY_OPTIMAL) : RenderPass {
    var depth : VkAttachmentDescription
    depth.format = depth_format
    depth.samples._1 = true
    depth.loadOp = VkAttachmentLoadOp.CLEAR
    depth.storeOp = VkAttachmentStoreOp.STORE
    depth.stencilLoadOp = VkAttachmentLoadOp.DONT_CARE
    depth.stencilStoreOp = VkAttachmentStoreOp.DONT_CARE
    depth.initialLayout = VkImageLayout.UNDEFINED
    depth.finalLayout = final_layout

    var depth_ref : VkAttachmentReference
    depth_ref.attachment = 0u
    depth_ref.layout = VkImageLayout.DEPTH_STENCIL_ATTACHMENT_OPTIMAL

    var subpass : VkSubpassDescription
    subpass.pipelineBindPoint = VkPipelineBindPoint.GRAPHICS

    var ci = VkRenderPassCreateInfo()
    ci.attachmentCount = 1u
    ci.subpassCount = 1u
    var h : VkRenderPass
    unsafe {
        subpass.pDepthStencilAttachment = addr(depth_ref)
        ci.pAttachments = addr(depth)
        ci.pSubpasses = addr(subpass)
        vk_check(vkCreateRenderPass(boost_value_to_vk(device), ci, null, h), null)
    }
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    b._device = unsafe(reinterpret<uint64>(boost_value_to_vk(device)))
    return <- b
}

//! Two-attachment render pass: color at index 0, depth at index 1. Color clears+stores like the
//! single-color path; depth clears+discards (no read after the pass). Framebuffers built against
//! this must pass `[color_view, depth_view]` in attachment order.
def public create_render_pass_color_depth(device : Device; color_format, depth_format : VkFormat;
                                          color_final_layout : VkImageLayout = VkImageLayout.TRANSFER_SRC_OPTIMAL) : RenderPass {
    var attaches : array<VkAttachmentDescription>
    var color : VkAttachmentDescription
    color.format = color_format
    color.samples._1 = true
    color.loadOp = VkAttachmentLoadOp.CLEAR
    color.storeOp = VkAttachmentStoreOp.STORE
    color.stencilLoadOp = VkAttachmentLoadOp.DONT_CARE
    color.stencilStoreOp = VkAttachmentStoreOp.DONT_CARE
    color.initialLayout = VkImageLayout.UNDEFINED
    color.finalLayout = color_final_layout
    attaches |> push(color)
    var depth : VkAttachmentDescription
    depth.format = depth_format
    depth.samples._1 = true
    depth.loadOp = VkAttachmentLoadOp.CLEAR
    depth.storeOp = VkAttachmentStoreOp.DONT_CARE
    depth.stencilLoadOp = VkAttachmentLoadOp.DONT_CARE
    depth.stencilStoreOp = VkAttachmentStoreOp.DONT_CARE
    depth.initialLayout = VkImageLayout.UNDEFINED
    depth.finalLayout = VkImageLayout.DEPTH_STENCIL_ATTACHMENT_OPTIMAL
    attaches |> push(depth)

    var color_ref : VkAttachmentReference
    color_ref.attachment = 0u
    color_ref.layout = VkImageLayout.COLOR_ATTACHMENT_OPTIMAL
    var depth_ref : VkAttachmentReference
    depth_ref.attachment = 1u
    depth_ref.layout = VkImageLayout.DEPTH_STENCIL_ATTACHMENT_OPTIMAL

    var subpass : VkSubpassDescription
    subpass.pipelineBindPoint = VkPipelineBindPoint.GRAPHICS
    subpass.colorAttachmentCount = 1u
    var ci = VkRenderPassCreateInfo()
    ci.attachmentCount = 2u
    ci.subpassCount = 1u
    var h : VkRenderPass
    unsafe {
        subpass.pColorAttachments = addr(color_ref)
        subpass.pDepthStencilAttachment = addr(depth_ref)
        ci.pAttachments = addr(attaches[0])
        ci.pSubpasses = addr(subpass)
        vk_check(vkCreateRenderPass(boost_value_to_vk(device), ci, null, h), null)
    }
    delete attaches
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    b._device = unsafe(reinterpret<uint64>(boost_value_to_vk(device)))
    return <- b
}

//! `dynamic_viewport` leaves the viewport/scissor out of the pipeline (VIEWPORT+SCISSOR
//! dynamic state) so the pipeline survives swapchain resize -- set them per frame with
//! cmd_set_viewport / cmd_set_scissor (draw_frame does this when its dynamic_viewport is true).
def public create_graphics_pipeline_simple(device : Device; render_pass : RenderPass; layout : PipelineLayout;
                                           vert : ShaderModule; frag : ShaderModule; width, height : int; dynamic_viewport : bool = false) : Pipeline {
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
    viewport.width = float(width)
    viewport.height = float(height)
    viewport.maxDepth = 1.0f
    var scissor : VkRect2D
    scissor.extent.width = uint(width)
    scissor.extent.height = uint(height)
    var vpstate = VkPipelineViewportStateCreateInfo()
    vpstate.viewportCount = 1u
    vpstate.scissorCount = 1u

    var raster = VkPipelineRasterizationStateCreateInfo()
    raster.polygonMode = VkPolygonMode.FILL
    raster.frontFace = VkFrontFace.COUNTER_CLOCKWISE
    raster.lineWidth = 1.0f
    var msaa = VkPipelineMultisampleStateCreateInfo()
    msaa.rasterizationSamples._1 = true
    var blend_att : VkPipelineColorBlendAttachmentState
    blend_att.colorWriteMask.r = true
    blend_att.colorWriteMask.g = true
    blend_att.colorWriteMask.b = true
    blend_att.colorWriteMask.a = true
    var blend = VkPipelineColorBlendStateCreateInfo()
    blend.attachmentCount = 1u

    var dyn_states : array<VkDynamicState>
    var dynstate = VkPipelineDynamicStateCreateInfo()
    if (dynamic_viewport) {
        dyn_states |> push(VkDynamicState.VIEWPORT)
        dyn_states |> push(VkDynamicState.SCISSOR)
        dynstate.dynamicStateCount = uint(length(dyn_states))
    }

    var gp = VkGraphicsPipelineCreateInfo()
    gp.stageCount = 2u
    gp.layout = boost_value_to_vk(layout)
    gp.renderPass = boost_value_to_vk(render_pass)
    var h : VkPipeline
    unsafe {
        if (dynamic_viewport) {
            dynstate.pDynamicStates = addr(dyn_states[0])
            gp.pDynamicState = addr(dynstate)
        } else {
            vpstate.pViewports = addr(viewport)
            vpstate.pScissors = addr(scissor)
        }
        blend.pAttachments = addr(blend_att)
        gp.pStages = addr(stages[0])
        gp.pVertexInputState = addr(vinput)
        gp.pInputAssemblyState = addr(iasm)
        gp.pViewportState = addr(vpstate)
        gp.pRasterizationState = addr(raster)
        gp.pMultisampleState = addr(msaa)
        gp.pColorBlendState = addr(blend)
        vk_check(vkCreateGraphicsPipelines(boost_value_to_vk(device), null, 1u, addr(gp), null, addr(h)), null)
    }
    delete dyn_states
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    b._device = unsafe(reinterpret<uint64>(boost_value_to_vk(device)))
    return <- b
}

//! Graphics pipeline for textured / lit 3D meshes: takes vertex-input bindings + attributes (so a
//! vertex buffer with pos+uv+normal etc. flows in instead of `gl_VertexIndex` fabrication) and
//! enables depth test + write by default (LESS_OR_EQUAL, the standard z-buffer comparison). Other
//! state — rasterizer, blend, msaa — matches `create_graphics_pipeline_simple`; the render pass
//! must have a depth attachment when `depth_test_enable` is true. Pass `dynamic_viewport=true` to
//! leave viewport/scissor out of the pipeline for swapchain-resize windowing.
def public create_graphics_pipeline_v3d(device : Device; render_pass : RenderPass; layout : PipelineLayout;
                                        vert : ShaderModule; frag : ShaderModule; width, height : int;
                                        var vertex_bindings : array<VkVertexInputBindingDescription>;
                                        var vertex_attributes : array<VkVertexInputAttributeDescription>;
                                        depth_test_enable : bool = true; depth_write_enable : bool = true;
                                        depth_compare_op : VkCompareOp = VkCompareOp.LESS_OR_EQUAL;
                                        dynamic_viewport : bool = false) : Pipeline {
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
    vinput.vertexBindingDescriptionCount = uint(length(vertex_bindings))
    vinput.vertexAttributeDescriptionCount = uint(length(vertex_attributes))
    var iasm = VkPipelineInputAssemblyStateCreateInfo()
    iasm.topology = VkPrimitiveTopology.TRIANGLE_LIST

    var viewport : VkViewport
    viewport.width = float(width)
    viewport.height = float(height)
    viewport.maxDepth = 1.0f
    var scissor : VkRect2D
    scissor.extent.width = uint(width)
    scissor.extent.height = uint(height)
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

    var depthstate = VkPipelineDepthStencilStateCreateInfo()
    depthstate.depthTestEnable = depth_test_enable ? VK_TRUE : VK_FALSE
    depthstate.depthWriteEnable = depth_write_enable ? VK_TRUE : VK_FALSE
    depthstate.depthCompareOp = depth_compare_op
    depthstate.minDepthBounds = 0.0f
    depthstate.maxDepthBounds = 1.0f

    var blend_att : VkPipelineColorBlendAttachmentState
    blend_att.colorWriteMask.r = true
    blend_att.colorWriteMask.g = true
    blend_att.colorWriteMask.b = true
    blend_att.colorWriteMask.a = true
    var blend = VkPipelineColorBlendStateCreateInfo()
    blend.attachmentCount = 1u

    var dyn_states : array<VkDynamicState>
    var dynstate = VkPipelineDynamicStateCreateInfo()
    if (dynamic_viewport) {
        dyn_states |> push(VkDynamicState.VIEWPORT)
        dyn_states |> push(VkDynamicState.SCISSOR)
        dynstate.dynamicStateCount = uint(length(dyn_states))
    }

    var gp = VkGraphicsPipelineCreateInfo()
    gp.stageCount = 2u
    gp.layout = boost_value_to_vk(layout)
    gp.renderPass = boost_value_to_vk(render_pass)
    var h : VkPipeline
    unsafe {
        if (!empty(vertex_bindings)) {
            vinput.pVertexBindingDescriptions = addr(vertex_bindings[0])
        }
        if (!empty(vertex_attributes)) {
            vinput.pVertexAttributeDescriptions = addr(vertex_attributes[0])
        }
        if (dynamic_viewport) {
            dynstate.pDynamicStates = addr(dyn_states[0])
            gp.pDynamicState = addr(dynstate)
        } else {
            vpstate.pViewports = addr(viewport)
            vpstate.pScissors = addr(scissor)
        }
        blend.pAttachments = addr(blend_att)
        gp.pStages = addr(stages[0])
        gp.pVertexInputState = addr(vinput)
        gp.pInputAssemblyState = addr(iasm)
        gp.pViewportState = addr(vpstate)
        gp.pRasterizationState = addr(raster)
        gp.pMultisampleState = addr(msaa)
        gp.pDepthStencilState = addr(depthstate)
        gp.pColorBlendState = addr(blend)
        vk_check(vkCreateGraphicsPipelines(boost_value_to_vk(device), null, 1u, addr(gp), null, addr(h)), null)
    }
    delete dyn_states
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    b._device = unsafe(reinterpret<uint64>(boost_value_to_vk(device)))
    return <- b
}

//! create a compute pipeline from a shader module + layout (owns the VkPipeline;
//! finalizes via vkDestroyPipeline). Wraps the batch vkCreateComputePipelines at count 1.
def public create_compute_pipeline(device : Device; layout : PipelineLayout; shader : ShaderModule; entry : string = "main") : Pipeline {
    var stage = VkPipelineShaderStageCreateInfo()
    stage.stage.compute = true
    stage.module_ = boost_value_to_vk(shader)
    stage.pName = entry
    var cp = VkComputePipelineCreateInfo()
    cp.stage = stage
    cp.layout = boost_value_to_vk(layout)
    var h : VkPipeline
    unsafe {
        vk_check(vkCreateComputePipelines(boost_value_to_vk(device), null, 1u, addr(cp), null, addr(h)), null)
    }
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    b._device = unsafe(reinterpret<uint64>(boost_value_to_vk(device)))
    return <- b
}

//! Record a single-image pipeline barrier that transitions `image` from `old_layout` to `new_layout`,
//! with the given access masks and pipeline stages (color aspect, 1 mip, 1 layer). The building block
//! for storage-image / transfer layout moves; used by compute_to_storage_image below.
def public transition_image(cmd : CommandBuffer; image : Image; old_layout, new_layout : VkImageLayout;
                            src_access, dst_access : VkAccessFlags; src_stage, dst_stage : VkPipelineStageFlags) {
    var barrier : ImageMemoryBarrier
    barrier.srcAccessMask = src_access
    barrier.dstAccessMask = dst_access
    barrier.oldLayout = old_layout
    barrier.newLayout = new_layout
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
    barrier.image = weak_copy(image)
    barrier.subresourceRange.aspectMask.color = true
    barrier.subresourceRange.levelCount = 1u
    barrier.subresourceRange.layerCount = 1u
    var no_mem : array<MemoryBarrier>
    var no_buf : array<BufferMemoryBarrier>
    var imgs : array<ImageMemoryBarrier>
    imgs |> emplace(barrier)
    var no_dep : VkDependencyFlags
    cmd_pipeline_barrier(cmd, src_stage, dst_stage, no_dep, no_mem, no_buf, imgs)
}

//! Depth-aspect counterpart of `transition_image`. Same barrier mechanics; flips the aspectMask
//! to `depth = true`. Used by the shadow-mapping pattern when the shadow map is sampled in pass 2
//! after being written in pass 1, or any other depth-image layout transition not covered by the
//! render-pass-driven finalLayout. Stencil-combined formats need the stencil bit too — caller can
//! use the explicit `transition_image_aspect` overload below for that case.
def public transition_depth_image(cmd : CommandBuffer; image : Image; old_layout, new_layout : VkImageLayout;
                                  src_access, dst_access : VkAccessFlags; src_stage, dst_stage : VkPipelineStageFlags) {
    var aspect : VkImageAspectFlags
    aspect.depth = true
    transition_image_aspect(cmd, image, old_layout, new_layout, src_access, dst_access, src_stage, dst_stage, aspect)
}

//! Fully general `transition_image` — caller supplies the `aspectMask`. Use this for stencil
//! aspects, combined depth+stencil, or anything `transition_image` / `transition_depth_image`
//! don't cover. `levelCount = layerCount = 1` (matching the convenience helpers); for mip
//! chains / array layers drop to a raw `cmd_pipeline_barrier`.
def public transition_image_aspect(cmd : CommandBuffer; image : Image; old_layout, new_layout : VkImageLayout;
                                   src_access, dst_access : VkAccessFlags; src_stage, dst_stage : VkPipelineStageFlags;
                                   aspect : VkImageAspectFlags) {
    var barrier : ImageMemoryBarrier
    barrier.srcAccessMask = src_access
    barrier.dstAccessMask = dst_access
    barrier.oldLayout = old_layout
    barrier.newLayout = new_layout
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
    barrier.image = weak_copy(image)
    barrier.subresourceRange.aspectMask = aspect
    barrier.subresourceRange.levelCount = 1u
    barrier.subresourceRange.layerCount = 1u
    var no_mem : array<MemoryBarrier>
    var no_buf : array<BufferMemoryBarrier>
    var imgs : array<ImageMemoryBarrier>
    imgs |> emplace(barrier)
    var no_dep : VkDependencyFlags
    cmd_pipeline_barrier(cmd, src_stage, dst_stage, no_dep, no_mem, no_buf, imgs)
}

//! Run a compute shader that writes an Rgba8 storage image and return the w*h RGBA8 pixels. `words` is
//! an emitted SPIR-V compute blob whose entry point binds a storage image2D at set=0/binding=0 and
//! `imageStore`s a color per invocation over an 8x8 local size. A one-shot: it creates its own
//! instance/device, the storage image, the descriptor set, the compute pipeline and a command pool,
//! dispatches w/8 x h/8, and reads the image back. w and h must be positive multiples of 8 so the
//! dispatch covers every pixel (asserted). For the canonical authoring side see dasSpirv's image2D +
//! imageStore (e.g. dasVulkan's storage-image tests and the Mandelbrot tutorial).
def public compute_to_storage_image(var words : array<uint>; w, h : int) : array<uint8> {
    assert(w > 0 && h > 0 && (w % 8) == 0 && (h % 8) == 0,
        "compute_to_storage_image: w/h must be positive multiples of 8")
    if (volkInitialize() != 0) {
        panic("no Vulkan loader")
    }
    var pixels : array<uint8>
    var inscope instance <- create_instance("dasVulkan compute", make_api_version(1u, 3u, 0u))
    volkLoadInstance(boost_value_to_vk(instance))
    let phys = select_physical_device(instance)
    let gfx = select_graphics_queue_family(phys)
    var inscope device <- create_device(phys, gfx)
    volkLoadDevice(boost_value_to_vk(device))
    let dev = boost_value_to_vk(device)
    let queue = get_device_queue(device, gfx, 0u)
    let fmt = VkFormat.R8G8B8A8_UNORM

    // the storage image (STORAGE for the compute write + TRANSFER_SRC for the readback), device-local + view
    var ici : ImageCreateInfo
    ici.imageType = VkImageType._2D
    ici.format = fmt
    ici.extent.width = uint(w)
    ici.extent.height = uint(h)
    ici.extent.depth = 1u
    ici.mipLevels = 1u
    ici.arrayLayers = 1u
    ici.samples._1 = true
    ici.tiling = VkImageTiling.OPTIMAL
    ici.usage.storage = true
    ici.usage.transfer_src = true
    ici.initialLayout = VkImageLayout.UNDEFINED
    var inscope image <- create_image(device, ici)
    var ireq : VkMemoryRequirements
    vkGetImageMemoryRequirements(dev, boost_value_to_vk(image), ireq)
    var iwant : VkMemoryPropertyFlags
    iwant.device_local = true
    var imai : MemoryAllocateInfo
    imai.allocationSize = ireq.size
    imai.memoryTypeIndex = find_memory_type(phys, ireq.memoryTypeBits, iwant)
    var inscope imem <- allocate_memory(device, imai)
    vk_check(vkBindImageMemory(dev, boost_value_to_vk(image), boost_value_to_vk(imem), 0ul), null)
    var vci : ImageViewCreateInfo
    vci.image = weak_copy(image)
    vci.viewType = VkImageViewType._2D
    vci.format = fmt
    vci.subresourceRange.aspectMask.color = true
    vci.subresourceRange.levelCount = 1u
    vci.subresourceRange.layerCount = 1u
    var inscope view <- create_image_view(device, vci)

    // descriptor set layout + pool: binding 0 = STORAGE_IMAGE, compute
    var dslci : DescriptorSetLayoutCreateInfo
    var b0 : DescriptorSetLayoutBinding
    b0.binding = 0u
    b0.descriptorType = VkDescriptorType.STORAGE_IMAGE
    b0.descriptorCount = 1u
    b0.stageFlags.compute = true
    dslci.pBindings |> emplace(b0)
    var inscope set_layout <- create_descriptor_set_layout(device, dslci)

    var dpci : DescriptorPoolCreateInfo
    dpci.maxSets = 1u
    var psize : DescriptorPoolSize
    psize.type_ = VkDescriptorType.STORAGE_IMAGE
    psize.descriptorCount = 1u
    dpci.pPoolSizes |> push(psize)
    var inscope desc_pool <- create_descriptor_pool(device, dpci)

    var dsai = VkDescriptorSetAllocateInfo()
    dsai.descriptorPool = boost_value_to_vk(desc_pool)
    dsai.descriptorSetCount = 1u
    var raw_set_layout = boost_value_to_vk(set_layout)
    var raw_set : VkDescriptorSet
    unsafe {
        dsai.pSetLayouts = addr(raw_set_layout)
        vk_check(vkAllocateDescriptorSets(dev, dsai, addr(raw_set)), null)
    }

    // bind the storage image view (layout GENERAL, no sampler)
    var write : WriteDescriptorSet
    write.dstSet = vk_value_to_boost(raw_set)
    write.dstBinding = 0u
    write.descriptorType = VkDescriptorType.STORAGE_IMAGE
    write.descriptorCount = 1u
    var iinfo : DescriptorImageInfo
    iinfo.imageView = weak_copy(view)
    iinfo.imageLayout = VkImageLayout.GENERAL
    write.pImageInfo |> push(iinfo)
    var writes : array<WriteDescriptorSet>
    writes |> emplace(write)
    var no_copies : array<CopyDescriptorSet>
    update_descriptor_sets(device, writes, no_copies)

    // compute pipeline from the emitted blob
    var inscope shader <- create_shader_module(device, words)
    var plci : PipelineLayoutCreateInfo
    plci.pSetLayouts <- [weak_copy(set_layout)]
    var inscope pipe_layout <- create_pipeline_layout(device, plci)
    var inscope pipeline <- create_compute_pipeline(device, pipe_layout, shader)

    var inscope readback <- create_host_buffer(device, phys, uint64(w) * uint64(h) * 4ul)
    var poolci : CommandPoolCreateInfo
    poolci.queueFamilyIndex = gfx
    var inscope pool <- create_command_pool(device, poolci)

    run_cmd_sync(device, pool, queue) $(cmd) {
        var none : VkAccessFlags
        var shader_write : VkAccessFlags
        shader_write.shader_write = true
        var to_read : VkAccessFlags
        to_read.transfer_read = true
        var top : VkPipelineStageFlags
        top.top_of_pipe = true
        var comp : VkPipelineStageFlags
        comp.compute_shader = true
        var xfer : VkPipelineStageFlags
        xfer.transfer = true
        // UNDEFINED -> GENERAL for the storage-image write
        transition_image(cmd, image, VkImageLayout.UNDEFINED, VkImageLayout.GENERAL,
            none, shader_write, top, comp)
        cmd_bind_pipeline(cmd, pipeline, VkPipelineBindPoint.COMPUTE)
        var sets : array<DescriptorSet>
        sets |> push(vk_value_to_boost(raw_set))
        var no_dyn : array<uint>
        cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.COMPUTE, pipe_layout, 0u, sets, no_dyn)
        cmd_dispatch(cmd, uint(w / 8), uint(h / 8), 1u)
        // GENERAL -> TRANSFER_SRC for the readback copy
        transition_image(cmd, image, VkImageLayout.GENERAL, VkImageLayout.TRANSFER_SRC_OPTIMAL,
            shader_write, to_read, comp, xfer)
        copy_image_to_buffer(cmd, image, readback, w, h)
    }
    map_memory_to_array(device, readback.memory, uint64(w) * uint64(h) * 4ul) $(m) {
        pixels := m
    }
    return <- pixels
}

// ===== combined builders =====

//! image + backing device memory + view, owned together (destroyed view->image->memory)
struct public OffscreenTarget {
    image : Image
    memory : DeviceMemory
    view : ImageView
}

def public finalize(var t : OffscreenTarget) {
    delete t.view
    delete t.image
    delete t.memory
}

def public build_offscreen_target(device : Device; phys : VkPhysicalDevice; width, height : int; format : VkFormat) : OffscreenTarget {
    var ici : ImageCreateInfo
    ici.imageType = VkImageType._2D
    ici.format = format
    ici.extent.width = uint(width)
    ici.extent.height = uint(height)
    ici.extent.depth = 1u
    ici.mipLevels = 1u
    ici.arrayLayers = 1u
    ici.samples._1 = true
    ici.tiling = VkImageTiling.OPTIMAL
    ici.usage.color_attachment = true
    ici.usage.transfer_src = true
    ici.initialLayout = VkImageLayout.UNDEFINED
    var inscope image <- create_image(device, ici)

    var req : VkMemoryRequirements
    vkGetImageMemoryRequirements(boost_value_to_vk(device), boost_value_to_vk(image), req)
    var want : VkMemoryPropertyFlags
    want.device_local = true
    var mai : MemoryAllocateInfo
    mai.allocationSize = req.size
    mai.memoryTypeIndex = find_memory_type(phys, req.memoryTypeBits, want)
    var inscope memory <- allocate_memory(device, mai)
    vk_check(vkBindImageMemory(boost_value_to_vk(device), boost_value_to_vk(image), boost_value_to_vk(memory), 0ul), null)

    var vci : ImageViewCreateInfo
    vci.image = weak_copy(image)
    vci.viewType = VkImageViewType._2D
    vci.format = format
    vci.subresourceRange.aspectMask.color = true
    vci.subresourceRange.levelCount = 1u
    vci.subresourceRange.layerCount = 1u
    var inscope view <- create_image_view(device, vci)

    var t : OffscreenTarget
    t.image <- image
    t.memory <- memory
    t.view <- view
    return <- t
}

//! depth image + backing memory + depth-aspect view, owned together. Mirrors OffscreenTarget but
//! with depth_stencil_attachment usage + a depth-only aspect on the view, suitable for the depth
//! attachment of an offscreen render pass. Default format `D32_SFLOAT` is one of the two formats
//! Vulkan guarantees on every device for depth attachment (the other is `D32_SFLOAT_S8_UINT`).
struct public OffscreenDepth {
    image : Image
    memory : DeviceMemory
    view : ImageView
}

def public finalize(var d : OffscreenDepth) {
    delete d.view
    delete d.image
    delete d.memory
}

def public build_offscreen_depth(device : Device; phys : VkPhysicalDevice; width, height : int;
                                 format : VkFormat = VkFormat.D32_SFLOAT) : OffscreenDepth {
    var extra : VkImageUsageFlags  // default: empty
    return <- build_offscreen_depth(device, phys, width, height, format, extra)
}

//! `build_offscreen_depth` overload taking caller-supplied extra usage flags. The base helper
//! always sets `depth_stencil_attachment`; this overload adds whatever else the caller needs —
//! `sampled` for shadow maps (the image is read by a `sampler2DShadow` in the next pass),
//! `transfer_src` for offscreen-depth readback, etc. Memory + view stay device-local D32_SFLOAT.
def public build_offscreen_depth(device : Device; phys : VkPhysicalDevice; width, height : int;
                                 format : VkFormat; extra_usage : VkImageUsageFlags) : OffscreenDepth {
    var ici : ImageCreateInfo
    ici.imageType = VkImageType._2D
    ici.format = format
    ici.extent.width = uint(width)
    ici.extent.height = uint(height)
    ici.extent.depth = 1u
    ici.mipLevels = 1u
    ici.arrayLayers = 1u
    ici.samples._1 = true
    ici.tiling = VkImageTiling.OPTIMAL
    ici.usage = extra_usage
    ici.usage.depth_stencil_attachment = true
    ici.initialLayout = VkImageLayout.UNDEFINED
    var inscope image <- create_image(device, ici)

    var req : VkMemoryRequirements
    vkGetImageMemoryRequirements(boost_value_to_vk(device), boost_value_to_vk(image), req)
    var want : VkMemoryPropertyFlags
    want.device_local = true
    var mai : MemoryAllocateInfo
    mai.allocationSize = req.size
    mai.memoryTypeIndex = find_memory_type(phys, req.memoryTypeBits, want)
    var inscope memory <- allocate_memory(device, mai)
    vk_check(vkBindImageMemory(boost_value_to_vk(device), boost_value_to_vk(image), boost_value_to_vk(memory), 0ul), null)

    var vci : ImageViewCreateInfo
    vci.image = weak_copy(image)
    vci.viewType = VkImageViewType._2D
    vci.format = format
    vci.subresourceRange.aspectMask.depth = true
    // include the stencil aspect for combined depth+stencil formats -- omitting it on those leaves
    // the view invalid (VUID-VkImageViewCreateInfo-subresourceRange-01018).
    if (format == VkFormat.D16_UNORM_S8_UINT
            || format == VkFormat.D24_UNORM_S8_UINT
            || format == VkFormat.D32_SFLOAT_S8_UINT) {
        vci.subresourceRange.aspectMask.stencil = true
    }
    vci.subresourceRange.levelCount = 1u
    vci.subresourceRange.layerCount = 1u
    var inscope view <- create_image_view(device, vci)

    var d : OffscreenDepth
    d.image <- image
    d.memory <- memory
    d.view <- view
    return <- d
}

//! host-visible buffer + backing memory, owned together
struct public HostBuffer {
    buffer : Buffer
    memory : DeviceMemory
    size : uint64
}

def public finalize(var hb : HostBuffer) {
    delete hb.buffer
    delete hb.memory
}

def public create_host_buffer(device : Device; phys : VkPhysicalDevice; size : uint64) : HostBuffer {
    var bci : BufferCreateInfo
    bci.size = size
    bci.usage.transfer_dst = true
    var inscope buffer <- create_buffer(device, bci)
    var req : VkMemoryRequirements
    vkGetBufferMemoryRequirements(boost_value_to_vk(device), boost_value_to_vk(buffer), req)
    var want : VkMemoryPropertyFlags
    want.host_visible = true
    want.host_coherent = true
    var mai : MemoryAllocateInfo
    mai.allocationSize = req.size
    mai.memoryTypeIndex = find_memory_type(phys, req.memoryTypeBits, want)
    var inscope memory <- allocate_memory(device, mai)
    vk_check(vkBindBufferMemory(boost_value_to_vk(device), boost_value_to_vk(buffer), boost_value_to_vk(memory), 0ul), null)
    var hb : HostBuffer
    hb.buffer <- buffer
    hb.memory <- memory
    hb.size = size
    return <- hb
}

//! HostBuffer with caller-chosen usage flags (vertex/index/uniform/storage/transfer_src/...). The
//! `(device, phys, size)` overload above hardcodes `transfer_dst` for the readback-buffer role;
//! this overload is the path tutorials reach for when they want a host-visible buffer with
//! arbitrary usage. Memory is still HOST_VISIBLE | HOST_COHERENT.
def public create_host_buffer(device : Device; phys : VkPhysicalDevice; size : uint64; usage : VkBufferUsageFlags) : HostBuffer {
    var bci : BufferCreateInfo
    bci.size = size
    bci.usage = usage
    var inscope buffer <- create_buffer(device, bci)
    var req : VkMemoryRequirements
    vkGetBufferMemoryRequirements(boost_value_to_vk(device), boost_value_to_vk(buffer), req)
    var want : VkMemoryPropertyFlags
    want.host_visible = true
    want.host_coherent = true
    var mai : MemoryAllocateInfo
    mai.allocationSize = req.size
    mai.memoryTypeIndex = find_memory_type(phys, req.memoryTypeBits, want)
    var inscope memory <- allocate_memory(device, mai)
    vk_check(vkBindBufferMemory(boost_value_to_vk(device), boost_value_to_vk(buffer), boost_value_to_vk(memory), 0ul), null)
    var hb : HostBuffer
    hb.buffer <- buffer
    hb.memory <- memory
    hb.size = size
    return <- hb
}

//! Typed upload of `array<TT>` into a HostBuffer: maps `length * sizeof<TT>` bytes, memcpys, unmaps.
//! Memory must be HOST_COHERENT (true for `create_host_buffer` allocations). No-op on an empty array.
def public upload_bytes(buf : HostBuffer; device : Device; var data : array<auto(TT)>) {
    if (empty(data)) return
    let nbytes = length(data) * typeinfo sizeof(type<TT>)
    assert(uint64(nbytes) <= buf.size, "upload_bytes: data exceeds destination HostBuffer.size")
    var mapped : void? = null
    let mf : VkMemoryMapFlags
    unsafe {
        vk_check(vkMapMemory(boost_value_to_vk(device), boost_value_to_vk(buf.memory), 0ul, uint64(nbytes), mf, addr(mapped)), null)
        memcpy(mapped, reinterpret<void?>(addr(data[0])), nbytes)
    }
    vkUnmapMemory(boost_value_to_vk(device), boost_value_to_vk(buf.memory))
}

//! Create a host-visible buffer sized to fit `data` and upload it in one call. The single-line
//! "vertex/index buffer from typed array" the tutorials all reach for. Panics on empty input:
//! Vulkan requires `VkBufferCreateInfo.size > 0` (VUID-VkBufferCreateInfo-size-00912), so an
//! empty array can't produce a valid buffer here.
def public create_host_buffer_from_bytes(device : Device; phys : VkPhysicalDevice;
                                         usage : VkBufferUsageFlags; var data : array<auto(TT)>) : HostBuffer {
    assert(!empty(data), "create_host_buffer_from_bytes: empty data — VkBuffer.size must be > 0")
    let nbytes = uint64(length(data) * typeinfo sizeof(type<TT>))
    var hb <- create_host_buffer(device, phys, nbytes, usage)
    hb |> upload_bytes(device, data)
    return <- hb
}

// ===== block brackets =====

//! allocate a one-shot primary command buffer, record the block, submit, wait idle
def public run_cmd_sync(device : Device; pool : CommandPool; queue : VkQueue; blk : block<(cmd : CommandBuffer) : void>) {
    var ai = VkCommandBufferAllocateInfo()
    ai.commandPool = boost_value_to_vk(pool)
    ai.level = VkCommandBufferLevel.PRIMARY
    ai.commandBufferCount = 1u
    var raw_cmd : VkCommandBuffer
    unsafe {
        vk_check(vkAllocateCommandBuffers(boost_value_to_vk(device), ai, addr(raw_cmd)), null)
    }
    let cmd = vk_value_to_boost(raw_cmd)   // non-owning wrapper (pool-freed below)
    let begin = VkCommandBufferBeginInfo()
    vk_check(vkBeginCommandBuffer(raw_cmd, begin), null)
    invoke(blk, cmd)
    vk_check(vkEndCommandBuffer(raw_cmd), null)
    var submit = VkSubmitInfo()
    submit.commandBufferCount = 1u
    unsafe {
        submit.pCommandBuffers = addr(raw_cmd)
        vk_check(vkQueueSubmit(queue, 1u, addr(submit), null), null)
    }
    vk_check(vkQueueWaitIdle(queue), null)
    unsafe {
        vkFreeCommandBuffers(boost_value_to_vk(device), boost_value_to_vk(pool), 1u, addr(raw_cmd))
    }
}

//! begin/end a render pass around the block, clearing to `clear`
def public record_render_pass(cmd : CommandBuffer; render_pass : RenderPass; framebuffer : Framebuffer;
                              area : VkRect2D; clear : VkClearValue; blk : block<() : void>) {
    var rp = VkRenderPassBeginInfo()
    rp.renderPass = boost_value_to_vk(render_pass)
    rp.framebuffer = boost_value_to_vk(framebuffer)
    rp.renderArea = area
    rp.clearValueCount = 1u
    var c = clear
    let raw_cmd = boost_value_to_vk(cmd)
    unsafe {
        rp.pClearValues = addr(c)
        vkCmdBeginRenderPass(raw_cmd, rp, VkSubpassContents.INLINE)
    }
    invoke(blk)
    vkCmdEndRenderPass(raw_cmd)
}

//! multi-clear overload: one VkClearValue per attachment, in framebuffer attachment order.
//! Use with `create_render_pass_color_depth` (clears = [color, depth]). The single-clear overload
//! above covers the no-clear / one-attachment case; this one is for per-attachment clears, so an
//! empty `clears` is always a caller bug (CLEAR loadOp attachments would read uninitialized
//! VkClearValues -- VUID-VkRenderPassBeginInfo-clearValueCount-00902).
def public record_render_pass(cmd : CommandBuffer; render_pass : RenderPass; framebuffer : Framebuffer;
                              area : VkRect2D; var clears : array<VkClearValue>; blk : block<() : void>) {
    assert(!empty(clears), "record_render_pass multi-clear: clears must be non-empty (one per attachment)")
    var rp = VkRenderPassBeginInfo()
    rp.renderPass = boost_value_to_vk(render_pass)
    rp.framebuffer = boost_value_to_vk(framebuffer)
    rp.renderArea = area
    rp.clearValueCount = uint(length(clears))
    let raw_cmd = boost_value_to_vk(cmd)
    unsafe {
        rp.pClearValues = addr(clears[0])
        vkCmdBeginRenderPass(raw_cmd, rp, VkSubpassContents.INLINE)
    }
    invoke(blk)
    vkCmdEndRenderPass(raw_cmd)
}

//! Block-form device-memory mapping. Maps the whole allocation (VK_WHOLE_SIZE), invokes the block
//! with the raw mapped pointer, unmaps on block return. Used by the SpirvVulkanShader bind_uniform
//! macro for one-shot UBO upload: the block writes typed fields at known std140 offsets via
//! `write_field`. **Memory must be HOST_VISIBLE | HOST_COHERENT**: with HOST_COHERENT the GPU sees
//! the writes after vkUnmapMemory without an explicit flush; non-coherent memory needs a
//! vkFlushMappedMemoryRanges between the writes and the unmap, which this helper does NOT do. The
//! standard dasVulkan UBO allocation path (mhb / create_host_buffer) picks coherent memory, so the
//! tutorials are safe; if you allocate non-coherent memory yourself, wrap the writes accordingly.
def public with_mapped_memory(device : Device; memory : DeviceMemory; blk : block<(ptr : void?) : void>) {
    var mapped : void? = null
    var flags : VkMemoryMapFlags
    unsafe {
        vk_check(vkMapMemory(boost_value_to_vk(device), boost_value_to_vk(memory), 0ul, VK_WHOLE_SIZE, flags, addr(mapped)), null)
    }
    invoke(blk, mapped)
    vkUnmapMemory(boost_value_to_vk(device), boost_value_to_vk(memory))
}

//! Write a single typed value at a byte offset into mapped device memory (one memcpy of sizeof<TT>
//! bytes). Designed for std140 field writes: the bind_uniform macro emits one call per @uniform-block
//! field at its compile-time-computed offset. TT = any 32-bit scalar / vec / float4x4 / float3x4 with
//! the daslang storage matching std140 directly. float3x3 needs per-column writes (not this).
def public write_field(ptr : void?; offset : uint; var value : auto(TT) const) {
    unsafe {
        let dst = reinterpret<void?>(intptr(ptr) + uint64(offset))
        memcpy(dst, reinterpret<void?>(addr(value)), typeinfo sizeof(type<TT>))
    }
}

//! map a device-memory range, expose it as an array<uint8>, unmap after the block
def public map_memory_to_array(device : Device; memory : DeviceMemory; size : uint64; blk : block<(data : array<uint8>) : void>) {
    var mapped : void? = null
    var flags : VkMemoryMapFlags
    unsafe {
        vk_check(vkMapMemory(boost_value_to_vk(device), boost_value_to_vk(memory), 0ul, size, flags, addr(mapped)), null)
    }
    var arr : array<uint8>
    arr |> resize(int(size))
    unsafe {
        memcpy(reinterpret<void?>(addr(arr[0])), mapped, int(size))
    }
    vkUnmapMemory(boost_value_to_vk(device), boost_value_to_vk(memory))
    invoke(blk, arr)
    delete arr
}

//! map a device-memory range, copy `count` elements of T into an owned array<T>, unmap.
//! The typed/copying readback — no block, no manual memcpy/reinterpret at the call site.
[unused_argument(elem)] def public read_memory(device : Device; memory : DeviceMemory; elem : type<auto(TT)>; count : int) : array<TT> {
    var out : array<TT>
    if (count <= 0) {
        return <- out
    }
    out |> resize(count)
    let nbytes = count * typeinfo sizeof(type<TT>)
    var mapped : void? = null
    let flags : VkMemoryMapFlags
    unsafe {
        vk_check(vkMapMemory(boost_value_to_vk(device), boost_value_to_vk(memory), 0ul, uint64(nbytes), flags, addr(mapped)), null)
        memcpy(reinterpret<void?>(addr(out[0])), mapped, nbytes)
    }
    vkUnmapMemory(boost_value_to_vk(device), boost_value_to_vk(memory))
    return <- out
}

// ===== conveniences =====

def public full_area(width, height : int) : VkRect2D {
    var r : VkRect2D
    r.extent.width = uint(width)
    r.extent.height = uint(height)
    return r
}

def public clear_color(r, g, b, a : float) : VkClearValue {
    var c : VkClearValue
    c.color.float32[0] = r
    c.color.float32[1] = g
    c.color.float32[2] = b
    c.color.float32[3] = a
    return c
}

//! `depth` clear in [0, 1] (1.0 is the "far" reset for the standard z-buffer convention).
def public clear_depth(depth : float = 1.0f; stencil : uint = 0u) : VkClearValue {
    var c : VkClearValue
    c.depthStencil.depth = depth
    c.depthStencil.stencil = stencil
    return c
}

//! Depth-compare ("shadow") sampler. Enables `compareEnable` + `compareOp = LESS`. Vulkan's
//! per-tap result is `reference compareOp sampledDepth`, so with `LESS` the comparison fires when
//! `ref < sampledDepth` → the fragment's light-space depth is closer to the light than the stored
//! depth → not occluded → return 1 = lit. LINEAR filtering so the hardware PCFs the 2x2 footprint
//! around the sample point. Address mode is CLAMP_TO_BORDER with a white (fully-lit)
//! border so off-shadow-map fragments default to lit, the convention every shadow-map tutorial
//! relies on. Consumed by `sampler2DShadow` + `textureCompare(...)` in the shader.
def public create_sampler_shadow(device : Device; compare_op : VkCompareOp = VkCompareOp.LESS) : Sampler {
    var sci : SamplerCreateInfo
    sci.magFilter = VkFilter.LINEAR
    sci.minFilter = VkFilter.LINEAR
    sci.mipmapMode = VkSamplerMipmapMode.LINEAR
    sci.addressModeU = VkSamplerAddressMode.CLAMP_TO_BORDER
    sci.addressModeV = VkSamplerAddressMode.CLAMP_TO_BORDER
    sci.addressModeW = VkSamplerAddressMode.CLAMP_TO_BORDER
    sci.borderColor = VkBorderColor.FLOAT_OPAQUE_WHITE
    sci.compareEnable = VK_TRUE
    sci.compareOp = compare_op
    return <- create_sampler(device, sci)
}

//! bind a pipeline (defaults to the graphics bind point; pass COMPUTE for a compute pipeline)
def public cmd_bind_pipeline(cmd : CommandBuffer; pipeline : Pipeline; bind_point : VkPipelineBindPoint = VkPipelineBindPoint.GRAPHICS) {
    vkCmdBindPipeline(boost_value_to_vk(cmd), bind_point, boost_value_to_vk(pipeline))
}

//! draw (convenience over the generated cmd_draw: defaults instance/first to 0)
def public cmd_draw(cmd : CommandBuffer; vertex_count : uint; instance_count : uint = 1u) {
    vkCmdDraw(boost_value_to_vk(cmd), vertex_count, instance_count, 0u, 0u)
}

//! Bind one vertex buffer at the given binding slot (offset 0 by default). The generated
//! `cmd_bind_vertex_buffers` takes `array<Buffer>` + `array<uint64>` which forces a per-frame
//! allocation for single-binding draws; this overload avoids it.
def public cmd_bind_vertex_buffer(cmd : CommandBuffer; binding : uint; buffer : Buffer; offset : uint64 = 0ul) {
    var raw_buf = boost_value_to_vk(buffer)
    var off = offset
    unsafe {
        vkCmdBindVertexBuffers(boost_value_to_vk(cmd), binding, 1u, addr(raw_buf), addr(off))
    }
}

//! Typed push-constant upload: writes `sizeof<TT>` bytes from `value` into the pipeline's push
//! block at `offset`, for shader stages `stages`. The size is derived from the daslang value, so
//! the call site no longer carries a hand-counted byte size or a `reinterpret<void?>(addr(...))`.
//! TT's daslang layout must match the shader's std430 push-constant layout (true for scalar /
//! vec4 / mat4 packs without vec3 padding surprises). Vulkan requires both `offset` and the
//! resolved size to be multiples of 4 (VUID-vkCmdPushConstants-offset-00370 /
//! VUID-vkCmdPushConstants-size-00369), so this asserts both — using e.g. a `bool` or `uint8`
//! TT silently trips driver validation otherwise.
def public cmd_push_constants(cmd : CommandBuffer; layout : PipelineLayout; stages : VkShaderStageFlags;
                              offset : uint; var value : auto(TT) const) {
    let sz = uint(typeinfo sizeof(type<TT>))
    assert((offset & 3u) == 0u, "cmd_push_constants: offset must be a multiple of 4")
    assert((sz & 3u) == 0u, "cmd_push_constants: sizeof<TT> must be a multiple of 4")
    unsafe {
        vkCmdPushConstants(boost_value_to_vk(cmd), boost_value_to_vk(layout), stages,
            offset, sz, reinterpret<void?>(addr(value)))
    }
}

def public copy_image_to_buffer(cmd : CommandBuffer; image : Image; buffer : HostBuffer; width, height : int) {
    var region : VkBufferImageCopy
    region.imageSubresource.aspectMask.color = true
    region.imageSubresource.layerCount = 1u
    region.imageExtent.width = uint(width)
    region.imageExtent.height = uint(height)
    region.imageExtent.depth = 1u
    unsafe {
        vkCmdCopyImageToBuffer(boost_value_to_vk(cmd), boost_value_to_vk(image), VkImageLayout.TRANSFER_SRC_OPTIMAL,
            boost_value_to_vk(buffer.buffer), 1u, addr(region))
    }
}
