options gen2
options indenting = 4

// GPU gates for the dasSpirv compute-tier wave (daslang #3493 + #3494): subgroup reduce/shuffle
// correctness, specialization-constant overrides at pipeline creation (value + workgroup-x axis),
// and 8/16-bit SSBO storage (a block_q8_0-style f16-scale + int8-quant dequant against host-packed
// bytes). Each gate probes device support first and soft-skips (lavapipe / old drivers miss bits).

require dastest/testing_boost public
require scene_helpers
require spirv/spirv_shader
require spirv/spirv_builtins public
require math

// ===== shaders =====
var @ssbo @binding = 0 sgt_sum : array<float>
var @ssbo @binding = 1 sgt_size : array<uint>
var @ssbo @binding = 2 sgt_shf : array<uint>
var @ssbo @binding = 3 sgt_lane : array<uint>

[compute_shader(local_size_x=64, name="sgt_spv")]
def sgt_kernel {
    let gi = gl_GlobalInvocationID.x
    sgt_sum[gi] = subgroupAdd(1.0)
    sgt_size[gi] = gl_SubgroupSize
    sgt_shf[gi] = subgroupShuffleXor(gl_SubgroupInvocationID, 1u)
    sgt_lane[gi] = gl_SubgroupInvocationID
}

var @constant_id = 1 sct_scale : uint = 1u
var @ssbo @binding = 0 sct_y : array<uint>
var @ssbo @binding = 1 sct_local : array<uint>

[compute_shader(local_size_x=64, local_size_x_id=0, name="sct_spv")]
def sct_kernel {
    let gi = gl_GlobalInvocationID.x
    sct_y[gi] = gi * sct_scale
    sct_local[gi] = gl_LocalInvocationID.x
}

struct GBlockQ8 {
    d  : float16
    qs : int8[32]
}

var @ssbo @binding = 0 gq8_blocks : array<GBlockQ8>
var @ssbo @binding = 1 gq8_y : array<float>

[compute_shader(local_size_x=64, name="gq8_spv")]
def gq8_kernel {
    let b = gl_GlobalInvocationID.x
    var acc = 0.0
    var i = 0u
    while (i < 32u) {
        acc += float(int(gq8_blocks[b].qs[i]))
        i++
    }
    gq8_y[b] = acc * float(gq8_blocks[b].d)
}

// ===== a multi-SSBO compute runner =====
// One host-visible coherent STORAGE buffer per binding, contents uploaded from / read back into
// `bufs` (byte arrays; bufs[i] -> binding i). `spec` empty = the plain pipeline path;
// `storage_8_16` picks the feature-enabled device. Returns false when the DEVICE-side probe says
// the caller should have skipped (defensive; tests gate first).
def run_multi(var words : array<uint>; var bufs : array<array<uint8>>; groups : uint;
              spec : array<SpecConstantValue>; storage_8_16 : bool) {
    if (volkInitialize() != 0) {
        panic("no Vulkan loader")
    }
    let nb = length(bufs)
    var inscope instance <- create_instance("dasVulkan test", make_api_version(1u, 3u, 0u))
    volkLoadInstance(boost_value_to_vk(instance))
    let phys = select_physical_device(instance)
    let gfx = select_graphics_queue_family(phys)
    var inscope device <- (storage_8_16 ? create_device_storage_8_16(phys, gfx) : create_device(phys, gfx))
    volkLoadDevice(boost_value_to_vk(device))
    let dev = boost_value_to_vk(device)
    let queue = get_device_queue(device, gfx, 0u)

    var buffers : array<Buffer>
    var memories : array<DeviceMemory>
    buffers |> reserve(nb)
    memories |> reserve(nb)
    for (bi in range(nb)) {
        var bci : BufferCreateInfo
        bci.size = uint64(length(bufs[bi]))
        bci.usage.storage_buffer = true
        var buffer <- create_buffer(device, bci)
        var req : VkMemoryRequirements
        vkGetBufferMemoryRequirements(dev, boost_value_to_vk(buffer), req)
        var want : VkMemoryPropertyFlags
        want.host_visible = true
        want.host_coherent = true
        let mai = MemoryAllocateInfo(allocationSize = req.size,
            memoryTypeIndex = find_memory_type(phys, req.memoryTypeBits, want))
        var memory <- allocate_memory(device, mai)
        vk_check(vkBindBufferMemory(dev, boost_value_to_vk(buffer), boost_value_to_vk(memory), 0ul), null)
        var mapped : void? = null
        let mf : VkMemoryMapFlags
        unsafe {
            vk_check(vkMapMemory(dev, boost_value_to_vk(memory), 0ul, uint64(length(bufs[bi])), mf, addr(mapped)), null)
            memcpy(mapped, addr<void?>(bufs[bi][0]), length(bufs[bi]))
        }
        vkUnmapMemory(dev, boost_value_to_vk(memory))
        buffers |> emplace(buffer)
        memories |> emplace(memory)
    }

    var dslci : DescriptorSetLayoutCreateInfo
    dslci.pBindings |> reserve(nb)
    for (bi in range(nb)) {
        var b0 = DescriptorSetLayoutBinding(binding = uint(bi),
            descriptorType = VkDescriptorType.STORAGE_BUFFER, descriptorCount = 1u)
        b0.stageFlags.compute = true
        dslci.pBindings |> emplace(b0)
    }
    var inscope set_layout <- create_descriptor_set_layout(device, dslci)

    var dpci : DescriptorPoolCreateInfo
    dpci.maxSets = 1u
    var psize = DescriptorPoolSize(type_ = VkDescriptorType.STORAGE_BUFFER, descriptorCount = uint(nb))
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

    var writes : array<WriteDescriptorSet>
    writes |> reserve(nb)
    for (bi in range(nb)) {
        var write = WriteDescriptorSet(dstSet = vk_value_to_boost(raw_set), dstBinding = uint(bi),
            descriptorType = VkDescriptorType.STORAGE_BUFFER, descriptorCount = 1u)
        var binfo = DescriptorBufferInfo(buffer = weak_copy(buffers[bi]), range_ = uint64(length(bufs[bi])))
        write.pBufferInfo |> push(binfo)
        writes |> emplace(write)
    }
    let no_copies : array<CopyDescriptorSet>
    update_descriptor_sets(device, writes, no_copies)

    var inscope shader <- create_shader_module(device, words)
    var plci : PipelineLayoutCreateInfo
    plci.pSetLayouts <- [weak_copy(set_layout)]
    var inscope pipe_layout <- create_pipeline_layout(device, plci)
    var inscope pipeline <- (empty(spec) ? create_compute_pipeline(device, pipe_layout, shader)
                                         : create_compute_pipeline(device, pipe_layout, shader, spec))

    var cpci : CommandPoolCreateInfo
    cpci.queueFamilyIndex = gfx
    var inscope pool <- create_command_pool(device, cpci)
    run_cmd_sync(device, pool, queue) $(cmd) {
        cmd_bind_pipeline(cmd, pipeline, VkPipelineBindPoint.COMPUTE)
        unsafe {
            vkCmdBindDescriptorSets(boost_value_to_vk(cmd), VkPipelineBindPoint.COMPUTE, boost_value_to_vk(pipe_layout), 0u, 1u, addr(raw_set), 0u, null)
        }
        cmd_dispatch(cmd, groups, 1u, 1u)
    }

    for (bi in range(nb)) {
        var mapped : void? = null
        let mf : VkMemoryMapFlags
        unsafe {
            vk_check(vkMapMemory(dev, boost_value_to_vk(memories[bi]), 0ul, uint64(length(bufs[bi])), mf, addr(mapped)), null)
            memcpy(addr<void?>(bufs[bi][0]), mapped, length(bufs[bi]))
        }
        vkUnmapMemory(dev, boost_value_to_vk(memories[bi]))
    }
    delete buffers
    delete memories
}

// device-support probe with a throwaway instance (tests soft-skip on false)
def probe_support() : tuple<subgroups : bool; storage : bool> {
    if (volkInitialize() != 0) {
        return (subgroups = false, storage = false)
    }
    var inscope instance <- create_instance("dasVulkan probe", make_api_version(1u, 3u, 0u))
    volkLoadInstance(boost_value_to_vk(instance))
    let phys = select_physical_device(instance)
    return (subgroups = subgroup_compute_ops_supported(phys), storage = storage_8_16_supported(phys))
}

def u32_of(buf : array<uint8>; i : int) : uint {
    return (uint(buf[i * 4]) | (uint(buf[i * 4 + 1]) << 8u)
        | (uint(buf[i * 4 + 2]) << 16u) | (uint(buf[i * 4 + 3]) << 24u))
}

[test]
def test_subgroup_gpu(t : T?) {
    let sup = probe_support()
    if (!sup.subgroups) {
        feint("device lacks compute subgroup basic+arithmetic+shuffle+ballot; skipping\n")
        return
    }
    let n = 256
    var bufs : array<array<uint8>>
    bufs |> reserve(4)
    for (_bi in range(4)) {
        var b : array<uint8>
        b |> resize(n * 4)
        bufs |> emplace(b)
    }
    var words <- clone_to_move(sgt_spv)
    let no_spec : array<SpecConstantValue>
    run_multi(words, bufs, uint(n / 64), no_spec, false)
    var bad_sum = 0
    var bad_shf = 0
    for (i in range(n)) {
        let sz = u32_of(bufs[1], i)
        let active = min(sz, 64u)                    // wg=64: a subgroup wider than the wg runs partial
        let sum = unsafe(reinterpret<float>(u32_of(bufs[0], i)))
        if (sum != float(active)) {
            bad_sum++
        }
        let lane = u32_of(bufs[3], i)
        if (u32_of(bufs[2], i) != (lane ^ 1u)) {
            bad_shf++
        }
    }
    t |> success(bad_sum == 0, "subgroupAdd(1.0) == active lane count on every invocation ({bad_sum} wrong)")
    t |> success(bad_shf == 0, "subgroupShuffleXor(lane, 1) == lane^1 on every invocation ({bad_shf} wrong)")
    delete words
    delete bufs
}

[test]
def test_spec_constants_gpu(t : T?) {
    let n = 256
    // run 1: defaults (scale=1, wg-x=64)
    var bufs1 : array<array<uint8>>
    bufs1 |> reserve(2)
    for (_bi in range(2)) {
        var b : array<uint8>
        b |> resize(n * 4)
        bufs1 |> emplace(b)
    }
    var words <- clone_to_move(sct_spv)
    let no_spec : array<SpecConstantValue>
    run_multi(words, bufs1, uint(n / 64), no_spec, false)
    var ok1 = 0
    var max_local1 = 0u
    for (i in range(n)) {
        if (u32_of(bufs1[0], i) == uint(i)) {
            ok1++
        }
        max_local1 = max(max_local1, u32_of(bufs1[1], i))
    }
    t |> success(ok1 == n, "default pipeline: y[i] == i (scale default 1)")
    t |> equal(max_local1, 63u)
    // run 2: override wg-x (SpecId 0) to 32 and scale (SpecId 1) to 7 on the SAME shader module
    var bufs2 : array<array<uint8>>
    bufs2 |> reserve(2)
    for (_bi in range(2)) {
        var b : array<uint8>
        b |> resize(n * 4)
        bufs2 |> emplace(b)
    }
    var words2 <- clone_to_move(sct_spv)
    var spec <- [SpecConstantValue(id = 0u, value = 32u), SpecConstantValue(id = 1u, value = 7u)]
    run_multi(words2, bufs2, uint(n / 32), spec, false)
    var ok2 = 0
    var max_local2 = 0u
    for (i in range(n)) {
        if (u32_of(bufs2[0], i) == uint(i) * 7u) {
            ok2++
        }
        max_local2 = max(max_local2, u32_of(bufs2[1], i))
    }
    t |> success(ok2 == n, "specialized pipeline: y[i] == i*7 (SpecId 1 override applied)")
    t |> equal(max_local2, 31u)     // the WorkgroupSize builtin override actually resized the workgroup
    delete words
    delete words2
    delete bufs1
    delete bufs2
    delete spec
}

[test]
def test_storage_8_16_gpu(t : T?) {
    let sup = probe_support()
    if (!sup.storage) {
        feint("device lacks 8/16-bit SSBO storage features; skipping\n")
        return
    }
    let nblocks = 64
    // host-pack block_q8_0 bytes: float16 d at +0, int8 qs[32] at +2, stride 34 (std430)
    var blocks : array<uint8>
    blocks |> resize(nblocks * 34)
    var expected : array<float>
    expected |> resize(nblocks)
    for (b in range(nblocks)) {
        let scale = 0.5 * float(1 + (b % 3))                        // 0.5 / 1.0 / 1.5 -- f16-exact
        let dbits = packHalf2x16(float2(scale, 0.0)) & 0xFFFFu
        blocks[b * 34] = uint8(dbits & 0xFFu)
        blocks[b * 34 + 1] = uint8((dbits >> 8u) & 0xFFu)
        var qsum = 0
        for (k in range(32)) {
            let q = ((b * 7 + k * 3) % 31) - 15                     // -15..15 int8 pattern
            qsum += q
            blocks[b * 34 + 2 + k] = uint8(q & 0xFF)
        }
        expected[b] = float(qsum) * scale
    }
    var bufs : array<array<uint8>>
    bufs |> emplace(blocks)
    var yb : array<uint8>
    yb |> resize(nblocks * 4)
    bufs |> emplace(yb)
    var words <- clone_to_move(gq8_spv)
    let no_spec : array<SpecConstantValue>
    run_multi(words, bufs, uint(nblocks / 64), no_spec, true)
    var bad = 0
    for (b in range(nblocks)) {
        let got = unsafe(reinterpret<float>(u32_of(bufs[1], b)))
        if (got != expected[b]) {
            bad++
        }
    }
    t |> success(bad == 0, "GPU dequant of host-packed block_q8_0 bytes == CPU ({bad} of {nblocks} wrong)")
    delete words
    delete bufs
    delete expected
}
