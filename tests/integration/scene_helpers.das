options gen2
options indenting = 4

// Shared offscreen scenes for the integration tests: render the triangle and
// run the compute square, returning the result data for assertions. No [test]
// functions here -- required by the test files.

module scene_helpers

require vulkan public
require vulkan/vulkan_boost public
require compute_shaders
require daslib/fio
require daslib/module_path

let TRI_W = 256
let TRI_H = 256

//! resolve a shader under the package's examples/shaders. The package may sit at
//! a daspkg modules/ path (CI) or be loaded directly (-load_module dev), so try
//! the source-relative path first, then a couple of cwd-relative candidates.
def private load_spirv(name : string) : array<uint8> {
    let here = dir_name(get_module_file_name("scene_helpers"))
    let candidates = [
        path_join(here, "../../examples/shaders/{name}"),
        "modules/dasVulkan/examples/shaders/{name}",
        "examples/shaders/{name}"
    ]
    var out : array<uint8>
    for (path in candidates) {
        let fs = stat(path)
        continue if (!fs.is_valid)
        fopen(path, "rb") $(f) {
            fload(f, int(fs.size)) $(data : array<uint8>) {
                out := data
            }
        }
        return <- out
    }
    panic("missing shader {name} (tried source-relative + modules/dasVulkan + cwd)")
    return <- out
}

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

    var vert_code <- load_spirv("triangle.vert.spv")
    var frag_code <- load_spirv("triangle.frag.spv")
    var inscope vert <- create_shader_module(device, vert_code)
    var inscope frag <- create_shader_module(device, frag_code)
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
