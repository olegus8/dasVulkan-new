options gen2
options indenting = 4

// Hand-written ergonomic top of the boost: selection helpers, block brackets,
// combined builders, and the composite creators whose CreateInfo the generator
// skips (instance/device/render-pass/shader-module/pipeline). Re-exports the
// generated boost so users `require vulkan/vulkan_boost` and get everything.

module vulkan_boost shared

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

//! is `name` advertised among `phys`'s available device extensions? Use this to gate an optional
//! device extension before enabling it (e.g. skip a VK_EXT_mesh_shader test on a driver -- such as an
//! older Mesa lavapipe -- that does not advertise it, rather than crashing vkCreateDevice).
def public device_extension_available(phys : VkPhysicalDevice; name : string) : bool {
    var count = 0u
    if (vkEnumerateDeviceExtensionProperties(phys, "", count, null) != VkResult.SUCCESS || count == 0u) {
        return false
    }
    var props : array<VkExtensionProperties>
    props |> resize(int(count))
    let rc = vkEnumerateDeviceExtensionProperties(phys, "", count, unsafe(addr(props[0])))
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

//! True iff ``phys`` both advertises ``VK_EXT_mesh_shader`` AND reports the ``meshShader`` and
//! ``taskShader`` feature bits as supported (queried via ``vkGetPhysicalDeviceFeatures2``). The
//! extension string alone is not sufficient: a driver can list the extension yet report a feature
//! bit as 0, which would still fail ``vkCreateDevice``. Use this to gate mesh-pipeline setup.
def public mesh_shader_supported(phys : VkPhysicalDevice) : bool {
    if (!device_extension_available(phys, "VK_EXT_mesh_shader")) {
        return false
    }
    var mf = VkPhysicalDeviceMeshShaderFeaturesEXT()   // sType pre-filled by the ctor
    var f2 = VkPhysicalDeviceFeatures2()
    unsafe {
        f2.pNext = reinterpret<void?>(addr(mf))
    }
    vkGetPhysicalDeviceFeatures2(phys, f2)
    return mf.meshShader != 0u && mf.taskShader != 0u
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

//! Create a device with Vulkan 1.3 features (e.g. ``dynamicRendering``, ``synchronization2``).
//! Vulkan 1.3 promoted KHR_dynamic_rendering and KHR_synchronization2 to core, but the device
//! still has to *opt in* via ``VkPhysicalDeviceVulkan13Features`` -- the 1.3 API doesn't enable
//! anything automatically. Caller sets the needed flags (e.g. ``f13.dynamicRendering = 1u``),
//! this helper threads the struct in via the pNext chain of ``VkDeviceCreateInfo``. The instance
//! must be at api version 1.3; otherwise ``vkCreateDevice`` rejects the chain with
//! ``ERROR_FEATURE_NOT_PRESENT``.
def public create_device(phys : VkPhysicalDevice; queue_family : uint; extensions : array<string>;
                         var features13 : VkPhysicalDeviceVulkan13Features) : Device {
    var prio = 1.0f
    var qci = VkDeviceQueueCreateInfo()
    qci.queueFamilyIndex = queue_family
    qci.queueCount = 1u
    unsafe {
        qci.pQueuePriorities = addr(prio)
    }
    features13.sType = VkStructureType.PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
    var ci = VkDeviceCreateInfo()
    ci.queueCreateInfoCount = 1u
    unsafe {
        ci.pQueueCreateInfos = addr(qci)
        ci.pNext = reinterpret<void?>(addr(features13))
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

//! Create a device with Vulkan 1.2 features (e.g. ``descriptorIndexing``,
//! ``shaderSampledImageArrayNonUniformIndexing``, ``runtimeDescriptorArray``). VK_EXT_descriptor_indexing
//! was promoted to core in 1.2, so a 1.2+ instance can opt into bindless via this struct in the pNext
//! chain of ``VkDeviceCreateInfo``; no extension string is required. The instance must be at api
//! version 1.2 (or higher); otherwise ``vkCreateDevice`` rejects the chain with
//! ``VK_ERROR_FEATURE_NOT_PRESENT``. Caller sets the needed flags; this helper threads the struct in.
def public create_device(phys : VkPhysicalDevice; queue_family : uint; extensions : array<string>;
                         var features12 : VkPhysicalDeviceVulkan12Features) : Device {
    var prio = 1.0f
    var qci = VkDeviceQueueCreateInfo()
    qci.queueFamilyIndex = queue_family
    qci.queueCount = 1u
    unsafe {
        qci.pQueuePriorities = addr(prio)
    }
    features12.sType = VkStructureType.PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
    var ci = VkDeviceCreateInfo()
    ci.queueCreateInfoCount = 1u
    unsafe {
        ci.pQueueCreateInfos = addr(qci)
        ci.pNext = reinterpret<void?>(addr(features12))
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

//! Create a device with the bindless feature set enabled: ``descriptorIndexing`` (the umbrella flag)
//! plus ``shaderSampledImageArrayNonUniformIndexing`` (so a fragment can index a ``sampler2D[N]`` by
//! a per-invocation value with ``nonuniformEXT``). Uses the Vulkan 1.2-core
//! `VkPhysicalDeviceVulkan12Features` path — no `VK_EXT_descriptor_indexing` extension string
//! required on a 1.2+ instance. Pairs with the dasSpirv bindless track (PR-B `nonuniformEXT`, PR-C
//! `sampler2D[N]`); the GPU regression tests under `tests/integration/test_bindless_*.das` and
//! `test_nonuniform_ext.das` use this entry point. **`runtimeDescriptorArray` is deliberately NOT
//! enabled** — runtime-sized descriptor arrays (`sampler2D[]`) are a follow-up scope; enable it
//! explicitly via the `create_device` features12 overload when that lands.
def public create_device_descriptor_indexing(phys : VkPhysicalDevice; queue_family : uint) : Device {
    let no_ext : array<string>
    var f12 : VkPhysicalDeviceVulkan12Features
    f12.descriptorIndexing = 1u
    f12.shaderSampledImageArrayNonUniformIndexing = 1u
    return <- create_device(phys, queue_family, no_ext, f12)
}

//! Create a device with the GPU-driven-rendering feature set enabled: ``multiDrawIndirect`` (so
//! ``vkCmdDrawIndirect`` can dispatch more than one draw in a single command) and
//! ``shaderDrawParameters`` (so a vertex shader can read ``gl_DrawID`` -- BuiltIn DrawIndex -- to
//! key per-draw state). multiDrawIndirect rides on the base ``VkPhysicalDeviceFeatures``;
//! shaderDrawParameters was promoted to Vulkan 1.1 core via VkPhysicalDeviceVulkan11Features, so a
//! 1.1+ instance can opt into it without an extension string. Both are threaded into pNext
//! together. Pairs with the dasSpirv PR-A `gl_DrawID` surface; used by
//! `tests/integration/test_gl_draw_id.das`.
def public create_device_draw_parameters(phys : VkPhysicalDevice; queue_family : uint) : Device {
    var prio = 1.0f
    var qci = VkDeviceQueueCreateInfo()
    qci.queueFamilyIndex = queue_family
    qci.queueCount = 1u
    unsafe {
        qci.pQueuePriorities = addr(prio)
    }
    var base : VkPhysicalDeviceFeatures
    base.multiDrawIndirect = 1u
    var f11 : VkPhysicalDeviceVulkan11Features
    f11.sType = VkStructureType.PHYSICAL_DEVICE_VULKAN_1_1_FEATURES
    f11.shaderDrawParameters = 1u
    var ci = VkDeviceCreateInfo()
    ci.queueCreateInfoCount = 1u
    unsafe {
        ci.pQueueCreateInfos = addr(qci)
        ci.pEnabledFeatures = addr(base)
        ci.pNext = reinterpret<void?>(addr(f11))
    }
    var h : VkDevice
    vk_check(vkCreateDevice(phys, ci, null, h), null)
    var b = vk_value_to_boost(h)
    b._needs_delete = true
    return <- b
}

//! Create a device with ``VK_EXT_mesh_shader`` enabled. Caller sets the wanted feature flags (e.g.
//! ``mf.meshShader = 1u``, ``mf.taskShader = 1u``); this helper threads
//! ``VkPhysicalDeviceMeshShaderFeaturesEXT`` into the ``VkDeviceCreateInfo`` pNext chain. The caller
//! MUST also pass the ``"VK_EXT_mesh_shader"`` device-extension string in ``extensions`` (the feature
//! flags alone are not enough). Mesh/task shaders execute SPIR-V 1.4, which is core in Vulkan 1.2, so
//! the instance must be at api version >= 1.2. Pairs with the dasSpirv mesh emitter and
//! ``cmd_draw_mesh_tasks_e_x_t``. Verify the device advertises the features via a
//! ``VkPhysicalDeviceMeshShaderFeaturesEXT`` queried through ``VkPhysicalDeviceFeatures2`` before
//! enabling them; an unsupported flag fails ``vkCreateDevice``.
def public create_device(phys : VkPhysicalDevice; queue_family : uint; extensions : array<string>;
                         var meshFeatures : VkPhysicalDeviceMeshShaderFeaturesEXT) : Device {
    var prio = 1.0f
    var qci = VkDeviceQueueCreateInfo()
    qci.queueFamilyIndex = queue_family
    qci.queueCount = 1u
    unsafe {
        qci.pQueuePriorities = addr(prio)
    }
    meshFeatures.sType = VkStructureType.PHYSICAL_DEVICE_MESH_SHADER_FEATURES_EXT
    var ci = VkDeviceCreateInfo()
    ci.queueCreateInfoCount = 1u
    unsafe {
        ci.pQueueCreateInfos = addr(qci)
        ci.pNext = reinterpret<void?>(addr(meshFeatures))
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

//! Create a device with the mesh-shader pipeline enabled: ``meshShader`` + ``taskShader`` features plus
//! the ``VK_EXT_mesh_shader`` device-extension string, in one call. This is the entry point Tutorial 13
//! and its pixel-oracle (``tutorials/13_mesh/test_mesh.das``) use. The instance must be at api version >= 1.2 (SPIR-V 1.4).
def public create_device_mesh_shader(phys : VkPhysicalDevice; queue_family : uint) : Device {
    if (!mesh_shader_supported(phys)) {
        panic("create_device_mesh_shader: device does not support the VK_EXT_mesh_shader meshShader+taskShader features")
    }
    var mf : VkPhysicalDeviceMeshShaderFeaturesEXT
    mf.meshShader = 1u
    mf.taskShader = 1u
    return <- create_device(phys, queue_family, ["VK_EXT_mesh_shader"], mf)
}

//! True iff ``phys`` advertises the three device extensions hardware ray tracing needs
//! (``VK_KHR_acceleration_structure``, ``VK_KHR_ray_tracing_pipeline``,
//! ``VK_KHR_deferred_host_operations``) AND reports the ``accelerationStructure``,
//! ``rayTracingPipeline`` and ``bufferDeviceAddress`` feature bits as supported. The extension
//! strings alone are not sufficient: a driver can list an extension yet report its feature bit
//! as 0, which still fails ``vkCreateDevice``. Use this to gate RT setup — CI software renderers
//! (Mesa lavapipe) typically fail this probe, so RT tests soft-skip there.
def public rt_supported(phys : VkPhysicalDevice) : bool {
    if (!device_extension_available(phys, "VK_KHR_acceleration_structure") ||
            !device_extension_available(phys, "VK_KHR_ray_tracing_pipeline") ||
            !device_extension_available(phys, "VK_KHR_deferred_host_operations")) {
        return false
    }
    var f12 = VkPhysicalDeviceVulkan12Features()
    var asf = VkPhysicalDeviceAccelerationStructureFeaturesKHR()
    var rtf = VkPhysicalDeviceRayTracingPipelineFeaturesKHR()
    var f2 = VkPhysicalDeviceFeatures2()
    unsafe {
        f2.pNext = reinterpret<void?>(addr(f12))
        f12.pNext = reinterpret<void?>(addr(asf))
        asf.pNext = reinterpret<void?>(addr(rtf))
    }
    vkGetPhysicalDeviceFeatures2(phys, f2)
    return f12.bufferDeviceAddress != 0u && asf.accelerationStructure != 0u && rtf.rayTracingPipeline != 0u
}

//! Create a device with the hardware ray-tracing stack enabled in one call: ``bufferDeviceAddress``
//! (Vulkan 1.2 core), ``accelerationStructure`` and ``rayTracingPipeline`` features threaded through
//! the pNext chain, plus the three device-extension strings. The instance must be at api version
//! >= 1.2 (RT shaders are SPIR-V 1.4). Pairs with the [vulkan_raygen_shader] /
//! [vulkan_miss_shader] / [vulkan_closest_hit_shader] annotations, build_blas / build_tlas,
//! build_shader_binding_table, and cmd_trace_rays_k_h_r. Gate with rt_supported first.
def public create_device_ray_tracing(phys : VkPhysicalDevice; queue_family : uint) : Device {
    let no_extra : array<string>
    return <- create_device_ray_tracing(phys, queue_family, no_extra)
}

//! create_device_ray_tracing with additional device extensions on top of the RT set (a windowed
//! RT app passes ``["VK_KHR_swapchain"]``).
def public create_device_ray_tracing(phys : VkPhysicalDevice; queue_family : uint; extra_extensions : array<string>) : Device {
    if (!rt_supported(phys)) {
        panic("create_device_ray_tracing: device does not support VK_KHR_ray_tracing_pipeline + VK_KHR_acceleration_structure + bufferDeviceAddress")
    }
    var prio = 1.0f
    var qci = VkDeviceQueueCreateInfo()
    qci.queueFamilyIndex = queue_family
    qci.queueCount = 1u
    var f12 = VkPhysicalDeviceVulkan12Features()
    f12.bufferDeviceAddress = 1u
    var asf = VkPhysicalDeviceAccelerationStructureFeaturesKHR()
    asf.accelerationStructure = 1u
    var rtf = VkPhysicalDeviceRayTracingPipelineFeaturesKHR()
    rtf.rayTracingPipeline = 1u
    var extensions <- ["VK_KHR_acceleration_structure", "VK_KHR_ray_tracing_pipeline", "VK_KHR_deferred_host_operations"]
    extensions |> push_from(extra_extensions)
    var ci = VkDeviceCreateInfo()
    ci.queueCreateInfoCount = 1u
    ci.enabledExtensionCount = uint(length(extensions))
    unsafe {
        qci.pQueuePriorities = addr(prio)
        ci.pQueueCreateInfos = addr(qci)
        ci.pNext = reinterpret<void?>(addr(f12))
        f12.pNext = reinterpret<void?>(addr(asf))
        asf.pNext = reinterpret<void?>(addr(rtf))
        ci.ppEnabledExtensionNames = reinterpret<void?>(addr(extensions[0]))
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
    let ci = VkPipelineLayoutCreateInfo()
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

//! Graphics pipeline for the VK_EXT_mesh_shader pipeline: a task -> mesh -> fragment stage chain with
//! NO vertex input and NO input-assembly state (a mesh pipeline amplifies geometry on the GPU; those
//! two states are ignored, so they are left null). Everything else — viewport, rasterizer, MSAA-off,
//! opaque color blend — matches `create_graphics_pipeline_simple`. The device must have been created
//! with `create_device_mesh_shader` (or equivalent) and the shaders authored with `[vulkan_task_shader]`
//! / `[vulkan_mesh_shader]` / `[vulkan_fragment_shader]`. Draw with `cmd_draw_mesh_tasks_e_x_t`.
def public create_mesh_pipeline(device : Device; render_pass : RenderPass; layout : PipelineLayout;
                                task : ShaderModule; mesh : ShaderModule; frag : ShaderModule;
                                width, height : int; dynamic_viewport : bool = false;
                                enable_depth : bool = false) : Pipeline {
    var stages : array<VkPipelineShaderStageCreateInfo>
    stages |> resize(3)
    stages[0] = VkPipelineShaderStageCreateInfo()
    stages[0].stage.task_ext = true
    stages[0].module_ = boost_value_to_vk(task)
    stages[0].pName = "main"
    stages[1] = VkPipelineShaderStageCreateInfo()
    stages[1].stage.mesh_ext = true
    stages[1].module_ = boost_value_to_vk(mesh)
    stages[1].pName = "main"
    stages[2] = VkPipelineShaderStageCreateInfo()
    stages[2].stage.fragment = true
    stages[2].module_ = boost_value_to_vk(frag)
    stages[2].pName = "main"

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

    // depth test + write (LESS_OR_EQUAL) when the render pass carries a depth attachment; left off
    // (pDepthStencilState null) by default so the depthless Tutorial 13 path is unchanged.
    var depthstate = VkPipelineDepthStencilStateCreateInfo()
    if (enable_depth) {
        depthstate.depthTestEnable = VK_TRUE
        depthstate.depthWriteEnable = VK_TRUE
        depthstate.depthCompareOp = VkCompareOp.LESS_OR_EQUAL
        depthstate.maxDepthBounds = 1.0f
    }

    var dyn_states : array<VkDynamicState>
    var dynstate = VkPipelineDynamicStateCreateInfo()
    if (dynamic_viewport) {
        dyn_states |> push(VkDynamicState.VIEWPORT)
        dyn_states |> push(VkDynamicState.SCISSOR)
        dynstate.dynamicStateCount = uint(length(dyn_states))
    }

    var gp = VkGraphicsPipelineCreateInfo()
    gp.stageCount = 3u
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
        // NB: pVertexInputState + pInputAssemblyState deliberately left null — ignored for mesh pipelines.
        gp.pViewportState = addr(vpstate)
        gp.pRasterizationState = addr(raster)
        gp.pMultisampleState = addr(msaa)
        if (enable_depth) {
            gp.pDepthStencilState = addr(depthstate)
        }
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

//! `create_graphics_pipeline_v3d` parallel for the dynamic-rendering path (Vulkan 1.3 core).
//! No `RenderPass` -- instead the pipeline carries a `VkPipelineRenderingCreateInfo` in its
//! pNext chain with the color/depth format and view mask. `samples` flows into both the
//! multisample state and the rendering create info (the spec doesn't require it in the rendering
//! info, but matching it makes the layout self-documenting). Tutorial 09 uses this with 4x MSAA;
//! tutorial 10 will reuse it with `samples._1 = true` + multiple color formats.
def public create_graphics_pipeline_dyn(device : Device;
                                        color_format, depth_format : VkFormat;
                                        samples : VkSampleCountFlags;
                                        layout : PipelineLayout;
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
    msaa.rasterizationSamples = samples

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

    // dynamic-rendering pipeline carries the color/depth formats in a VkPipelineRenderingCreateInfo
    // attached via pNext (instead of a VkRenderPass handle). We allocate the color format slot
    // separately so addr() is valid through the call.
    var dyn_render = VkPipelineRenderingCreateInfo()
    var cf = color_format
    dyn_render.depthAttachmentFormat = depth_format
    dyn_render.colorAttachmentCount = 1u

    var gp = VkGraphicsPipelineCreateInfo()
    gp.stageCount = 2u
    gp.layout = boost_value_to_vk(layout)
    // no render_pass on the dynamic-rendering path; pNext carries the format info instead
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
        dyn_render.pColorAttachmentFormats = addr(cf)
        gp.pNext = reinterpret<void?>(addr(dyn_render))
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
    var barrier = ImageMemoryBarrier(srcAccessMask = src_access, dstAccessMask = dst_access,
        oldLayout = old_layout, newLayout = new_layout, srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, image = weak_copy(image))
    barrier.subresourceRange.aspectMask.color = true
    barrier.subresourceRange.levelCount = 1u
    barrier.subresourceRange.layerCount = 1u
    let no_mem : array<MemoryBarrier>
    let no_buf : array<BufferMemoryBarrier>
    var imgs : array<ImageMemoryBarrier>
    imgs |> emplace(barrier)
    let no_dep : VkDependencyFlags
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
    var barrier = ImageMemoryBarrier(srcAccessMask = src_access, dstAccessMask = dst_access,
        oldLayout = old_layout, newLayout = new_layout, srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, image = weak_copy(image))
    barrier.subresourceRange.aspectMask = aspect
    barrier.subresourceRange.levelCount = 1u
    barrier.subresourceRange.layerCount = 1u
    let no_mem : array<MemoryBarrier>
    let no_buf : array<BufferMemoryBarrier>
    var imgs : array<ImageMemoryBarrier>
    imgs |> emplace(barrier)
    let no_dep : VkDependencyFlags
    cmd_pipeline_barrier(cmd, src_stage, dst_stage, no_dep, no_mem, no_buf, imgs)
}

//! Run a compute shader that writes an Rgba8 storage image and return the w*h RGBA8 pixels. `words` is
//! an emitted SPIR-V compute blob whose entry point binds a storage image2D at set=0/binding=0 and
//! `imageStore`s a color per invocation over an 8x8 local size. A one-shot: it creates its own
//! instance/device, the storage image, the descriptor set, the compute pipeline and a command pool,
//! dispatches w/8 x h/8, and reads the image back. w and h must be positive multiples of 8 so the
//! dispatch covers every pixel (asserted). For the canonical authoring side see dasSpirv's image2D +
//! imageStore (e.g. dasVulkan's storage-image tests and the Mandelbrot tutorial).
//! When `srgb_encode` is true the linear storage image is blitted into an R8G8B8A8_SRGB intermediate
//! before readback, so the hardware applies the linear->sRGB gamma encode at the blit and the returned
//! bytes are display-ready (storage images do NOT sRGB-encode on write). Default false: copy as-is.
def public compute_to_storage_image(var words : array<uint>; w, h : int; srgb_encode : bool = false) : array<uint8> {
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
    var ici = ImageCreateInfo(imageType = VkImageType._2D, format = fmt, mipLevels = 1u, arrayLayers = 1u,
        tiling = VkImageTiling.OPTIMAL, initialLayout = VkImageLayout.UNDEFINED)
    ici.extent.width = uint(w)
    ici.extent.height = uint(h)
    ici.extent.depth = 1u
    ici.samples._1 = true
    ici.usage.storage = true
    ici.usage.transfer_src = true
    var inscope image <- create_image(device, ici)
    var ireq : VkMemoryRequirements
    vkGetImageMemoryRequirements(dev, boost_value_to_vk(image), ireq)
    var iwant : VkMemoryPropertyFlags
    iwant.device_local = true
    let imai = MemoryAllocateInfo(allocationSize = ireq.size,
        memoryTypeIndex = find_memory_type(phys, ireq.memoryTypeBits, iwant))
    var inscope imem <- allocate_memory(device, imai)
    vk_check(vkBindImageMemory(dev, boost_value_to_vk(image), boost_value_to_vk(imem), 0ul), null)
    var vci = ImageViewCreateInfo(image = weak_copy(image), viewType = VkImageViewType._2D, format = fmt)
    vci.subresourceRange.aspectMask.color = true
    vci.subresourceRange.levelCount = 1u
    vci.subresourceRange.layerCount = 1u
    var inscope view <- create_image_view(device, vci)

    // optional sRGB readback intermediate: when srgb_encode, the linear storage image is blitted into
    // this R8G8B8A8_SRGB image (hardware applies linear->sRGB at the blit) and THAT is read back. No
    // storage usage -- storage images don't sRGB-encode on write; TRANSFER_DST (blit target) + TRANSFER_SRC.
    let srgb_fmt = VkFormat.R8G8B8A8_SRGB
    var inscope srgb_image : Image
    var inscope srgb_mem : DeviceMemory
    if (srgb_encode) {
        var sici = ImageCreateInfo(imageType = VkImageType._2D, format = srgb_fmt, mipLevels = 1u, arrayLayers = 1u,
            tiling = VkImageTiling.OPTIMAL, initialLayout = VkImageLayout.UNDEFINED)
        sici.extent.width = uint(w)
        sici.extent.height = uint(h)
        sici.extent.depth = 1u
        sici.samples._1 = true
        sici.usage.transfer_dst = true
        sici.usage.transfer_src = true
        srgb_image <- create_image(device, sici)
        var sreq : VkMemoryRequirements
        vkGetImageMemoryRequirements(dev, boost_value_to_vk(srgb_image), sreq)
        var swant : VkMemoryPropertyFlags
        swant.device_local = true
        let smai = MemoryAllocateInfo(allocationSize = sreq.size,
            memoryTypeIndex = find_memory_type(phys, sreq.memoryTypeBits, swant))
        srgb_mem <- allocate_memory(device, smai)
        vk_check(vkBindImageMemory(dev, boost_value_to_vk(srgb_image), boost_value_to_vk(srgb_mem), 0ul), null)
    }

    // descriptor set layout + pool: binding 0 = STORAGE_IMAGE, compute
    var dslci : DescriptorSetLayoutCreateInfo
    var b0 = DescriptorSetLayoutBinding(binding = 0u, descriptorType = VkDescriptorType.STORAGE_IMAGE, descriptorCount = 1u)
    b0.stageFlags.compute = true
    dslci.pBindings |> emplace(b0)
    var inscope set_layout <- create_descriptor_set_layout(device, dslci)

    var dpci : DescriptorPoolCreateInfo
    dpci.maxSets = 1u
    let psize = DescriptorPoolSize(type_ = VkDescriptorType.STORAGE_IMAGE, descriptorCount = 1u)
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
    var write = WriteDescriptorSet(dstSet = vk_value_to_boost(raw_set), dstBinding = 0u,
        descriptorType = VkDescriptorType.STORAGE_IMAGE, descriptorCount = 1u)
    let iinfo = DescriptorImageInfo(imageView = weak_copy(view), imageLayout = VkImageLayout.GENERAL)
    write.pImageInfo |> push(iinfo)
    var writes : array<WriteDescriptorSet>
    writes |> emplace(write)
    let no_copies : array<CopyDescriptorSet>
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
        let none : VkAccessFlags
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
        if (srgb_encode) {
            // blit the linear UNORM storage image into the sRGB intermediate (hardware applies the
            // linear->sRGB encode at the format conversion), then read THAT back gamma-encoded.
            var transfer_write : VkAccessFlags
            transfer_write.transfer_write = true
            transition_image(cmd, srgb_image, VkImageLayout.UNDEFINED, VkImageLayout.TRANSFER_DST_OPTIMAL,
                none, transfer_write, top, xfer)
            var region : VkImageBlit
            region.srcSubresource.aspectMask.color = true
            region.srcSubresource.layerCount = 1u
            region.srcOffsets[1].x = w
            region.srcOffsets[1].y = h
            region.srcOffsets[1].z = 1
            region.dstSubresource.aspectMask.color = true
            region.dstSubresource.layerCount = 1u
            region.dstOffsets[1].x = w
            region.dstOffsets[1].y = h
            region.dstOffsets[1].z = 1
            unsafe {
                vkCmdBlitImage(boost_value_to_vk(cmd),
                    boost_value_to_vk(image),      VkImageLayout.TRANSFER_SRC_OPTIMAL,
                    boost_value_to_vk(srgb_image), VkImageLayout.TRANSFER_DST_OPTIMAL,
                    1u, addr(region), VkFilter.NEAREST)
            }
            transition_image(cmd, srgb_image, VkImageLayout.TRANSFER_DST_OPTIMAL, VkImageLayout.TRANSFER_SRC_OPTIMAL,
                transfer_write, to_read, xfer, xfer)
            copy_image_to_buffer(cmd, srgb_image, readback, w, h)
        } else {
            copy_image_to_buffer(cmd, image, readback, w, h)
        }
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
    var samples : VkSampleCountFlags
    samples._1 = true
    var extra : VkImageUsageFlags
    extra.transfer_src = true                   // base helper default: blittable to host readback
    return <- build_offscreen_target(device, phys, width, height, format, samples, extra)
}

//! `build_offscreen_target` overload taking caller-supplied sample count + extra usage flags.
//! `color_attachment` is always set; `extra_usage` adds the rest -- `transfer_src` for the
//! offscreen-readback default, `input_attachment` for subpass-input rails (tutorial 10),
//! `sampled` for post-processing chains (tutorial 11), `_4`/`_8` on `samples` for MSAA
//! (tutorial 09). MSAA images CANNOT carry `transfer_src` -- the resolve target does.
def public build_offscreen_target(device : Device; phys : VkPhysicalDevice; width, height : int;
                                  format : VkFormat; samples : VkSampleCountFlags;
                                  extra_usage : VkImageUsageFlags) : OffscreenTarget {
    var ici = ImageCreateInfo(imageType = VkImageType._2D, format = format, mipLevels = 1u, arrayLayers = 1u,
        samples = samples, tiling = VkImageTiling.OPTIMAL, initialLayout = VkImageLayout.UNDEFINED)
    ici.extent.width = uint(width)
    ici.extent.height = uint(height)
    ici.extent.depth = 1u
    ici.usage = extra_usage
    ici.usage.color_attachment = true
    var inscope image <- create_image(device, ici)

    var req : VkMemoryRequirements
    vkGetImageMemoryRequirements(boost_value_to_vk(device), boost_value_to_vk(image), req)
    var want : VkMemoryPropertyFlags
    want.device_local = true
    let mai = MemoryAllocateInfo(allocationSize = req.size,
        memoryTypeIndex = find_memory_type(phys, req.memoryTypeBits, want))
    var inscope memory <- allocate_memory(device, mai)
    vk_check(vkBindImageMemory(boost_value_to_vk(device), boost_value_to_vk(image), boost_value_to_vk(memory), 0ul), null)

    var vci = ImageViewCreateInfo(image = weak_copy(image), viewType = VkImageViewType._2D, format = format)
    vci.subresourceRange.aspectMask.color = true
    vci.subresourceRange.levelCount = 1u
    vci.subresourceRange.layerCount = 1u
    var inscope view <- create_image_view(device, vci)

    var t = OffscreenTarget(image <- image, memory <- memory, view <- view)
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
    let extra : VkImageUsageFlags  // default: empty
    return <- build_offscreen_depth(device, phys, width, height, format, extra)
}

//! `build_offscreen_depth` overload taking caller-supplied extra usage flags. The base helper
//! always sets `depth_stencil_attachment`; this overload adds whatever else the caller needs —
//! `sampled` for shadow maps (the image is read by a `sampler2DShadow` in the next pass),
//! `transfer_src` for offscreen-depth readback, etc. Memory + view stay device-local D32_SFLOAT.
def public build_offscreen_depth(device : Device; phys : VkPhysicalDevice; width, height : int;
                                 format : VkFormat; extra_usage : VkImageUsageFlags) : OffscreenDepth {
    var samples : VkSampleCountFlags
    samples._1 = true
    return <- build_offscreen_depth(device, phys, width, height, format, extra_usage, samples)
}

//! `build_offscreen_depth` overload taking caller-supplied sample count. Use this for MSAA depth
//! attachments (tutorial 09): the color and depth attachments in one render pass must agree on
//! `samples`, so a 4x color target needs a 4x depth target. The caller passes both `extra_usage`
//! and `samples` -- samples-only callers go through the 5-arg overload with default empty extras.
def public build_offscreen_depth(device : Device; phys : VkPhysicalDevice; width, height : int;
                                 format : VkFormat; extra_usage : VkImageUsageFlags;
                                 samples : VkSampleCountFlags) : OffscreenDepth {
    var ici = ImageCreateInfo(imageType = VkImageType._2D, format = format, mipLevels = 1u, arrayLayers = 1u,
        samples = samples, tiling = VkImageTiling.OPTIMAL, initialLayout = VkImageLayout.UNDEFINED)
    ici.extent.width = uint(width)
    ici.extent.height = uint(height)
    ici.extent.depth = 1u
    ici.usage = extra_usage
    ici.usage.depth_stencil_attachment = true
    var inscope image <- create_image(device, ici)

    var req : VkMemoryRequirements
    vkGetImageMemoryRequirements(boost_value_to_vk(device), boost_value_to_vk(image), req)
    var want : VkMemoryPropertyFlags
    want.device_local = true
    let mai = MemoryAllocateInfo(allocationSize = req.size,
        memoryTypeIndex = find_memory_type(phys, req.memoryTypeBits, want))
    var inscope memory <- allocate_memory(device, mai)
    vk_check(vkBindImageMemory(boost_value_to_vk(device), boost_value_to_vk(image), boost_value_to_vk(memory), 0ul), null)

    var vci = ImageViewCreateInfo(image = weak_copy(image), viewType = VkImageViewType._2D, format = format)
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

    var d = OffscreenDepth(image <- image, memory <- memory, view <- view)
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
    let mai = MemoryAllocateInfo(allocationSize = req.size,
        memoryTypeIndex = find_memory_type(phys, req.memoryTypeBits, want))
    var inscope memory <- allocate_memory(device, mai)
    vk_check(vkBindBufferMemory(boost_value_to_vk(device), boost_value_to_vk(buffer), boost_value_to_vk(memory), 0ul), null)
    var hb = HostBuffer(buffer <- buffer, memory <- memory, size = size)
    return <- hb
}

//! HostBuffer with caller-chosen usage flags (vertex/index/uniform/storage/transfer_src/...). The
//! `(device, phys, size)` overload above hardcodes `transfer_dst` for the readback-buffer role;
//! this overload is the path tutorials reach for when they want a host-visible buffer with
//! arbitrary usage. Memory is still HOST_VISIBLE | HOST_COHERENT.
def public create_host_buffer(device : Device; phys : VkPhysicalDevice; size : uint64; usage : VkBufferUsageFlags) : HostBuffer {
    var bci = BufferCreateInfo(size = size, usage = usage)
    var inscope buffer <- create_buffer(device, bci)
    var req : VkMemoryRequirements
    vkGetBufferMemoryRequirements(boost_value_to_vk(device), boost_value_to_vk(buffer), req)
    var want : VkMemoryPropertyFlags
    want.host_visible = true
    want.host_coherent = true
    let mai = MemoryAllocateInfo(allocationSize = req.size,
        memoryTypeIndex = find_memory_type(phys, req.memoryTypeBits, want))
    var inscope memory <- allocate_memory(device, mai)
    vk_check(vkBindBufferMemory(boost_value_to_vk(device), boost_value_to_vk(buffer), boost_value_to_vk(memory), 0ul), null)
    var hb = HostBuffer(buffer <- buffer, memory <- memory, size = size)
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

//! Block-form dynamic-rendering wrapper: calls vkCmdBeginRendering before the block,
//! vkCmdEndRendering after. Vulkan 1.3 core. Replaces the (render_pass + framebuffer) pair
//! `record_render_pass` needs with an inline VkRenderingInfo built from `color_attachments`
//! + optional depth/stencil. The caller owns the boost `RenderingAttachmentInfo` values --
//! tutorial 09 uses one MSAA color attachment with a 1x resolve target wired into
//! `resolveImageView`, no extra render pass or framebuffer object required.
def public record_rendering(cmd : CommandBuffer; area : VkRect2D; layer_count : uint;
                            var color_attachments : array<RenderingAttachmentInfo>;
                            var depth_attachment : RenderingAttachmentInfo;
                            blk : block<() : void>) {
    var info = RenderingInfo(renderArea = area, layerCount = layer_count, viewMask = 0u,
        pColorAttachments <- color_attachments)
    unsafe {
        info.pDepthAttachment = addr(depth_attachment)
    }
    cmd_begin_rendering(cmd, info)
    invoke(blk)
    cmd_end_rendering(cmd)
}

//! Color-only `record_rendering` overload -- no depth/stencil attachment. Used by post-process
//! passes that write a fullscreen quad to an offscreen color target (tutorial 11).
def public record_rendering(cmd : CommandBuffer; area : VkRect2D; layer_count : uint;
                            var color_attachments : array<RenderingAttachmentInfo>;
                            blk : block<() : void>) {
    var info = RenderingInfo(renderArea = area, layerCount = layer_count, viewMask = 0u,
        pColorAttachments <- color_attachments)
    cmd_begin_rendering(cmd, info)
    invoke(blk)
    cmd_end_rendering(cmd)
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
    let flags : VkMemoryMapFlags
    unsafe {
        vk_check(vkMapMemory(boost_value_to_vk(device), boost_value_to_vk(memory), 0ul, VK_WHOLE_SIZE, flags, addr(mapped)), null)
    }
    invoke(blk, mapped)
    vkUnmapMemory(boost_value_to_vk(device), boost_value_to_vk(memory))
}

// Reusable CPU scratch for push-constant staging. Grows to the largest block seen and is never freed —
// a small per-program scratch reused every push, so no per-frame allocation in the record loop. Single-
// threaded command recording + the block below never re-enters, so a module global is safe.
var private g_push_staging : array<uint8>

//! Block-form std140 staging for push constants. Sizes a CPU scratch buffer to `size` bytes, hands the
//! block a raw pointer into it, and frees nothing (the scratch is reused). The push_constants_<shader>
//! macro drives this: the block writes each field at its std140 offset via `write_field` and then calls
//! vkCmdPushConstants with the same pointer, so the GPU receives std140-packed bytes rather than the raw
//! daslang struct image (which can diverge — e.g. a float3 immediately before a scalar packs differently).
def public with_push_staging(size : uint; blk : block<(ptr : void?) : void>) {
    return if (size == 0u)
    if (int(size) > length(g_push_staging)) {
        g_push_staging |> resize(int(size))
    }
    unsafe {
        invoke(blk, reinterpret<void?>(addr(g_push_staging[0])))
    }
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
    let flags : VkMemoryMapFlags
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
    let sci = SamplerCreateInfo(magFilter = VkFilter.LINEAR, minFilter = VkFilter.LINEAR,
        mipmapMode = VkSamplerMipmapMode.LINEAR, addressModeU = VkSamplerAddressMode.CLAMP_TO_BORDER,
        addressModeV = VkSamplerAddressMode.CLAMP_TO_BORDER, addressModeW = VkSamplerAddressMode.CLAMP_TO_BORDER,
        borderColor = VkBorderColor.FLOAT_OPAQUE_WHITE, compareEnable = VK_TRUE, compareOp = compare_op)
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

// ===== hardware ray tracing rails (VK_KHR_ray_tracing_pipeline) =====

//! buffer + memory allocated with the DEVICE_ADDRESS flag + its GPU virtual address, owned
//! together. The building block for everything ray tracing references by VkDeviceAddress:
//! acceleration-structure storage, build scratch, build inputs, shader binding tables.
struct public AddressBuffer {
    buffer : Buffer
    memory : DeviceMemory
    size : uint64
    address : uint64
}

def public finalize(var ab : AddressBuffer) {
    delete ab.buffer
    delete ab.memory
}

//! Create a buffer + memory + device address. The helper adds the ``shader_device_address``
//! usage bit and the matching ``VkMemoryAllocateFlagsInfo`` DEVICE_ADDRESS allocate flag (an
//! address query against memory allocated without it is invalid). ``host_visible = true``
//! allocates HOST_VISIBLE|HOST_COHERENT memory (mappable — SBTs, AS build inputs); ``false``
//! allocates DEVICE_LOCAL (AS storage, scratch). Requires a device created with the
//! ``bufferDeviceAddress`` feature (create_device_ray_tracing).
def public create_address_buffer(device : Device; phys : VkPhysicalDevice; size : uint64;
                                 usage : VkBufferUsageFlags; host_visible : bool) : AddressBuffer {
    var u = usage
    u.shader_device_address = true
    var bci = BufferCreateInfo(size = size, usage = u)
    var inscope buffer <- create_buffer(device, bci)
    var req : VkMemoryRequirements
    vkGetBufferMemoryRequirements(boost_value_to_vk(device), boost_value_to_vk(buffer), req)
    var want : VkMemoryPropertyFlags
    if (host_visible) {
        want.host_visible = true
        want.host_coherent = true
    } else {
        want.device_local = true
    }
    var flags_info = VkMemoryAllocateFlagsInfo()
    flags_info.flags.device_address = true
    var mai = MemoryAllocateInfo(allocationSize = req.size,
        memoryTypeIndex = find_memory_type(phys, req.memoryTypeBits, want))
    unsafe {
        mai.next = reinterpret<void?>(addr(flags_info))
    }
    var inscope memory <- allocate_memory(device, mai)
    vk_check(vkBindBufferMemory(boost_value_to_vk(device), boost_value_to_vk(buffer), boost_value_to_vk(memory), 0ul), null)
    let bdai = BufferDeviceAddressInfo(buffer = weak_copy(buffer))
    let address = get_buffer_device_address(device, bdai)
    var ab = AddressBuffer(buffer <- buffer, memory <- memory, size = size, address = address)
    return <- ab
}

//! Typed upload of `array<TT>` into an AddressBuffer (host_visible allocations only) — same
//! contract as the HostBuffer overload.
def public upload_bytes(buf : AddressBuffer; device : Device; var data : array<auto(TT)>) {
    if (empty(data)) {
        return
    }
    let nbytes = length(data) * typeinfo sizeof(type<TT>)
    assert(uint64(nbytes) <= buf.size, "upload_bytes: data exceeds destination AddressBuffer.size")
    var mapped : void? = null
    let mf : VkMemoryMapFlags
    unsafe {
        vk_check(vkMapMemory(boost_value_to_vk(device), boost_value_to_vk(buf.memory), 0ul, uint64(nbytes), mf, addr(mapped)), null)
        memcpy(mapped, reinterpret<void?>(addr(data[0])), nbytes)
    }
    vkUnmapMemory(boost_value_to_vk(device), boost_value_to_vk(buf.memory))
}

//! Query the ray-tracing pipeline properties (the shader-group handle size / alignment rules the
//! SBT layout needs) via the ``vkGetPhysicalDeviceProperties2`` pNext chain.
def public get_ray_tracing_properties(phys : VkPhysicalDevice) : VkPhysicalDeviceRayTracingPipelinePropertiesKHR {
    var rtp = VkPhysicalDeviceRayTracingPipelinePropertiesKHR()
    var p2 = VkPhysicalDeviceProperties2()
    unsafe {
        p2.pNext = reinterpret<void?>(addr(rtp))
    }
    vkGetPhysicalDeviceProperties2(phys, p2)
    rtp.pNext = null   // don't leak the dangling chain pointer to the caller
    return rtp
}

//! Fetch the opaque shader-group handles of a ray-tracing pipeline
//! (``vkGetRayTracingShaderGroupHandlesKHR`` — raw-only in the generated layer: its ``void*``
//! out-param is not boost-mappable). Returns ``group_count`` records of ``handle_size`` bytes,
//! tightly packed — the raw material build_shader_binding_table copies into aligned SBT records.
def public get_ray_tracing_shader_group_handles(device : Device; pipeline : Pipeline;
                                                first_group : uint; group_count : uint; handle_size : uint) : array<uint8> {
    var data : array<uint8>
    data |> resize(int(group_count * handle_size))
    unsafe {
        vk_check(vkGetRayTracingShaderGroupHandlesKHR(boost_value_to_vk(device), boost_value_to_vk(pipeline),
            first_group, group_count, uint64(length(data)), reinterpret<void?>(addr(data[0]))), null)
    }
    return <- data
}

//! Create a triangle-path ray-tracing pipeline: raygen + N miss + closest-hit stages, one GENERAL
//! group per general stage and one TRIANGLES_HIT_GROUP for the closest-hit. Group order is
//! [raygen, miss[0..N), hit] — the layout build_shader_binding_table assumes; ``traceRayEXT``'s
//! ``miss_index`` selects within the miss region. Shadow-ray setups take two miss shaders (index
//! 0 = radiance/sky, index 1 = the shadow "lit" flip). ``max_recursion >= 2`` lets the
//! closest-hit stage trace (shadow) rays itself.
def public create_ray_tracing_pipeline(device : Device; layout : PipelineLayout;
                                       raygen : ShaderModule; miss : array<ShaderModule>; closest_hit : ShaderModule;
                                       max_recursion : uint = 1u) : Pipeline {
    assert(!empty(miss), "create_ray_tracing_pipeline: need at least one miss shader")
    var ci : RayTracingPipelineCreateInfoKHR
    ci.pStages |> reserve(2 + length(miss))
    ci.pGroups |> reserve(2 + length(miss))
    var st_rgen = PipelineShaderStageCreateInfo(module_ = weak_copy(raygen), pName = "main")
    st_rgen.stage.raygen_khr = true
    ci.pStages |> emplace(st_rgen)
    ci.pGroups |> push(RayTracingShaderGroupCreateInfoKHR(type_ = VkRayTracingShaderGroupTypeKHR.GENERAL_KHR,
        generalShader = 0u, closestHitShader = VK_SHADER_UNUSED_KHR,
        anyHitShader = VK_SHADER_UNUSED_KHR, intersectionShader = VK_SHADER_UNUSED_KHR))
    for (i in range(length(miss))) {
        var st_miss = PipelineShaderStageCreateInfo(module_ = weak_copy(miss[i]), pName = "main")
        st_miss.stage.miss_khr = true
        ci.pStages |> emplace(st_miss)
        ci.pGroups |> push(RayTracingShaderGroupCreateInfoKHR(type_ = VkRayTracingShaderGroupTypeKHR.GENERAL_KHR,
            generalShader = uint(1 + i), closestHitShader = VK_SHADER_UNUSED_KHR,
            anyHitShader = VK_SHADER_UNUSED_KHR, intersectionShader = VK_SHADER_UNUSED_KHR))
    }
    var st_chit = PipelineShaderStageCreateInfo(module_ = weak_copy(closest_hit), pName = "main")
    st_chit.stage.closest_hit_khr = true
    ci.pStages |> emplace(st_chit)
    ci.pGroups |> push(RayTracingShaderGroupCreateInfoKHR(type_ = VkRayTracingShaderGroupTypeKHR.TRIANGLES_HIT_GROUP_KHR,
        generalShader = VK_SHADER_UNUSED_KHR, closestHitShader = uint(1 + length(miss)),
        anyHitShader = VK_SHADER_UNUSED_KHR, intersectionShader = VK_SHADER_UNUSED_KHR))
    ci.maxPipelineRayRecursionDepth = max_recursion
    ci.layout = weak_copy(layout)
    var infos : array<RayTracingPipelineCreateInfoKHR>
    infos |> emplace(ci)
    var no_op : DeferredOperationKHR
    var no_cache : PipelineCache
    var pipes <- create_ray_tracing_pipelines_k_h_r(device, no_op, no_cache, infos)
    unsafe {
        delete infos
    }
    var p <- pipes[0]
    delete pipes
    return <- p
}

//! Single-miss convenience over the N-miss overload: groups [raygen, miss, hit].
def public create_ray_tracing_pipeline(device : Device; layout : PipelineLayout;
                                       raygen : ShaderModule; miss : ShaderModule; closest_hit : ShaderModule;
                                       max_recursion : uint = 1u) : Pipeline {
    var mlist : array<ShaderModule>
    mlist |> push(weak_copy(miss))
    var p <- create_ray_tracing_pipeline(device, layout, raygen, mlist, closest_hit, max_recursion)
    delete mlist
    return <- p
}

//! A built shader binding table: the backing device-address buffer plus the four strided regions
//! ``cmd_trace_rays_k_h_r`` consumes. ``callable`` is a valid empty region (no callable shaders).
struct public ShaderBindingTable {
    buffer : AddressBuffer
    raygen : StridedDeviceAddressRegionKHR
    miss : StridedDeviceAddressRegionKHR
    hit : StridedDeviceAddressRegionKHR
    callable : StridedDeviceAddressRegionKHR
}

def public finalize(var sbt : ShaderBindingTable) {
    delete sbt.buffer
}

def private align_up(v : uint64; alignment : uint64) : uint64 => (v + alignment - 1ul) & ~(alignment - 1ul)

//! Build the shader binding table for a pipeline created by create_ray_tracing_pipeline (group
//! order [raygen | miss_count × miss | hit_count × hit]). Queries the device's group-handle
//! size/alignment rules, fetches the opaque handles, packs them into records aligned per
//! ``shaderGroupHandleAlignment`` with each region start aligned per ``shaderGroupBaseAlignment``,
//! and uploads into a SHADER_BINDING_TABLE device-address buffer. The returned regions point into
//! that buffer — keep the ShaderBindingTable alive for every trace that uses it.
def public build_shader_binding_table(device : Device; phys : VkPhysicalDevice; pipeline : Pipeline;
                                      miss_count : uint; hit_count : uint) : ShaderBindingTable {
    let props = get_ray_tracing_properties(phys)
    let handle_size = uint64(props.shaderGroupHandleSize)
    let record = align_up(handle_size, uint64(props.shaderGroupHandleAlignment))
    let base_align = uint64(props.shaderGroupBaseAlignment)
    let rgen_size = align_up(record, base_align)
    let miss_size = align_up(uint64(miss_count) * record, base_align)
    let hit_size = align_up(uint64(hit_count) * record, base_align)
    let total = rgen_size + miss_size + hit_size
    let group_count = 1u + miss_count + hit_count
    var handles <- get_ray_tracing_shader_group_handles(device, pipeline, 0u, group_count, uint(handle_size))
    var usage : VkBufferUsageFlags
    usage.shader_binding_table_khr = true
    // over-allocate by base_align so the record block can start base-aligned even when the
    // buffer's device address itself is not (region.deviceAddress % base_align must be 0)
    var sbt = ShaderBindingTable(buffer <- create_address_buffer(device, phys, total + base_align, usage, true))
    let start = align_up(sbt.buffer.address, base_align)
    let pad = int(start - sbt.buffer.address)
    var records : array<uint8>
    records |> resize(pad + int(total))
    for (g in range(int(group_count))) {
        var dst = pad
        if (g == 0) {
            dst += 0
        } elif (g <= int(miss_count)) {
            dst += int(rgen_size) + (g - 1) * int(record)
        } else {
            dst += int(rgen_size + miss_size) + (g - 1 - int(miss_count)) * int(record)
        }
        for (b in range(int(handle_size))) {
            records[dst + b] = handles[g * int(handle_size) + b]
        }
    }
    sbt.buffer |> upload_bytes(device, records)
    delete handles
    delete records
    sbt.raygen = StridedDeviceAddressRegionKHR(deviceAddress = start, stride = rgen_size, size = rgen_size)
    sbt.miss = StridedDeviceAddressRegionKHR(deviceAddress = start + rgen_size, stride = record, size = miss_size)
    sbt.hit = StridedDeviceAddressRegionKHR(deviceAddress = start + rgen_size + miss_size, stride = record, size = hit_size)
    return <- sbt
}

//! Trace using a built ShaderBindingTable (the four strided regions in one argument).
def public cmd_trace_rays(cmd : CommandBuffer; sbt : ShaderBindingTable; width : uint; height : uint; depth : uint = 1u) {
    cmd_trace_rays_k_h_r(cmd, sbt.raygen, sbt.miss, sbt.hit, sbt.callable, width, height, depth)
}

//! Host-side stand-in for ``VkAccelerationStructureInstanceKHR``, which the generator skips (C
//! bitfield members). The daslang layout is byte-identical to the C struct (48-byte row-major
//! 3x4 transform, two packed bitfield words, the referenced BLAS address), so an
//! ``array<AccelInstance>`` uploads straight into the TLAS instance buffer. Build records with
//! make_accel_instance (it packs the bitfield words); set translation via ``inst.transform[r][3]``.
struct public AccelInstance {
    transform : float[3][4]        // row r = [x-axis, y-axis, z-axis, translation][r]
    customIndex24_mask8 : uint     // instanceCustomIndex:24 | mask:8
    sbtOffset24_flags8 : uint      // instanceShaderBindingTableRecordOffset:24 | flags:8
    blasAddress : uint64           // accelerationStructureReference
}

//! An AccelInstance with the identity transform. ``flags`` is VkGeometryInstanceFlagBitsKHR
//! (e.g. 1 = TRIANGLE_FACING_CULL_DISABLE); the default ``mask`` 0xFF passes every trace cull mask.
def public make_accel_instance(blas_address : uint64; custom_index : uint = 0u; mask : uint = 0xFFu;
                               sbt_record_offset : uint = 0u; flags : uint = 0u) : AccelInstance {
    var inst : AccelInstance
    inst.transform[0][0] = 1.0
    inst.transform[1][1] = 1.0
    inst.transform[2][2] = 1.0
    inst.customIndex24_mask8 = (custom_index & 0x00FFFFFFu) | (mask << 24u)
    inst.sbtOffset24_flags8 = (sbt_record_offset & 0x00FFFFFFu) | (flags << 24u)
    inst.blasAddress = blas_address
    return inst
}

//! An acceleration structure with its backing storage buffer and GPU address, owned together
//! (``var inscope tlas <- build_tlas(...)``). For a BLAS, ``address`` is what TLAS instances
//! reference (make_accel_instance takes it).
struct public AccelStructure {
    handle : AccelerationStructureKHR
    buffer : AddressBuffer
    address : uint64
}

def public finalize(var a : AccelStructure) {
    delete a.handle
    delete a.buffer
}

// shared create→sizes→scratch→build→address dance behind build_blas / build_tlas. run_cmd_sync
// waits the queue idle, so the scratch (and the caller's build-input buffers) may be freed right
// after, and a BLAS built this way is complete before a TLAS build that references it starts.
def private build_accel_structure(device : Device; phys : VkPhysicalDevice; pool : CommandPool; queue : VkQueue;
                                  geom : AccelerationStructureGeometryKHR; as_type : VkAccelerationStructureTypeKHR;
                                  prim_count : uint) : AccelStructure {
    var bgi = AccelerationStructureBuildGeometryInfoKHR(type_ = as_type,
        mode = VkBuildAccelerationStructureModeKHR.BUILD_KHR)
    bgi.flags.prefer_fast_trace_khr = true
    bgi.pGeometries |> push(geom)
    var max_prims <- [prim_count]
    let sizes = get_acceleration_structure_build_sizes_k_h_r(device, VkAccelerationStructureBuildTypeKHR.DEVICE_KHR, bgi, max_prims)
    delete max_prims
    var storage_usage : VkBufferUsageFlags
    storage_usage.acceleration_structure_storage_khr = true
    var inscope as_buf <- create_address_buffer(device, phys, sizes.accelerationStructureSize, storage_usage, false)
    let asci = AccelerationStructureCreateInfoKHR(buffer = weak_copy(as_buf.buffer),
        size = sizes.accelerationStructureSize, type_ = as_type)
    var inscope handle <- create_acceleration_structure_k_h_r(device, asci)
    var scratch_usage : VkBufferUsageFlags
    scratch_usage.storage_buffer = true
    var inscope scratch <- create_address_buffer(device, phys, sizes.buildScratchSize, scratch_usage, false)
    bgi.dstAccelerationStructure = weak_copy(handle)
    bgi.scratchData.deviceAddress = scratch.address
    var infos : array<AccelerationStructureBuildGeometryInfoKHR>
    infos |> emplace(bgi)
    var ranges : array<array<AccelerationStructureBuildRangeInfoKHR>>
    ranges |> resize(1)
    ranges[0] |> push(AccelerationStructureBuildRangeInfoKHR(primitiveCount = prim_count))
    run_cmd_sync(device, pool, queue) $(cmd) {
        cmd_build_acceleration_structures_k_h_r(cmd, infos, ranges)
    }
    unsafe {
        delete infos
    }
    delete ranges
    let dai = AccelerationStructureDeviceAddressInfoKHR(accelerationStructure = weak_copy(handle))
    let address = get_acceleration_structure_device_address_k_h_r(device, dai)
    var result = AccelStructure(handle <- handle, buffer <- as_buf, address = address)
    return <- result
}

//! Build a bottom-level acceleration structure over an indexed triangle list, blocking until the
//! GPU build completes. ``vertices`` are xyz positions (VK_FORMAT_R32G32B32_SFLOAT, stride
//! ``sizeof(float3)``); ``indices`` are uint triples, one per triangle. The build-input buffers
//! are transient — only the returned AccelStructure stays resident.
def public build_blas(device : Device; phys : VkPhysicalDevice; pool : CommandPool; queue : VkQueue;
                      var vertices : array<float3>; var indices : array<uint>) : AccelStructure {
    assert(!empty(vertices), "build_blas: vertices must be non-empty")
    assert(!empty(indices), "build_blas: indices must be non-empty")
    assert(length(indices) % 3 == 0, "build_blas: indices must be uint triples")
    var input_usage : VkBufferUsageFlags
    input_usage.acceleration_structure_build_input_read_only_khr = true
    let vsize = uint64(length(vertices) * typeinfo sizeof(type<float3>))
    var inscope vbuf <- create_address_buffer(device, phys, vsize, input_usage, true)
    vbuf |> upload_bytes(device, vertices)
    let isize = uint64(length(indices) * 4)
    var inscope ibuf <- create_address_buffer(device, phys, isize, input_usage, true)
    ibuf |> upload_bytes(device, indices)
    var tri = VkAccelerationStructureGeometryTrianglesDataKHR()
    tri.vertexFormat = VkFormat.R32G32B32_SFLOAT
    tri.vertexData.deviceAddress = vbuf.address
    tri.vertexStride = uint64(typeinfo sizeof(type<float3>))
    tri.maxVertex = uint(length(vertices) - 1)
    tri.indexType = VkIndexType.UINT32
    tri.indexData.deviceAddress = ibuf.address
    var geom : AccelerationStructureGeometryKHR
    geom.geometryType = VkGeometryTypeKHR.TRIANGLES_KHR
    geom.geometry.triangles = tri
    geom.flags.opaque_khr = true
    return <- build_accel_structure(device, phys, pool, queue, geom, VkAccelerationStructureTypeKHR.BOTTOM_LEVEL_KHR,
        uint(length(indices) / 3))
}

//! Build a top-level acceleration structure over BLAS instances (make_accel_instance), blocking
//! until the GPU build completes. The referenced BLASes must be fully built — true for build_blas,
//! which waits the queue idle.
def public build_tlas(device : Device; phys : VkPhysicalDevice; pool : CommandPool; queue : VkQueue;
                      var instances : array<AccelInstance>) : AccelStructure {
    static_assert(typeinfo sizeof(type<AccelInstance>) == 64, "AccelInstance must stay wire-identical to VkAccelerationStructureInstanceKHR (64 bytes)")
    assert(!empty(instances), "build_tlas: instances must be non-empty")
    var input_usage : VkBufferUsageFlags
    input_usage.acceleration_structure_build_input_read_only_khr = true
    let isize = uint64(length(instances) * typeinfo sizeof(type<AccelInstance>))
    var inscope ibuf <- create_address_buffer(device, phys, isize, input_usage, true)
    ibuf |> upload_bytes(device, instances)
    var idata = VkAccelerationStructureGeometryInstancesDataKHR()
    idata.data.deviceAddress = ibuf.address
    var geom : AccelerationStructureGeometryKHR
    geom.geometryType = VkGeometryTypeKHR.INSTANCES_KHR
    geom.geometry.instances = idata
    return <- build_accel_structure(device, phys, pool, queue, geom, VkAccelerationStructureTypeKHR.TOP_LEVEL_KHR,
        uint(length(instances)))
}

//! Write a top-level acceleration structure into a descriptor set — the pNext-chained
//! ``VkWriteDescriptorSetAccelerationStructureKHR`` dance in one call. Matches the
//! ``SpirvDescriptorKind.acceleration_structure`` binding vulkan_reflect lays out for an
//! ``accelerationStructureEXT`` shader global.
def public write_descriptor_acceleration_structure(device : Device; dset : DescriptorSet; binding : uint; tlas : AccelStructure) {
    var raw_as = boost_value_to_vk(tlas.handle)
    var was = VkWriteDescriptorSetAccelerationStructureKHR()
    was.accelerationStructureCount = 1u
    var w = VkWriteDescriptorSet()
    w.dstSet = boost_value_to_vk(dset)
    w.dstBinding = binding
    w.descriptorCount = 1u
    w.descriptorType = VkDescriptorType.ACCELERATION_STRUCTURE_KHR
    unsafe {
        was.pAccelerationStructures = addr(raw_as)
        w.pNext = reinterpret<void?>(addr(was))
        vkUpdateDescriptorSets(boost_value_to_vk(device), 1u, addr(w), 0u, null)
    }
}
