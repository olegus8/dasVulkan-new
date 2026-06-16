options gen2
options indenting = 4

// Shared setup for both Mandelbrot viewers: create an Rgba8 storage image, run the compute shader once
// into it, and hand back the GPU-resident result. This is the part the blit viewer and the sampled
// viewer have in common; each then differs only in how it gets the image onto the swapchain. It mirrors
// vulkan_boost's compute_to_storage_image but keeps the image RESIDENT (no readback / teardown) so the
// window can present it every frame. Kept tutorial-local; promote to the library if a later compute
// tutorial needs it too.

module mandelbrot_compute

require vulkan public
require vulkan/vulkan_boost public

//! a compute result living on the GPU: the image + its backing memory + a view, owned together.
struct public ComputeImage {
    image : Image
    memory : DeviceMemory
    view : ImageView
    width : int
    height : int
}

def public finalize(var ci : ComputeImage) {
    delete ci.view
    delete ci.image
    delete ci.memory
}

//! Create an Rgba8 storage image and run `words` (a dasSpirv compute blob binding a storage image2D at
//! set=0/binding=0) once over w/8 x h/8, returning the GPU-resident result in the GENERAL layout. The
//! image carries STORAGE (the compute write) + TRANSFER_SRC (the blit path) + SAMPLED (the texture path),
//! so either viewer can consume it. The descriptor set, pipeline and command pool are local; only the
//! image + memory + view persist in the returned bundle. w and h must be positive multiples of 8.
def public run_mandelbrot_compute(device : Device; phys : VkPhysicalDevice; queue : VkQueue;
        queue_family : uint; var words : array<uint>; w, h : int) : ComputeImage {
    assert(w > 0 && h > 0 && (w % 8) == 0 && (h % 8) == 0,
        "run_mandelbrot_compute: w/h must be positive multiples of 8")
    let dev = boost_value_to_vk(device)
    let fmt = VkFormat.R8G8B8A8_UNORM

    // the storage image: STORAGE for the compute write, TRANSFER_SRC for the blit, SAMPLED for the texture
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
    ici.usage.sampled = true
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

    // descriptor set: binding 0 = STORAGE_IMAGE, compute stage
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

    // bind the storage-image view (layout GENERAL, no sampler)
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

    var poolci : CommandPoolCreateInfo
    poolci.queueFamilyIndex = queue_family
    var inscope pool <- create_command_pool(device, poolci)

    // UNDEFINED -> GENERAL, dispatch one invocation per pixel; leave the result in GENERAL
    run_cmd_sync(device, pool, queue) $(cmd) {
        var none : VkAccessFlags
        var shader_write : VkAccessFlags
        shader_write.shader_write = true
        var top : VkPipelineStageFlags
        top.top_of_pipe = true
        var comp : VkPipelineStageFlags
        comp.compute_shader = true
        transition_image(cmd, image, VkImageLayout.UNDEFINED, VkImageLayout.GENERAL,
            none, shader_write, top, comp)
        cmd_bind_pipeline(cmd, pipeline, VkPipelineBindPoint.COMPUTE)
        var sets : array<DescriptorSet>
        sets |> push(vk_value_to_boost(raw_set))
        var no_dyn : array<uint>
        cmd_bind_descriptor_sets(cmd, VkPipelineBindPoint.COMPUTE, pipe_layout, 0u, sets, no_dyn)
        cmd_dispatch(cmd, uint(w / 8), uint(h / 8), 1u)
    }

    var ci : ComputeImage
    ci.image <- image
    ci.memory <- imem
    ci.view <- view
    ci.width = w
    ci.height = h
    return <- ci
}
