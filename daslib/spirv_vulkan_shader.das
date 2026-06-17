options gen2
options indenting = 4

// Vulkan-specific dasSpirv shader subclass + annotations. Mirrors the dasGlsl/dasOpenGL split:
// dasSpirv declares abstract bind hooks on SpirvShader; this subclass overrides them to emit
// Vulkan-flavored bind functions, and three function-macro annotations ([vulkan_vertex_shader],
// [vulkan_fragment_shader], [vulkan_compute_shader]) instantiate the subclass.
//
// generate_bind_uniform walks every @uniform-tagged module global reachable from the shader,
// computes its std140 layout via spirv_emit::compute_block_layout (the same offsets the SPIR-V
// emitter uses to lay out the interface block — single source of truth), and emits one write_field
// call per std140 field at its byte offset. The whole body is wrapped in with_mapped_memory so
// vkMapMemory/vkUnmapMemory bookend a single map cycle per call.

module spirv_vulkan_shader shared public

// vulkan_boost (where with_mapped_memory + write_field live) is NOT a shared module, so this
// shared macro module can't require it directly. It's not needed at macro time anyway — we just
// emit symbolic ExprCall("with_mapped_memory") / ExprCall("write_field") and rely on the consumer
// (tutorial / app) module's `require vulkan/vulkan_boost public` for resolution at codegen time.
// Same trick dasOpenGL's glsl_opengl uses for glUniformAny without requiring opengl_boost.
require spirv/spirv_shader public
require spirv/spirv_emit
require daslib/ast
require daslib/ast_boost
require daslib/templates_boost

class SpirvVulkanShader : SpirvShader {
    def override generate_bind_uniform_dummy(var func : FunctionPtr) {
        spirv_vulkan_shader::generate_bind_uniform_dummy(func)
    }
    def override generate_bind_uniform(fnMain : FunctionPtr; var fn : FunctionPtr) {
        spirv_vulkan_shader::generate_bind_uniform(fnMain, fn)
    }
    def override generate_push_constants_dummy(var func : FunctionPtr) {
        spirv_vulkan_shader::generate_push_constants_dummy(func)
    }
    def override generate_push_constants(fnMain : FunctionPtr; var fn : FunctionPtr) {
        spirv_vulkan_shader::generate_push_constants(fnMain, fn, shader_stage())
    }
}

[function_macro(name="vulkan_compute_shader")]
class SpirvVulkanComputeShader : SpirvVulkanShader {
    def override shader_stage() : ShaderStage => ShaderStage.Compute
}

[function_macro(name="vulkan_vertex_shader")]
class SpirvVulkanVertexShader : SpirvVulkanShader {
    def override shader_stage() : ShaderStage => ShaderStage.Vertex
}

[function_macro(name="vulkan_fragment_shader")]
class SpirvVulkanFragmentShader : SpirvVulkanShader {
    def override shader_stage() : ShaderStage => ShaderStage.Fragment
}

// Reserve an empty bind_uniform_<shader>(device : Device; memory : DeviceMemory) function so
// consumer code referencing it resolves during the first inference pass. The body is filled in
// patch by generate_bind_uniform; until then `exports = true` flags the function as still dummy.
[macro_function]
def private generate_bind_uniform_dummy(fnMain : FunctionPtr) {
    var fn = new Function(at = fnMain.at, atDecl = fnMain.at, name := bind_uniform_function_name(fnMain))
    fn.flags.generated = true
    fn.flags.exports = true
    fn.result = new TypeDecl(at = fnMain.at, baseType = Type.tVoid)
    // const: caller's `ctx.device` / `ctx.ubo.memory` may be const in scope; this lets either form bind.
    var dev_type <- new TypeDecl(at = fnMain.at, baseType = Type.alias, alias := "Device")
    dev_type.flags.constant = true
    fn.arguments |> emplace_new() <| new Variable(at = fnMain.at, name := "device", _type <- dev_type)
    var mem_type <- new TypeDecl(at = fnMain.at, baseType = Type.alias, alias := "DeviceMemory")
    mem_type.flags.constant = true
    fn.arguments |> emplace_new() <| new Variable(at = fnMain.at, name := "memory", _type <- mem_type)
    fn.body = new ExprBlock(at = fnMain.at)
    if (!(compiling_module() |> add_function(fn))) {
        panic("can't reserve bind_uniform dummy function for {fnMain.name}")
    }
}

// Fill the dummy bind_uniform function body: for every @uniform struct global reachable from
// fnMain, walk its std140 field layout and emit one write_field call per field. The whole body
// is wrapped in `with_mapped_memory(device, memory) <| $(ptr : void?) { ... }` so each call to
// the generated function does exactly one map/unmap cycle. Samplers/images are skipped here —
// they bind via descriptor-set writes, not via mapped memory.
[macro_function]
def private generate_bind_uniform(fnMain : FunctionPtr; var fn : FunctionPtr) {
    var inner = new ExprBlock(at = fn.at)
    inner.blockFlags.isClosure = true
    inner.returnType = new TypeDecl(at = fn.at, baseType = Type.tVoid)
    var ptr_arg <- new Variable(at = fn.at, name := "ptr")
    ptr_arg._type = new TypeDecl(at = fn.at,
        baseType = Type.tPointer,
        firstType = new TypeDecl(at = fn.at, baseType = Type.tVoid)
    )
    // Mark the parameter type as const so the block sig matches `block<(ptr : void?) : void>` —
    // block params default to const in source, but a macro-built Variable defaults to mutable.
    ptr_arg._type.flags.constant = true
    inner.arguments |> emplace(ptr_arg)

    // First pass: collect reachable @uniform struct globals. The generated function takes ONE
    // (device, memory) pair, so it can only write fields belonging to ONE UBO allocation -- if
    // a shader reaches >1 @uniform struct (different set/binding => different memory), writing
    // them all into the same allocation would corrupt the upload. Fail-closed at >1 until the
    // macro grows per-binding bind functions.
    var ubo_globals : array<Variable?>
    collect_dependencies(fnMain) $(vfun, vvar) {
        for (vv in vvar) {
            if (!(vv.annotation |> find_arg("uniform") is tBool)) continue
            // Only struct-typed @uniform globals (the std140 interface-block case). Samplers /
            // images / standalone scalars under @uniform either bind via descriptors or aren't
            // supported here; skip them silently — the SPIR-V emitter has already rejected any
            // invalid combos.
            if (vv._type == null || vv._type.baseType != Type.tStructure || vv._type.structType == null) continue
            ubo_globals |> push(vv)
        }
    }
    if (length(ubo_globals) > 1) {
        macro_error(compiling_program(), ubo_globals[0].at,
            "[vulkan_*_shader]: shader reaches {length(ubo_globals)} @uniform struct globals; bind_uniform_<shader>(device, memory) takes one memory allocation and would corrupt cross-block writes. Split into separate shaders, merge the UBOs into one struct, or wait for per-binding bind functions.")
        unsafe { delete ubo_globals; }
        return
    }
    for (vv in ubo_globals) {
        let st = vv._type.structType
        var layout_errors : array<string>
        var fields : array<BlockField>
        let layout = compute_block_layout(string(vv.name), st, fields, layout_errors)
        if (!layout.ok) {
            // Fail-closed: a UBO that can't lay out (e.g. a bool field) silently producing a
            // no-op bind_uniform would write garbage at runtime. Surface the compute_block_layout
            // diagnostic through macro_error so the shader fails to compile. compute_block_layout
            // pushes exactly one error on the failure path; take the first.
            let msg = empty(layout_errors) ? "(no diagnostic)" : layout_errors[0]
            macro_error(compiling_program(), vv.at,
                "[vulkan_*_shader]: @uniform '{vv.name}' std140 layout failed: {msg}")
            delete fields
            delete layout_errors
            unsafe { delete ubo_globals; }
            return
        }
        for (f in fields) {
            var cll = new ExprCall(at = vv.at, name := "write_field")
            cll.arguments |> emplace_new() <| new ExprVar(at = vv.at, name := "ptr")
            cll.arguments |> emplace_new() <| new ExprConstUInt(at = vv.at, value = uint(f.offset))
            var fld_access = new ExprField(at = vv.at,
                value <- new ExprVar(at = vv.at, name := vv.name),
                name := f.name
            )
            cll.arguments |> emplace(fld_access)
            inner.list |> emplace(cll)
        }
        delete fields
        delete layout_errors
    }
    unsafe { delete ubo_globals; }

    var mkblk = new ExprMakeBlock(at = fn.at, _block = inner)
    var wmm = new ExprCall(at = fn.at, name := "with_mapped_memory")
    wmm.arguments |> emplace_new() <| new ExprVar(at = fn.at, name := "device")
    wmm.arguments |> emplace_new() <| new ExprVar(at = fn.at, name := "memory")
    wmm.arguments |> emplace(mkblk)

    var body = new ExprBlock(at = fn.at)
    body.list |> emplace(wmm)
    fn.body = body
}

// Map ShaderStage to the underlying VkShaderStageFlagBits integer. The push-constants codegen
// emits VkShaderStageFlags(<this_value>) as a const bitfield-from-uint construction -- field-name
// assignment (e.g. `flags.vertex = true`) doesn't work through qmacro $i splicing, but the integer
// ctor is straightforward. Values from VK_SHADER_STAGE_*_BIT in the Vulkan spec.
def private stage_to_uint(stage : ShaderStage) : uint {
    if (stage == ShaderStage.Vertex) return 0x1u
    if (stage == ShaderStage.Fragment) return 0x10u
    return 0x20u  // compute
}

// Reserve an empty push_constants_<shader>(cb : CommandBuffer; layout : PipelineLayout) function.
// Mirrors generate_bind_uniform_dummy.
[macro_function]
def private generate_push_constants_dummy(fnMain : FunctionPtr) {
    var fn = new Function(at = fnMain.at, atDecl = fnMain.at, name := push_constants_function_name(fnMain))
    fn.flags.generated = true
    fn.flags.exports = true
    fn.result = new TypeDecl(at = fnMain.at, baseType = Type.tVoid)
    // cb and layout are taken const -- block-captured `cmd` is naturally const, and the function
    // never mutates either handle; reads through boost_value_to_vk are const.
    var cb_type <- new TypeDecl(at = fnMain.at, baseType = Type.alias, alias := "CommandBuffer")
    cb_type.flags.constant = true
    fn.arguments |> emplace_new() <| new Variable(at = fnMain.at, name := "cb", _type <- cb_type)
    var layout_type <- new TypeDecl(at = fnMain.at, baseType = Type.alias, alias := "PipelineLayout")
    layout_type.flags.constant = true
    fn.arguments |> emplace_new() <| new Variable(at = fnMain.at, name := "layout", _type <- layout_type)
    fn.body = new ExprBlock(at = fnMain.at)
    if (!(compiling_module() |> add_function(fn))) {
        panic("can't reserve push_constants dummy function for {fnMain.name}")
    }
}

// Fill the push_constants function body: for every @push_constant struct global reachable from
// fnMain, emit one vkCmdPushConstants(cb, layout, stage_flags, 0u, sizeof_struct, addr(pc_var)).
// stage_flags is the shader's own stage -- if a push constant is read by multiple stages, the
// caller will run each stage's push function. Vulkan accepts updates from any subset of the
// declared range's stages.
[macro_function]
def private generate_push_constants(fnMain : FunctionPtr; var fn : FunctionPtr; stage : ShaderStage) {
    let stage_uint = stage_to_uint(stage)
    var stmt_list : array<Expression?>
    // First pass: collect reachable @push_constant struct globals. Vulkan allows at most ONE
    // push-constant block per stage, and the current macro hard-codes offset=0 for all writes --
    // emitting two pushes at offset=0 would overlap and corrupt. Fail-closed at >1 until per-range
    // pushing (offset + size per block) is wired up.
    var pc_globals : array<Variable?>
    collect_dependencies(fnMain) $(vfun, vvar) {
        for (vv in vvar) {
            if (!(vv.annotation |> find_arg("push_constant") is tBool)) continue
            if (vv._type == null || vv._type.baseType != Type.tStructure || vv._type.structType == null) continue
            pc_globals |> push(vv)
        }
    }
    if (length(pc_globals) > 1) {
        macro_error(compiling_program(), pc_globals[0].at,
            "[vulkan_*_shader]: shader reaches {length(pc_globals)} @push_constant struct globals; the generated function always pushes at offset=0 and would emit overlapping vkCmdPushConstants writes. Vulkan also caps push-constant blocks at one per stage -- merge the structs.")
        unsafe { delete pc_globals; }
        return
    }
    for (vv in pc_globals) {
        // size = std140 layout size of the push block. The user's daslang struct should match
        // this byte-for-byte (no float3-followed-by-scalar surprises) -- the bytes are uploaded
        // direct from addr(pc_var); if the layouts diverge the shader reads garbage.
        var errs : array<string>
        var fields : array<BlockField>
        let layout_info = compute_block_layout(string(vv.name), vv._type.structType, fields, errs)
        if (!layout_info.ok) {
            // Fail-closed: a @push_constant whose std140 size can't be computed would silently
            // skip the vkCmdPushConstants update, leaving stale push state and a corrupt frame.
            // Same rule as the @uniform path -- surface and abort.
            let msg = empty(errs) ? "(no diagnostic)" : errs[0]
            macro_error(compiling_program(), vv.at,
                "[vulkan_*_shader]: @push_constant '{vv.name}' std140 layout failed: {msg}")
            delete fields
            delete errs
            unsafe { delete pc_globals; }
            return
        }
        delete fields
        delete errs
        let var_name = string(vv.name)
        let size_expr <- new ExprConstUInt(at = vv.at, value = uint(layout_info.size))
        let stage_expr <- new ExprConstUInt(at = vv.at, value = stage_uint)
        stmt_list |> push_block_list <| qmacro_block() {
            unsafe {
                vkCmdPushConstants(boost_value_to_vk(cb), boost_value_to_vk(layout),
                    VkShaderStageFlags($e(stage_expr)), 0u, $e(size_expr),
                    reinterpret<void?>(addr($i(var_name))))
            }
        }
    }
    unsafe { delete pc_globals; }
    var body = new ExprBlock(at = fn.at)
    for (s in stmt_list) {
        body.list |> emplace(s)
    }
    fn.body = body
}
