options gen2
options indenting = 4

// Shared offscreen scenes for the integration tests: render the triangle and
// run the compute square, returning the result data for assertions. No [test]
// functions here -- required by the test files.

module scene_helpers

require vulkan public
require vulkan/vulkan_boost public
require compute_shaders
require triangle_shaders
require phase4_shaders
require vulkan/vulkan_reflect

let TRI_W = 256
let TRI_H = 256

//! render the RGB triangle offscreen and return the RGBA pixels (TRI_W*TRI_H*4)
def public render_triangle() : array<uint8> {
    if (volkInitialize() != 0) {
        panic("no Vulkan loader")
    }
    var pixels : array<uint8>
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
    var fbci : FramebufferCreateInfo
    fbci.renderPass = weak_copy(render_pass)
    fbci.pAttachments <- [weak_copy(target.view)]
    fbci.width = uint(TRI_W)
    fbci.height = uint(TRI_H)
    fbci.layers = 1u
    var inscope framebuffer <- create_framebuffer(device, fbci)

    // tri_vert_spv / tri_frag_spv are emitted by dasSpirv from triangle_shaders.das (array<uint> words)
    var inscope vert <- create_shader_module(device, tri_vert_spv)
    var inscope frag <- create_shader_module(device, tri_frag_spv)
    var inscope layout <- create_pipeline_layout(device)
    var inscope pipeline <- create_graphics_pipeline_simple(device, render_pass, layout, vert, frag, TRI_W, TRI_H)

    let buf_size = uint64(TRI_W * TRI_H * 4)
    var inscope readback <- create_host_buffer(device, phys, buf_size)
    var poolci : CommandPoolCreateInfo
    poolci.queueFamilyIndex = gfx
    var inscope pool <- create_command_pool(device, poolci)

    run_cmd_sync(device, pool, queue) $(cmd) {
        record_render_pass(cmd, render_pass, framebuffer, full_area(TRI_W, TRI_H), clear_color(0.1f, 0.1f, 0.15f, 1.0f)) {
            cmd_bind_pipeline(cmd, pipeline)
            cmd_draw(cmd, 3u)
        }
        copy_image_to_buffer(cmd, target.image, readback, TRI_W, TRI_H)
    }
    map_memory_to_array(device, readback.memory, buf_size) $(m) {
        pixels := m
    }
    return <- pixels
}

//! run the compute square (out[i] = i*i) over `n` elements and return the result
def public run_compute(n : int) : array<uint> {
    if (volkInitialize() != 0) {
        panic("no Vulkan loader")
    }
    var values : array<uint>
    values |> resize(n)
    var inscope instance <- create_instance("dasVulkan test", make_api_version(1u, 3u, 0u))
    volkLoadInstance(boost_value_to_vk(instance))
    let phys = select_physical_device(instance)
    let gfx = select_graphics_queue_family(phys)
    var inscope device <- create_device(phys, gfx)
    volkLoadDevice(boost_value_to_vk(device))
    let dev = boost_value_to_vk(device)
    let queue = get_device_queue(device, gfx, 0u)

    let buf_size = uint64(n * 4)
    var bci = VkBufferCreateInfo()
    bci.size = buf_size
    bci.usage.storage_buffer = true
    var buffer : VkBuffer
    vk_check(vkCreateBuffer(dev, bci, null, buffer), null)
    var req : VkMemoryRequirements
    vkGetBufferMemoryRequirements(dev, buffer, req)
    var want : VkMemoryPropertyFlags
    want.host_visible = true
    want.host_coherent = true
    var mai = VkMemoryAllocateInfo()
    mai.allocationSize = req.size
    mai.memoryTypeIndex = find_memory_type(phys, req.memoryTypeBits, want)
    var memory : VkDeviceMemory
    vk_check(vkAllocateMemory(dev, mai, null, memory), null)
    vk_check(vkBindBufferMemory(dev, buffer, memory, 0ul), null)

    var binding : VkDescriptorSetLayoutBinding
    binding.descriptorType = VkDescriptorType.STORAGE_BUFFER
    binding.descriptorCount = 1u
    binding.stageFlags.compute = true
    var dslci = VkDescriptorSetLayoutCreateInfo()
    dslci.bindingCount = 1u
    var set_layout : VkDescriptorSetLayout
    unsafe {
        dslci.pBindings = addr(binding)
        vk_check(vkCreateDescriptorSetLayout(dev, dslci, null, set_layout), null)
    }
    var pool_size : VkDescriptorPoolSize
    pool_size.type_ = VkDescriptorType.STORAGE_BUFFER
    pool_size.descriptorCount = 1u
    var dpci = VkDescriptorPoolCreateInfo()
    dpci.maxSets = 1u
    dpci.poolSizeCount = 1u
    var desc_pool : VkDescriptorPool
    unsafe {
        dpci.pPoolSizes = addr(pool_size)
        vk_check(vkCreateDescriptorPool(dev, dpci, null, desc_pool), null)
    }
    var dsai = VkDescriptorSetAllocateInfo()
    dsai.descriptorPool = desc_pool
    dsai.descriptorSetCount = 1u
    var desc_set : VkDescriptorSet
    unsafe {
        dsai.pSetLayouts = addr(set_layout)
        vk_check(vkAllocateDescriptorSets(dev, dsai, addr(desc_set)), null)
    }
    var dbinfo : VkDescriptorBufferInfo
    dbinfo.buffer = buffer
    dbinfo.range_ = buf_size
    var write = VkWriteDescriptorSet()
    write.dstSet = desc_set
    write.descriptorCount = 1u
    write.descriptorType = VkDescriptorType.STORAGE_BUFFER
    unsafe {
        write.pBufferInfo = addr(dbinfo)
        vkUpdateDescriptorSets(dev, 1u, addr(write), 0u, null)
    }
    var inscope shader <- create_shader_module(device, square_spv)
    var plci = VkPipelineLayoutCreateInfo()
    plci.setLayoutCount = 1u
    var pipe_layout : VkPipelineLayout
    unsafe {
        plci.pSetLayouts = addr(set_layout)
        vk_check(vkCreatePipelineLayout(dev, plci, null, pipe_layout), null)
    }
    var stage = VkPipelineShaderStageCreateInfo()
    stage.stage.compute = true
    stage.module_ = boost_value_to_vk(shader)
    stage.pName = "main"
    var cpci = VkComputePipelineCreateInfo()
    cpci.stage = stage
    cpci.layout = pipe_layout
    var pipeline : VkPipeline
    unsafe {
        vk_check(vkCreateComputePipelines(dev, null, 1u, addr(cpci), null, addr(pipeline)), null)
    }
    var poolci : CommandPoolCreateInfo
    poolci.queueFamilyIndex = gfx
    var inscope pool <- create_command_pool(device, poolci)
    run_cmd_sync(device, pool, queue) $(cmd) {
        vkCmdBindPipeline(boost_value_to_vk(cmd), VkPipelineBindPoint.COMPUTE, pipeline)
        unsafe {
            vkCmdBindDescriptorSets(boost_value_to_vk(cmd), VkPipelineBindPoint.COMPUTE, pipe_layout, 0u, 1u, addr(desc_set), 0u, null)
        }
        cmd_dispatch(cmd, uint(n / 64), 1u, 1u)
    }
    var mapped : void? = null
    var mf : VkMemoryMapFlags
    unsafe {
        vk_check(vkMapMemory(dev, memory, 0ul, buf_size, mf, addr(mapped)), null)
        memcpy(reinterpret<void?>(addr(values[0])), mapped, n * 4)
    }
    vkUnmapMemory(dev, memory)
    vkDestroyPipeline(dev, pipeline, null)
    vkDestroyPipelineLayout(dev, pipe_layout, null)
    vkDestroyDescriptorPool(dev, desc_pool, null)
    vkDestroyDescriptorSetLayout(dev, set_layout, null)
    vkDestroyBuffer(dev, buffer, null)
    vkFreeMemory(dev, memory, null)
    return <- values
}

def public px(pixels : array<uint8>; x, y : int) : int3 {
    let p = (y * TRI_W + x) * 4
    return int3(int(pixels[p]), int(pixels[p + 1]), int(pixels[p + 2]))
}

//! the dasSpirv GPU gate: run an arbitrary emitted SPIR-V compute blob (`words`) over `n`
//! elements and return the result, with descriptor layout / pool / update all through the
//! BOOST path. The storage-buffer binding has descriptorCount = 1 with no immutable samplers
//! -- the independent-count case the erasure model got wrong (would yield 0, so the shader
//! would not see the buffer and out[i] would not equal i*i). run_compute_boost feeds the
//! daslang-emitted `square_spv` through here; any future [compute_shader] blob reuses it.
def public run_compute_spirv(var words : array<uint>; n : int) : array<uint> {
    if (volkInitialize() != 0) {
        panic("no Vulkan loader")
    }
    var values : array<uint>
    values |> resize(n)
    var inscope instance <- create_instance("dasVulkan test", make_api_version(1u, 3u, 0u))
    volkLoadInstance(boost_value_to_vk(instance))
    let phys = select_physical_device(instance)
    let gfx = select_graphics_queue_family(phys)
    var inscope device <- create_device(phys, gfx)
    volkLoadDevice(boost_value_to_vk(device))
    let dev = boost_value_to_vk(device)
    let queue = get_device_queue(device, gfx, 0u)

    let buf_size = uint64(n * 4)
    var bci : BufferCreateInfo
    bci.size = buf_size
    bci.usage.storage_buffer = true
    var inscope buffer <- create_buffer(device, bci)
    var req : VkMemoryRequirements
    vkGetBufferMemoryRequirements(dev, boost_value_to_vk(buffer), req)
    var want : VkMemoryPropertyFlags
    want.host_visible = true
    want.host_coherent = true
    var mai : MemoryAllocateInfo
    mai.allocationSize = req.size
    mai.memoryTypeIndex = find_memory_type(phys, req.memoryTypeBits, want)
    var inscope memory <- allocate_memory(device, mai)
    vk_check(vkBindBufferMemory(dev, boost_value_to_vk(buffer), boost_value_to_vk(memory), 0ul), null)

    // descriptor set layout + pool via BOOST (descriptorCount = 1, no samplers)
    var dslci : DescriptorSetLayoutCreateInfo
    var b0 : DescriptorSetLayoutBinding
    b0.binding = 0u
    b0.descriptorType = VkDescriptorType.STORAGE_BUFFER
    b0.descriptorCount = 1u
    b0.stageFlags.compute = true
    dslci.pBindings |> emplace(b0)
    var inscope set_layout <- create_descriptor_set_layout(device, dslci)

    var dpci : DescriptorPoolCreateInfo
    dpci.maxSets = 1u
    var psize : DescriptorPoolSize
    psize.type_ = VkDescriptorType.STORAGE_BUFFER
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

    // bind the buffer through BOOST update_descriptor_sets (descriptorCount = 1, only pBufferInfo)
    var write : WriteDescriptorSet
    write.dstSet = vk_value_to_boost(raw_set)
    write.dstBinding = 0u
    write.descriptorType = VkDescriptorType.STORAGE_BUFFER
    write.descriptorCount = 1u
    var binfo : DescriptorBufferInfo
    binfo.buffer = weak_copy(buffer)
    binfo.range_ = buf_size
    write.pBufferInfo |> push(binfo)
    var writes : array<WriteDescriptorSet>
    writes |> emplace(write)
    var no_copies : array<CopyDescriptorSet>
    update_descriptor_sets(device, writes, no_copies)

    // compute pipeline (raw: compute pipelines are batch-created)
    var inscope shader <- create_shader_module(device, words)
    var plci : PipelineLayoutCreateInfo
    plci.pSetLayouts <- [weak_copy(set_layout)]
    var inscope pipe_layout <- create_pipeline_layout(device, plci)
    var stage = VkPipelineShaderStageCreateInfo()
    stage.stage.compute = true
    stage.module_ = boost_value_to_vk(shader)
    stage.pName = "main"
    var cpci = VkComputePipelineCreateInfo()
    cpci.stage = stage
    cpci.layout = boost_value_to_vk(pipe_layout)
    var pipeline : VkPipeline
    unsafe {
        vk_check(vkCreateComputePipelines(dev, null, 1u, addr(cpci), null, addr(pipeline)), null)
    }

    var inscope pool <- create_command_pool(device, pool_info(gfx))
    run_cmd_sync(device, pool, queue) $(cmd) {
        vkCmdBindPipeline(boost_value_to_vk(cmd), VkPipelineBindPoint.COMPUTE, pipeline)
        unsafe {
            vkCmdBindDescriptorSets(boost_value_to_vk(cmd), VkPipelineBindPoint.COMPUTE, boost_value_to_vk(pipe_layout), 0u, 1u, addr(raw_set), 0u, null)
        }
        cmd_dispatch(cmd, uint(n / 64), 1u, 1u)
    }

    var mapped : void? = null
    var mf : VkMemoryMapFlags
    unsafe {
        vk_check(vkMapMemory(dev, boost_value_to_vk(memory), 0ul, buf_size, mf, addr(mapped)), null)
        memcpy(reinterpret<void?>(addr(values[0])), mapped, n * 4)
    }
    vkUnmapMemory(dev, boost_value_to_vk(memory))
    vkDestroyPipeline(dev, pipeline, null)
    return <- values
}

//! the boost-descriptor compute square, now fed by the daslang-emitted `square_spv` blob.
def public run_compute_boost(n : int) : array<uint> {
    return <- run_compute_spirv(square_spv, n)
}

def private pool_info(queue_family : uint) : CommandPoolCreateInfo {
    var ci : CommandPoolCreateInfo
    ci.queueFamilyIndex = queue_family
    return ci
}

// ===== Phase-4 GPU gate: UBO matrix + push constant + combined image sampler =====

def private make_host_buffer(device : Device; phys : VkPhysicalDevice; size : uint64; usage : VkBufferUsageFlags) : HostBuffer {
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

def private upload(device : Device; memory : DeviceMemory; var data : array<auto(TT)>) {
    if (empty(data)) return            // vkMapMemory(size=0) is invalid; nothing to copy
    let nbytes = length(data) * typeinfo sizeof(type<TT>)
    var mapped : void? = null
    var mf : VkMemoryMapFlags
    unsafe {
        vk_check(vkMapMemory(boost_value_to_vk(device), boost_value_to_vk(memory), 0ul, uint64(nbytes), mf, addr(mapped)), null)
        memcpy(mapped, reinterpret<void?>(addr(data[0])), nbytes)
    }
    vkUnmapMemory(boost_value_to_vk(device), boost_value_to_vk(memory))
}

def private transition_image(cmd : CommandBuffer; image : Image; old_layout, new_layout : VkImageLayout;
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

//! Phase-4 GPU gate: render a textured quad transformed by a UBO MVP and modulated by a
//! push-constant tint; returns the RGBA pixels (TRI_W*TRI_H*4). Exercises the dasSpirv Phase-4
//! surface end to end on a real driver -- @uniform float4x4 (uploaded column-major), a combined
//! image sampler, and a push constant -- the parts spirv-val cannot verify semantically. The MVP
//! scales by 0.6 and translates x by +0.4: the translation lives in matrix column 3, so a correct
//! render (quad shifted right) proves daslang's column-major float4x4 matches the emitter's ColMajor
//! decoration. tint=(1,1,0) zeroes blue: a white texel rendering yellow proves the push constant.
def public render_textured_quad() : array<uint8> {
    if (volkInitialize() != 0) {
        panic("no Vulkan loader")
    }
    var pixels : array<uint8>
    var inscope instance <- create_instance("dasVulkan test", make_api_version(1u, 3u, 0u))
    volkLoadInstance(boost_value_to_vk(instance))
    let phys = select_physical_device(instance)
    let gfx = select_graphics_queue_family(phys)
    var inscope device <- create_device(phys, gfx)
    volkLoadDevice(boost_value_to_vk(device))
    let dev = boost_value_to_vk(device)
    let queue = get_device_queue(device, gfx, 0u)
    let fmt = VkFormat.R8G8B8A8_UNORM

    // offscreen color target + render pass + framebuffer (as render_triangle)
    var inscope target <- build_offscreen_target(device, phys, TRI_W, TRI_H, fmt)
    var inscope render_pass <- create_render_pass_single_color(device, fmt)
    var fbci : FramebufferCreateInfo
    fbci.renderPass = weak_copy(render_pass)
    fbci.pAttachments <- [weak_copy(target.view)]
    fbci.width = uint(TRI_W)
    fbci.height = uint(TRI_H)
    fbci.layers = 1u
    var inscope framebuffer <- create_framebuffer(device, fbci)

    // UBO: a single column-major MVP. Columns are contiguous; the translation (0.4, 0) is column 3.
    var mvp <- [
        0.6f, 0.0f, 0.0f, 0.0f,     // column 0
        0.0f, 0.6f, 0.0f, 0.0f,     // column 1
        0.0f, 0.0f, 1.0f, 0.0f,     // column 2
        0.4f, 0.0f, 0.0f, 1.0f]     // column 3 (translation x = +0.4)
    var ubo_usage : VkBufferUsageFlags
    ubo_usage.uniform_buffer = true
    var inscope ubo <- make_host_buffer(device, phys, 64ul, ubo_usage)
    upload(device, ubo.memory, mvp)
    delete mvp

    // texture: a 2x2 RGBA checkerboard, row 0 = red,green and row 1 = blue,white (NEAREST sampled)
    var texels <- [for (c in fixed_array(
        255, 0, 0, 255,         // texel (0,0) red
        0, 255, 0, 255,         // texel (1,0) green
        0, 0, 255, 255,         // texel (0,1) blue
        255, 255, 255, 255));   // texel (1,1) white
        uint8(c)]
    var staging_usage : VkBufferUsageFlags
    staging_usage.transfer_src = true
    var inscope staging <- make_host_buffer(device, phys, 16ul, staging_usage)
    upload(device, staging.memory, texels)
    delete texels

    var ici : ImageCreateInfo
    ici.imageType = VkImageType._2D
    ici.format = fmt
    ici.extent.width = 2u
    ici.extent.height = 2u
    ici.extent.depth = 1u
    ici.mipLevels = 1u
    ici.arrayLayers = 1u
    ici.samples._1 = true
    ici.tiling = VkImageTiling.OPTIMAL
    ici.usage.sampled = true
    ici.usage.transfer_dst = true
    ici.initialLayout = VkImageLayout.UNDEFINED
    var inscope tex_image <- create_image(device, ici)
    var ireq : VkMemoryRequirements
    vkGetImageMemoryRequirements(dev, boost_value_to_vk(tex_image), ireq)
    var iwant : VkMemoryPropertyFlags
    iwant.device_local = true
    var imai : MemoryAllocateInfo
    imai.allocationSize = ireq.size
    imai.memoryTypeIndex = find_memory_type(phys, ireq.memoryTypeBits, iwant)
    var inscope tex_memory <- allocate_memory(device, imai)
    vk_check(vkBindImageMemory(dev, boost_value_to_vk(tex_image), boost_value_to_vk(tex_memory), 0ul), null)

    var tvci : ImageViewCreateInfo
    tvci.image = weak_copy(tex_image)
    tvci.viewType = VkImageViewType._2D
    tvci.format = fmt
    tvci.subresourceRange.aspectMask.color = true
    tvci.subresourceRange.levelCount = 1u
    tvci.subresourceRange.layerCount = 1u
    var inscope tex_view <- create_image_view(device, tvci)

    var sci : SamplerCreateInfo
    sci.magFilter = VkFilter.NEAREST
    sci.minFilter = VkFilter.NEAREST
    sci.mipmapMode = VkSamplerMipmapMode.NEAREST
    sci.addressModeU = VkSamplerAddressMode.CLAMP_TO_EDGE
    sci.addressModeV = VkSamplerAddressMode.CLAMP_TO_EDGE
    sci.addressModeW = VkSamplerAddressMode.CLAMP_TO_EDGE
    sci.maxLod = 1.0f
    var inscope sampler <- create_sampler(device, sci)

    // Descriptor + pipeline layouts come straight from the shaders' own dasSpirv reflection (the
    // single source of truth) instead of being hand-declared: the quad_vert UBO @set0/@binding0
    // (vertex) and the quad_frag sampler @set0/@binding1 (fragment) and the fragment push-constant
    // range are all derived from quad_vert_spv_reflect / quad_frag_spv_reflect.
    var reflections <- [decode_reflection(quad_vert_spv_reflect), decode_reflection(quad_frag_spv_reflect)]
    var inscope set_layouts <- build_descriptor_set_layouts(device, reflections)

    var dpci : DescriptorPoolCreateInfo
    dpci.maxSets = 1u
    var ps0 : DescriptorPoolSize
    ps0.type_ = VkDescriptorType.UNIFORM_BUFFER
    ps0.descriptorCount = 1u
    dpci.pPoolSizes |> push(ps0)
    var ps1 : DescriptorPoolSize
    ps1.type_ = VkDescriptorType.COMBINED_IMAGE_SAMPLER
    ps1.descriptorCount = 1u
    dpci.pPoolSizes |> push(ps1)
    var inscope desc_pool <- create_descriptor_pool(device, dpci)

    var dsai = VkDescriptorSetAllocateInfo()
    dsai.descriptorPool = boost_value_to_vk(desc_pool)
    dsai.descriptorSetCount = 1u
    var raw_set_layout = boost_value_to_vk(set_layouts[0])
    var raw_set : VkDescriptorSet
    unsafe {
        dsai.pSetLayouts = addr(raw_set_layout)
        vk_check(vkAllocateDescriptorSets(dev, dsai, addr(raw_set)), null)
    }

    var writes : array<WriteDescriptorSet>
    var w0 : WriteDescriptorSet
    w0.dstSet = vk_value_to_boost(raw_set)
    w0.dstBinding = 0u
    w0.descriptorType = VkDescriptorType.UNIFORM_BUFFER
    w0.descriptorCount = 1u
    var binfo : DescriptorBufferInfo
    binfo.buffer = weak_copy(ubo.buffer)
    binfo.range_ = 64ul
    w0.pBufferInfo |> push(binfo)
    writes |> emplace(w0)
    var w1 : WriteDescriptorSet
    w1.dstSet = vk_value_to_boost(raw_set)
    w1.dstBinding = 1u
    w1.descriptorType = VkDescriptorType.COMBINED_IMAGE_SAMPLER
    w1.descriptorCount = 1u
    var iinfo : DescriptorImageInfo
    iinfo.sampler = weak_copy(sampler)
    iinfo.imageView = weak_copy(tex_view)
    iinfo.imageLayout = VkImageLayout.SHADER_READ_ONLY_OPTIMAL
    w1.pImageInfo |> push(iinfo)
    writes |> emplace(w1)
    var no_copies : array<CopyDescriptorSet>
    update_descriptor_sets(device, writes, no_copies)

    // pipeline layout (descriptor set + fragment push-constant range) is built from the same reflection.
    var inscope pipe_layout <- build_pipeline_layout(device, set_layouts, reflections)
    // The push-constant size is reflected too — Tint{float3} is 12 bytes (std140 vec3), so the command
    // below pushes exactly what the layout declares rather than the over-sized 16 the hand-build used.
    var push_size = 0u
    var have_push = false
    for (refl in reflections) {
        for (p in refl.push_constants) {
            // this gate has exactly one push range (fragment Tint at offset 0); assert that shape rather
            // than silently pushing 0 if reflection ever stops reporting it.
            assert(p.offset == 0, "reflected push-constant range must start at offset 0 for this gate")
            push_size = uint(p.size)
            have_push = true
        }
    }
    assert(have_push, "expected a reflected push-constant range (fragment Tint)")
    delete reflections

    var inscope vert <- create_shader_module(device, quad_vert_spv)
    var inscope frag <- create_shader_module(device, quad_frag_spv)
    var inscope pipeline <- create_graphics_pipeline_simple(device, render_pass, pipe_layout, vert, frag, TRI_W, TRI_H)

    let buf_size = uint64(TRI_W * TRI_H * 4)
    var inscope readback <- create_host_buffer(device, phys, buf_size)
    var inscope pool <- create_command_pool(device, pool_info(gfx))

    var tint = fixed_array(1.0f, 1.0f, 0.0f, 0.0f)   // zero blue -> white texel renders yellow

    run_cmd_sync(device, pool, queue) $(cmd) {
        let raw_cmd = boost_value_to_vk(cmd)
        var to_dst : VkAccessFlags
        to_dst.transfer_write = true
        var none : VkAccessFlags
        var top : VkPipelineStageFlags
        top.top_of_pipe = true
        var xfer : VkPipelineStageFlags
        xfer.transfer = true
        var frag_stage : VkPipelineStageFlags
        frag_stage.fragment_shader = true
        var to_read : VkAccessFlags
        to_read.shader_read = true
        transition_image(cmd, tex_image, VkImageLayout.UNDEFINED, VkImageLayout.TRANSFER_DST_OPTIMAL,
            none, to_dst, top, xfer)
        var region : BufferImageCopy
        region.imageSubresource.aspectMask.color = true
        region.imageSubresource.layerCount = 1u
        region.imageExtent.width = 2u
        region.imageExtent.height = 2u
        region.imageExtent.depth = 1u
        var regions : array<BufferImageCopy>
        regions |> emplace(region)
        cmd_copy_buffer_to_image(cmd, staging.buffer, tex_image, VkImageLayout.TRANSFER_DST_OPTIMAL, regions)
        transition_image(cmd, tex_image, VkImageLayout.TRANSFER_DST_OPTIMAL, VkImageLayout.SHADER_READ_ONLY_OPTIMAL,
            to_dst, to_read, xfer, frag_stage)
        record_render_pass(cmd, render_pass, framebuffer, full_area(TRI_W, TRI_H), clear_color(0.1f, 0.1f, 0.15f, 1.0f)) {
            cmd_bind_pipeline(cmd, pipeline)
            var sets : array<DescriptorSet>
            sets |> push(vk_value_to_boost(raw_set))
            var no_dyn : array<uint>
            cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.GRAPHICS, pipe_layout, 0u, sets, no_dyn)
            var pcf : VkShaderStageFlags
            pcf.fragment = true
            unsafe {
                vkCmdPushConstants(raw_cmd, boost_value_to_vk(pipe_layout), pcf, 0u, push_size, reinterpret<void?>(addr(tint[0])))
            }
            cmd_draw(cmd, 6u)
        }
        copy_image_to_buffer(cmd, target.image, readback, TRI_W, TRI_H)
    }
    map_memory_to_array(device, readback.memory, buf_size) $(m) {
        pixels := m
    }
    return <- pixels
}
