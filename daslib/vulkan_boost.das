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
    // array<string> is contiguous `const char*` pointers == const char* const* (what
    // Vulkan wants); ppEnabledExtensionNames is bound as void? so reinterpret to it.
    if (!empty(extensions)) {
        ci.enabledExtensionCount = uint(length(extensions))
        unsafe {
            ci.ppEnabledExtensionNames = reinterpret<void?>(addr(extensions[0]))
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

def public create_device(phys : VkPhysicalDevice; queue_family : uint) : Device {
    let no_ext : array<string>
    return <- create_device(phys, queue_family, no_ext)
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

def public create_graphics_pipeline_simple(device : Device; render_pass : RenderPass; layout : PipelineLayout;
        vert : ShaderModule; frag : ShaderModule; width, height : int) : Pipeline {
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

    var gp = VkGraphicsPipelineCreateInfo()
    gp.stageCount = 2u
    gp.layout = boost_value_to_vk(layout)
    gp.renderPass = boost_value_to_vk(render_pass)
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
        gp.pColorBlendState = addr(blend)
        vk_check(vkCreateGraphicsPipelines(boost_value_to_vk(device), null, 1u, addr(gp), null, addr(h)), null)
    }
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    b._device = unsafe(reinterpret<uint64>(boost_value_to_vk(device)))
    return <- b
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

// ===== block brackets =====

//! allocate a one-shot primary command buffer, record the block, submit, wait idle
def public run_cmd_sync(device : Device; pool : CommandPool; queue : VkQueue; blk : block<(cmd : VkCommandBuffer) : void>) {
    var ai = VkCommandBufferAllocateInfo()
    ai.commandPool = boost_value_to_vk(pool)
    ai.level = VkCommandBufferLevel.PRIMARY
    ai.commandBufferCount = 1u
    var cmd : VkCommandBuffer
    unsafe {
        vk_check(vkAllocateCommandBuffers(boost_value_to_vk(device), ai, addr(cmd)), null)
    }
    var begin = VkCommandBufferBeginInfo()
    vk_check(vkBeginCommandBuffer(cmd, begin), null)
    invoke(blk, cmd)
    vk_check(vkEndCommandBuffer(cmd), null)
    var submit = VkSubmitInfo()
    submit.commandBufferCount = 1u
    unsafe {
        submit.pCommandBuffers = addr(cmd)
        vk_check(vkQueueSubmit(queue, 1u, addr(submit), null), null)
    }
    vk_check(vkQueueWaitIdle(queue), null)
    unsafe {
        vkFreeCommandBuffers(boost_value_to_vk(device), boost_value_to_vk(pool), 1u, addr(cmd))
    }
}

//! begin/end a render pass around the block, clearing to `clear`
def public record_render_pass(cmd : VkCommandBuffer; render_pass : RenderPass; framebuffer : Framebuffer;
        area : VkRect2D; clear : VkClearValue; blk : block<() : void>) {
    var rp = VkRenderPassBeginInfo()
    rp.renderPass = boost_value_to_vk(render_pass)
    rp.framebuffer = boost_value_to_vk(framebuffer)
    rp.renderArea = area
    rp.clearValueCount = 1u
    var c = clear
    unsafe {
        rp.pClearValues = addr(c)
        vkCmdBeginRenderPass(cmd, rp, VkSubpassContents.INLINE)
    }
    invoke(blk)
    vkCmdEndRenderPass(cmd)
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

def public cmd_bind_pipeline(cmd : VkCommandBuffer; pipeline : Pipeline) {
    vkCmdBindPipeline(cmd, VkPipelineBindPoint.GRAPHICS, boost_value_to_vk(pipeline))
}

def public cmd_draw(cmd : VkCommandBuffer; vertex_count : uint; instance_count : uint = 1u) {
    vkCmdDraw(cmd, vertex_count, instance_count, 0u, 0u)
}

def public copy_image_to_buffer(cmd : VkCommandBuffer; image : Image; buffer : HostBuffer; width, height : int) {
    var region : VkBufferImageCopy
    region.imageSubresource.aspectMask.color = true
    region.imageSubresource.layerCount = 1u
    region.imageExtent.width = uint(width)
    region.imageExtent.height = uint(height)
    region.imageExtent.depth = 1u
    unsafe {
        vkCmdCopyImageToBuffer(cmd, boost_value_to_vk(image), VkImageLayout.TRANSFER_SRC_OPTIMAL,
            boost_value_to_vk(buffer.buffer), 1u, addr(region))
    }
}
