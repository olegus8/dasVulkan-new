options gen2
options indenting = 4
options persistent_heap = true

module vk_emit_boost

require vk_model
require vk_naming
require vk_emit
require daslib/fio
require strings
require daslib/strings_boost

// OB / CB / GEN_HEADER are re-exported from vk_emit

//! C scalar type -> daslang scalar type (for boost field declarations)
let DAS_SCALAR_MAP : table<string; string> <- {
    "int8_t" => "int8", "uint8_t" => "uint8", "int16_t" => "int16", "uint16_t" => "uint16",
    "int32_t" => "int", "uint32_t" => "uint", "int" => "int",
    "int64_t" => "int64", "uint64_t" => "uint64",
    "float" => "float", "double" => "double", "size_t" => "uint64", "char" => "int8"
}

// ===== ctors: sType-filling constructors over the RAW Vk structs =====
// daslang has no #if, so the boost can only reference types registered on every
// platform -- emit only for non-platform-guarded structs (protect == "").

def private emit_ctors(reg : VkRegistry; em : EmitModel; out_dir : string) {
    let stype_prefix = enum_value_prefix("VkStructureType", false, reg.vendor_tags)
    var count = 0
    fopen("{out_dir}/vulkan_ctors.das", "wb") $(f) {
        panic("can't write vulkan_ctors.das") if (f == null)
        fprint(f, GEN_HEADER)
        fprint(f, "options gen2\noptions indenting = 4\n\nmodule vulkan_ctors\n\nrequire vulkan public\n\n")
        for (s in reg.structs) {
            continue if (!empty(s.alias))
            continue if (!key_exists(em.struct_emit, s.name))
            continue if (!empty(s.protect))
            // find the sType member (always named "sType" with a values= attribute)
            var stype_const = ""
            for (m in s.members) {
                if (m.name == "sType" && !empty(m.stype_value)) {
                    stype_const = m.stype_value
                    break
                }
            }
            continue if (empty(stype_const))
            let short = enum_short_name(stype_prefix, stype_const)
            fprint(f, "//! construct a {s.name} with sType pre-filled\n")
            fprint(f, "def {s.name}() : {s.name} {OB}\n")
            fprint(f, "    var self : {s.name}\n")
            fprint(f, "    self.sType = VkStructureType.{short}\n")
            fprint(f, "    return self\n")
            fprint(f, "{CB}\n\n")
            count++
        }
    }
    to_log(LOG_INFO, "boost: {count} sType constructors -> vulkan_ctors.das\n")
}

// ===== ownership: derive create/destroy pairs, emit wrapper structs =====

//! the idiomatic boost name for a handle: strip the leading "Vk"
def public boost_name(vk_handle : string) : string {
    if (vk_handle |> starts_with("Vk")) {
        return vk_handle |> slice(2)
    }
    return vk_handle
}

struct ParentField {
    field : string      //! "_device"
    vktype : string     //! "VkDevice"
}

struct OwnerInfo {
    handle : string         //! VkImage
    boost : string          //! Image
    destroyer : string      //! vkDestroyImage / vkFreeMemory  ("" = no destroyer)
    parents : array<ParentField>
    pool_owned : bool       //! freed by a pool (cmd buffers / descriptor sets) -> finalize no-op
}

def private is_boost_handle(em : EmitModel; tn : string) : bool {
    return key_exists(em.handle_names, tn)
}

//! a command is a destroyer if it is named vkDestroy*/vkFree* and takes a handle param
def private find_destroyers(reg : VkRegistry; em : EmitModel) : table<string; int> {
    var result : table<string; int>    // handle name -> command index
    for (c, idx in reg.commands, range(length(reg.commands))) {
        continue if (!empty(c.alias))
        continue if (!key_exists(reg.enabled_commands, c.name))
        continue if (!empty(c.protect))
        let is_destroy = c.name |> starts_with("vkDestroy")
        let is_free = c.name |> starts_with("vkFree")
        continue if (!is_destroy && !is_free)
        // the destroyed handle is the (usually last) handle-typed param
        for (p in c.params) {
            if (is_boost_handle(em, p.type_name) && !key_exists(result, p.type_name)) {
                result[p.type_name] = idx
            }
        }
    }
    return <- result
}

def public derive_owners(reg : VkRegistry; em : EmitModel) : array<OwnerInfo> {
    let destroyers = find_destroyers(reg, em)
    var owners : array<OwnerInfo>
    for (h in reg.handles) {
        continue if (!empty(h.alias))
        continue if (!is_boost_handle(em, h.name))
        continue if (!empty(h.protect))
        var oi = OwnerInfo(handle = h.name, boost = boost_name(h.name))
        let didx = destroyers?[h.name] ?? -1
        if (didx >= 0) {
            let dc & = unsafe(reg.commands[didx])
            oi.destroyer = dc.name
            // parents = the np==0 handle params that appear before the destroyed handle
            for (p in dc.params) {
                if (p.type_name == h.name) {
                    break
                }
                if (is_boost_handle(em, p.type_name) && p.num_ptrs == 0) {
                    oi.parents |> emplace(ParentField(field = "_{das_safe_name(p.name)}", vktype = p.type_name))
                }
            }
            // array-free (the destroyed handle param is a pointer) => pool-owned, finalize is a no-op
            for (p in dc.params) {
                if (p.type_name == h.name && p.num_ptrs >= 1) {
                    oi.pool_owned = true
                }
            }
        }
        owners |> emplace(oi)
    }
    return <- owners
}

def private emit_handles_boost(reg : VkRegistry; em : EmitModel; out_dir : string; owners : array<OwnerInfo>) {
    fopen("{out_dir}/vulkan_handles.das", "wb") $(f) {
        panic("can't write vulkan_handles.das") if (f == null)
        fprint(f, GEN_HEADER)
        fprint(f, "options gen2\noptions indenting = 4\n\nmodule vulkan_handles\n\n")
        fprint(f, "require vulkan public\nrequire vulkan/vulkan_runtime public\n\n")
        for (oi in owners) {
            // wrapper struct -- handles stored as uint64 (their ABI form) so wrapper
            // copies are friction-free; reinterpret to the typed handle at the boundary.
            fprint(f, "struct {oi.boost} \{\n")
            fprint(f, "    _vk : uint64\n")
            fprint(f, "    _needs_delete : bool\n")
            for (pf in oi.parents) {
                fprint(f, "    {pf.field} : uint64\n")
            }
            fprint(f, "\}\n")
            // finalize
            fprint(f, "def finalize(var self : {oi.boost}) \{\n")
            if (!empty(oi.destroyer) && !oi.pool_owned) {
                fprint(f, "    if (self._needs_delete) \{\n")
                fprint(f, "        unsafe \{\n")
                fprint(f, "            {oi.destroyer}(")
                for (pf in oi.parents) {
                    fprint(f, "reinterpret<{pf.vktype}>(self.{pf.field}), ")
                }
                fprint(f, "reinterpret<{oi.handle}>(self._vk), null)\n")
                fprint(f, "        \}\n")
                fprint(f, "    \}\n")
            }
            fprint(f, "    self._needs_delete = false\n")
            fprint(f, "\}\n")
            // conversions
            fprint(f, "def boost_value_to_vk(self : {oi.boost}) : {oi.handle} \{ return unsafe(reinterpret<{oi.handle}>(self._vk)) \}\n")
            fprint(f, "def vk_value_to_boost(v : {oi.handle}) : {oi.boost} \{ var b : {oi.boost}; b._vk = unsafe(reinterpret<uint64>(v)); return b \}\n\n")
        }
    }
    to_log(LOG_INFO, "boost: {length(owners)} handle wrappers -> vulkan_handles.das\n")
}

// ===== vk_view: idiomatic boost structs with array<T> fields + transient C view =====

enum FieldKind {
    erase           //! sType / count member -- not a boost field; vk_view derives it
    next_ptr        //! pNext -> boost `next : void?`
    scalar          //! scalar / enum / flags / nested-POD / fixed-array -- direct copy
    boost_handle    //! handle by value -> boost handle type
    str             //! const char* -> string
    arr_scalar      //! count+ptr of scalar/enum -> array<T>
    arr_handle      //! count+ptr of handle -> array<BoostHandle>
    hard            //! unmappable -> skip the whole struct
}

struct BoostField {
    kind : FieldKind
    name : string           //! das-safe boost field name
    raw_name : string       //! original C member name (the raw struct field)
    boost_type : string     //! the boost field's das type
    elem_vktype : string    //! for arrays: the raw element type (VkSemaphore / uint32_t)
    elem_boost : string     //! for arrays: the boost element type
    count_member : string   //! for arrays: the raw count member name
    is_handle_elem : bool
}

//! names of members that are the count for some array member (len=thatName)
def private count_members_of(s : VkStructDef) : table<string> {
    var counts : table<string>
    for (m in s.members) {
        continue if (empty(m.len))
        // simple identifier len that names another member
        for (other in s.members) {
            if (other.name == m.len) {
                counts |> insert(m.len)
            }
        }
    }
    return <- counts
}

def private elem_is_handle(em : EmitModel; tn : string) : bool {
    return key_exists(em.handle_names, tn)
}

//! map a struct member to a boost field; FieldKind.hard signals "skip the whole struct"
def private classify_field(reg : VkRegistry; em : EmitModel; s : VkStructDef; m : VkMember; counts : table<string>) : BoostField {
    var bf = BoostField(name = das_safe_name(m.name), raw_name = m.name)
    let tn = m.type_name
    if (m.name == "sType" && !empty(m.stype_value)) {
        bf.kind = FieldKind.erase
        return <- bf
    }
    if (m.name == "pNext") {
        // only plain `const void* pNext` becomes the `next` escape; typed self-pointers
        // (VkBaseInStructure/VkBaseOutStructure) are meta-structs -> skip
        if (tn == "void") {
            bf.kind = FieldKind.next_ptr
            bf.name = "next"
        } else {
            bf.kind = FieldKind.hard
        }
        return <- bf
    }
    if (key_exists(counts, m.name)) {
        bf.kind = FieldKind.erase
        return <- bf
    }
    // function pointers, fixed-arrays, multi-pointers -> hard
    if (key_exists(reg.func_pointers, tn)) {
        bf.kind = FieldKind.hard
        return <- bf
    }
    if (length(m.arr_dims) > 0) {
        bf.kind = FieldKind.hard      // inline fixed-array members: defer
        return <- bf
    }
    // arrays: a len that names a count member
    let has_count = !empty(m.len) && key_exists(counts, m.len)
    if (has_count && m.num_ptrs == 1 && tn != "void" && tn != "char") {
        bf.count_member = m.len
        if (elem_is_handle(em, tn)) {
            bf.kind = FieldKind.arr_handle
            bf.elem_boost = boost_name(tn)
            bf.boost_type = "array<{bf.elem_boost}>"
            bf.elem_vktype = tn               // raw handle das type (e.g. VkSemaphore)
            bf.is_handle_elem = true
        } else {
            let ds = DAS_SCALAR_MAP?[tn] ?? ""
            if (!empty(ds)) {
                bf.kind = FieldKind.arr_scalar
                bf.boost_type = "array<{ds}>"
                bf.elem_vktype = ds           // scratch holds the same das scalar
            } else {
                bf.kind = FieldKind.hard      // array of struct / enum / flags -> defer
            }
        }
        return <- bf
    }
    // string
    if (tn == "char" && m.num_ptrs == 1) {
        bf.kind = FieldKind.str
        bf.boost_type = "string"
        return <- bf
    }
    // any remaining pointer -> hard (single struct ptr, void*, string arrays, scalar ptr)
    if (m.num_ptrs >= 1) {
        bf.kind = FieldKind.hard
        return <- bf
    }
    // by-value handle
    if (elem_is_handle(em, tn)) {
        bf.kind = FieldKind.boost_handle
        bf.boost_type = boost_name(tn)
        return <- bf
    }
    // by-value scalar / enum / flags / nested POD struct / base type -> direct copy (raw type kept)
    bf.kind = FieldKind.scalar
    bf.boost_type = scalar_field_type(reg, em, m)
    return <- bf
}

//! the das type of a by-value scalar/enum/flags/nested field, as the boost struct should declare it
def private scalar_field_type(reg : VkRegistry; em : EmitModel; m : VkMember) : string {
    let tn = m.type_name
    let direct = DAS_SCALAR_MAP?[tn] ?? ""
    if (!empty(direct)) {
        return direct
    }
    let fi = em.flags_lookup?[tn] ?? FlagsInfo()
    if (fi.kind != FlagsKind.not_flags) {
        return fi.canonical          // the bitfield alias
    }
    let bt = reg.base_types?[tn] ?? ""
    let via_base = DAS_SCALAR_MAP?[bt] ?? ""
    if (!empty(via_base)) {
        return via_base
    }
    return tn                          // enum / nested struct / VkBool32-style typedef
}

struct ViewStruct {
    s_index : int
    boost : string
    fields : array<BoostField>
}

def public derive_views(reg : VkRegistry; em : EmitModel; var skip_log : array<string>) : array<ViewStruct> {
    var views : array<ViewStruct>
    for (s, idx in reg.structs, range(length(reg.structs))) {
        continue if (!empty(s.alias))
        continue if (!key_exists(em.struct_emit, s.name))
        continue if (!empty(s.protect))
        continue if (s.is_union)            // unions: defer
        let counts = count_members_of(s)
        var vs = ViewStruct(s_index = idx, boost = boost_name(s.name))
        var hard = false
        for (m in s.members) {
            var bf <- classify_field(reg, em, s, m, counts)
            if (bf.kind == FieldKind.hard) {
                hard = true
                skip_log |> push("{s.name}: member {m.name} ({m.type_name} x{m.num_ptrs}) not mappable")
                break
            }
            vs.fields |> emplace(bf)
        }
        continue if (hard)
        views |> emplace(vs)
    }
    return <- views
}

def private emit_structs_boost(reg : VkRegistry; em : EmitModel; out_dir : string; views : array<ViewStruct>) {
    fopen("{out_dir}/vulkan_structs.das", "wb") $(f) {
        panic("can't write vulkan_structs.das") if (f == null)
        fprint(f, GEN_HEADER)
        fprint(f, "options gen2\noptions indenting = 4\n\nmodule vulkan_structs\n\n")
        fprint(f, "require vulkan public\nrequire vulkan/vulkan_ctors public\nrequire vulkan/vulkan_handles public\nrequire vulkan/vulkan_runtime public\n\n")
        for (vs in views) {
            let s & = unsafe(reg.structs[vs.s_index])
            // boost struct
            fprint(f, "struct {vs.boost} \{\n")
            for (bf in vs.fields) {
                if (bf.kind == FieldKind.erase) {
                    continue
                }
                if (bf.kind == FieldKind.next_ptr) {
                    fprint(f, "    next : void?\n")
                } else {
                    fprint(f, "    {bf.name} : {bf.boost_type}\n")
                }
            }
            // scratch arrays for the array fields
            for (bf in vs.fields) {
                if (bf.kind == FieldKind.arr_scalar || bf.kind == FieldKind.arr_handle) {
                    fprint(f, "    _vk_view_{bf.name} : array<{bf.elem_vktype}>\n")
                }
            }
            fprint(f, "\}\n")
            // vk_view_create_unsafe
            fprint(f, "def vk_view_create_unsafe(var b : {vs.boost}) : {s.name} \{\n")
            fprint(f, "    var vk = {s.name}()\n")
            // raw struct das field names are das_safe_name'd (same as the boost field name);
            // count members likewise.
            for (bf in vs.fields) {
                let cm = das_safe_name(bf.count_member)
                if (bf.kind == FieldKind.scalar) {
                    fprint(f, "    vk.{bf.name} = b.{bf.name}\n")
                } elif (bf.kind == FieldKind.boost_handle) {
                    fprint(f, "    vk.{bf.name} = boost_value_to_vk(b.{bf.name})\n")
                } elif (bf.kind == FieldKind.str) {
                    fprint(f, "    vk.{bf.name} = b.{bf.name}\n")
                } elif (bf.kind == FieldKind.next_ptr) {
                    fprint(f, "    vk.pNext = b.next\n")
                } elif (bf.kind == FieldKind.arr_scalar) {
                    fprint(f, "    b._vk_view_{bf.name} := b.{bf.name}\n")
                    fprint(f, "    vk.{cm} = uint(length(b.{bf.name}))\n")
                    fprint(f, "    vk.{bf.name} = array_addr(b._vk_view_{bf.name})\n")
                } elif (bf.kind == FieldKind.arr_handle) {
                    fprint(f, "    b._vk_view_{bf.name} <- [for (h in b.{bf.name}); boost_value_to_vk(h)]\n")
                    fprint(f, "    vk.{cm} = uint(length(b.{bf.name}))\n")
                    fprint(f, "    vk.{bf.name} = array_addr(b._vk_view_{bf.name})\n")
                }
            }
            fprint(f, "    return <- vk\n")
            fprint(f, "\}\n")
            // vk_view_destroy: free the scratch arrays
            fprint(f, "def vk_view_destroy(var b : {vs.boost}) \{\n")
            var any_scratch = false
            for (bf in vs.fields) {
                if (bf.kind == FieldKind.arr_handle) {
                    fprint(f, "    unsafe \{ delete b._vk_view_{bf.name} \}\n")    // array of handle pointers
                    any_scratch = true
                } elif (bf.kind == FieldKind.arr_scalar) {
                    fprint(f, "    delete b._vk_view_{bf.name}\n")
                    any_scratch = true
                }
            }
            if (!any_scratch) {
                fprint(f, "    pass\n")
            }
            fprint(f, "\}\n\n")
        }
    }
    to_log(LOG_INFO, "boost: {length(views)} vk_view structs -> vulkan_structs.das\n")
}

// ===== commands: generated creators (RAII create_X returning an owning wrapper) =====

struct CreatorInfo {
    command : string            //! vkCreateImage
    fn_name : string            //! create_image
    handle : string             //! VkImage
    boost : string              //! Image
    create_info_boost : string  //! ImageCreateInfo
    creator_params : array<ParentField>  //! the creator's leading handle params (call + signature)
    store_parents : array<ParentField>   //! the destroyer's parents, stored in the wrapper for finalize
}

//! snake_case a vkCreateImage / vkAllocateMemory name -> create_image / allocate_memory
def private command_fn_name(vkname : string) : string {
    var body = vkname
    if (body |> starts_with("vk")) {
        body = body |> slice(2)
    }
    return camel_to_snake(body)
}

def private camel_to_snake(s : string) : string {
    return build_string() $(var w) {
        peek_data(s) $(arr) {
            for (i in range(length(arr))) {
                let c = int(arr[i])
                let up = c >= 'A' && c <= 'Z'
                if (up && i > 0) {
                    w |> write_char('_')
                }
                w |> write_char(up ? c - 'A' + 'a' : c)
            }
        }
    }
}

def private derive_creators(reg : VkRegistry; em : EmitModel; owners : array<OwnerInfo>; views : array<ViewStruct>) : array<CreatorInfo> {
    // index owners by handle name, and the set of emitted view struct (vk) names
    var owner_of : table<string; int>
    for (oi, i in owners, range(length(owners))) {
        owner_of[oi.handle] = i
    }
    var view_set : table<string>
    for (vs in views) {
        view_set |> insert(reg.structs[vs.s_index].name)
    }
    var creators : array<CreatorInfo>
    for (c in reg.commands) {
        continue if (!empty(c.alias))
        continue if (!key_exists(reg.enabled_commands, c.name))
        continue if (!empty(c.protect))
        continue if (!(c.name |> starts_with("vkCreate")) && !(c.name |> starts_with("vkAllocate")))
        // single out-handle (no len -> not a batch), a create-info struct, leading handle parents
        var out_handle = ""
        var batch = false
        var ci_vk = ""
        var creator_params : array<ParentField>
        for (p in c.params) {
            if (key_exists(em.handle_names, p.type_name) && p.num_ptrs >= 1) {
                out_handle = p.type_name
                if (!empty(p.len)) {
                    batch = true
                }
            } elif (key_exists(em.handle_names, p.type_name) && p.num_ptrs == 0) {
                creator_params |> emplace(ParentField(field = "_{das_safe_name(p.name)}", vktype = p.type_name))
            } elif (key_exists(view_set, p.type_name) && p.num_ptrs == 1) {
                ci_vk = p.type_name
            }
        }
        continue if (empty(out_handle) || batch || empty(ci_vk))
        let oidx = owner_of?[out_handle] ?? -1
        continue if (oidx < 0)
        let oi & = unsafe(owners[oidx])
        var info = CreatorInfo(
            command = c.name,
            fn_name = command_fn_name(c.name),
            handle = out_handle,
            boost = oi.boost,
            create_info_boost = boost_name(ci_vk)
        )
        info.creator_params <- creator_params
        info.store_parents := oi.parents
        creators |> emplace(info)
    }
    return <- creators
}

def private param_name_of(field : string) : string {
    // wrapper field "_device" -> param "device"
    if (field |> starts_with("_")) {
        return field |> slice(1)
    }
    return field
}

def private emit_commands_boost(reg : VkRegistry; em : EmitModel; out_dir : string; creators : array<CreatorInfo>) {
    fopen("{out_dir}/vulkan_commands.das", "wb") $(f) {
        panic("can't write vulkan_commands.das") if (f == null)
        fprint(f, GEN_HEADER)
        fprint(f, "options gen2\noptions indenting = 4\n\nmodule vulkan_commands\n\n")
        fprint(f, "require vulkan public\nrequire vulkan/vulkan_handles public\nrequire vulkan/vulkan_structs public\nrequire vulkan/vulkan_runtime public\nrequire daslib/defer\n\n")
        for (ci in creators) {
            // signature: creator's leading handle params (boost) + create_info + optional result
            fprint(f, "def {ci.fn_name}(")
            for (pf in ci.creator_params) {
                fprint(f, "{param_name_of(pf.field)} : {boost_name(pf.vktype)}; ")
            }
            fprint(f, "var create_info : {ci.create_info_boost}; var result : VkResult? = null) : {ci.boost} \{\n")
            fprint(f, "    var vci = vk_view_create_unsafe(create_info)\n")
            fprint(f, "    defer() \{ vk_view_destroy(create_info) \}\n")
            fprint(f, "    var h : {ci.handle}\n")
            fprint(f, "    vk_check({ci.command}(")
            for (pf in ci.creator_params) {
                fprint(f, "boost_value_to_vk({param_name_of(pf.field)}), ")
            }
            fprint(f, "vci, null, h), result)\n")
            fprint(f, "    var b = vk_value_to_boost(h)\n")
            fprint(f, "    b._needs_delete = true\n")
            // store the destroyer's parents (matched to a creator param of the same type)
            for (sp in ci.store_parents) {
                for (cp in ci.creator_params) {
                    if (cp.vktype == sp.vktype) {
                        fprint(f, "    b.{sp.field} = unsafe(reinterpret<uint64>(boost_value_to_vk({param_name_of(cp.field)})))\n")
                        break
                    }
                }
            }
            fprint(f, "    return <- b\n")
            fprint(f, "\}\n\n")
        }
    }
    to_log(LOG_INFO, "boost: {length(creators)} creators -> vulkan_commands.das\n")
}

// ===== orchestrator =====

def public emit_boost(reg : VkRegistry; var em : EmitModel; out_dir : string) {
    var skip_log : array<string>
    emit_ctors(reg, em, out_dir)
    let owners <- derive_owners(reg, em)
    emit_handles_boost(reg, em, out_dir, owners)
    let views <- derive_views(reg, em, skip_log)
    emit_structs_boost(reg, em, out_dir, views)
    let creators <- derive_creators(reg, em, owners, views)
    emit_commands_boost(reg, em, out_dir, creators)
    to_log(LOG_INFO, "boost: {length(skip_log)} structs skipped (composite/unmappable members)\n")
}
