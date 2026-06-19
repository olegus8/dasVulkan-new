options gen2
options rtti = true

require daslib/fio
require daslib/rtti
require daslib/ast
require daslib/rst_comment
require daslib/rst
require daslib/regex
require daslib/regex_boost

// The ergonomic boost layer. The raw `vulkan` module mirrors the Vulkan API
// 1:1 (generated from vk.xml) and is not documented here — consult the Vulkan
// specification for those symbols. We document the daslang-specific layer:
// RAII handles, builders, block brackets, and the windowing helpers.
require vulkan/vulkan_runtime
require vulkan/vulkan_handles
require vulkan/vulkan_commands
require vulkan/vulkan_boost
require vulkan/vulkan_window

def document_module_vulkan_runtime() {
    var mod = find_module("vulkan_runtime")
    var groups <- array<DocGroup>(
        group_by_regex("Result checking", mod, %regex~^vk_check$%%),
        group_by_regex("Array interop",   mod, %regex~^array_addr$%%),
        group_by_regex("Ownership",       mod, %regex~^weak_copy$%%),
        group_by_regex("Versioning",      mod, %regex~^make_api_version$%%)
    )
    document("Runtime — result checking, array interop, ownership, versioning", mod, "vulkan_runtime.rst", groups)
}

def document_module_vulkan_handles() {
    var mod = find_module("vulkan_handles")
    // The module is 55 RAII handle-wrapper structs plus their mechanical
    // marshalling functions. The structs document themselves; hide the
    // per-handle plumbing so the page reads as a type index.
    var groups <- array<DocGroup>(
        hide_group(group_by_regex("Finalizers",  mod, %regex~^finalize$%%)),
        hide_group(group_by_regex("Marshalling", mod, %regex~^(boost_value_to_vk|vk_value_to_boost)$%%))
    )
    document("Handles — RAII ownership wrappers (one per Vulkan handle)", mod, "vulkan_handles.rst", groups)
}

def document_module_vulkan_commands() {
    var mod = find_module("vulkan_commands")
    var groups <- array<DocGroup>(
        group_by_regex("Memory",            mod, %regex~^allocate_memory$%%),
        group_by_regex("Buffers & images",  mod, %regex~^create_(buffer|buffer_view|image|image_view|sampler|sampler_ycbcr_conversion)$%%),
        group_by_regex("Pipelines & shaders", mod, %regex~^create_(pipeline_layout|shader_instrumentation_a_r_m|data_graph_pipeline_session_a_r_m)$%%),
        group_by_regex("Descriptors",       mod, %regex~^create_(descriptor_set_layout|descriptor_pool|descriptor_update_template|private_data_slot)$%%),
        group_by_regex("Render passes & framebuffers", mod, %regex~^create_(render_pass.*|framebuffer)$%%),
        group_by_regex("Commands & queries", mod, %regex~^create_(command_pool|query_pool|indirect_commands_layout_e_x_t|indirect_execution_set_e_x_t)$%%),
        group_by_regex("Synchronization",   mod, %regex~^create_(fence|semaphore|event)$%%),
        group_by_regex("Surfaces & swapchains", mod, %regex~^create_(display_mode_k_h_r|display_plane_surface_k_h_r|headless_surface_e_x_t|swapchain.*)$%%),
        group_by_regex("Acceleration & advanced", mod, %regex~^create_(acceleration_structure.*|micromap_e_x_t|optical_flow_session_n_v|external_compute_queue_n_v|cu_function_n_v_x|tensor_view_a_r_m|video_session_parameters_k_h_r)$%%)
    )
    document("Commands — RAII creators returning owning handle wrappers", mod, "vulkan_commands.rst", groups)
}

def document_module_vulkan_boost() {
    var mod = find_module("vulkan_boost")
    var groups <- array<DocGroup>(
        group_by_regex("Device selection", mod, %regex~^(select_physical_device|select_graphics_queue_family|find_memory_type)$%%),
        group_by_regex("Instance & device", mod, %regex~^(create_instance|create_device|create_device_descriptor_indexing|create_device_draw_parameters|get_device_queue|instance_extension_available)$%%),
        group_by_regex("Shaders & pipelines", mod, %regex~^(create_shader_module|create_pipeline_layout|create_graphics_pipeline_simple|create_graphics_pipeline_v3d|create_graphics_pipeline_dyn|create_compute_pipeline)$%%),
        group_by_regex("Render passes",    mod, %regex~^create_render_pass_(single_color|color_depth|depth_only)$%%),
        group_by_regex("Builders",         mod, %regex~^(build_offscreen_target|build_offscreen_depth|create_host_buffer|create_host_buffer_from_bytes|create_sampler_shadow|compute_to_storage_image)$%%),
        group_by_regex("Memory & brackets", mod, %regex~^(run_cmd_sync|record_render_pass|record_rendering|map_memory_to_array|read_memory|with_mapped_memory|write_field|upload_bytes)$%%),
        group_by_regex("Command recording", mod, %regex~^(cmd_bind_pipeline|cmd_bind_vertex_buffer|cmd_draw|cmd_push_constants|copy_image_to_buffer|transition_image|transition_depth_image|transition_image_aspect)$%%),
        group_by_regex("Conveniences",     mod, %regex~^(full_area|clear_color|clear_depth)$%%),
        hide_group(group_by_regex("Finalizers", mod, %regex~^finalize$%%))
    )
    document("Boost — selection, builders, block brackets, conveniences", mod, "vulkan_boost.rst", groups)
}

def document_module_vulkan_window() {
    var mod = find_module("vulkan_window")
    var groups <- array<DocGroup>(
        group_by_regex("Surfaces",   mod, %regex~^(create_surface|queue_family_supports_present)$%%),
        group_by_regex("Swapchain",  mod, %regex~^(create_swapchain|recreate_swapchain|build_swapchain_framebuffers)$%%),
        group_by_regex("Frame sync", mod, %regex~^create_frame_sync$%%),
        group_by_regex("Frame loop", mod, %regex~^(draw_frame|present_frame)$%%),
        hide_group(group_by_regex("Finalizers", mod, %regex~^finalize$%%))
    )
    document("Window — surface, swapchain, frame sync, and the present loop", mod, "vulkan_window.rst", groups)
}

// dasVulkan repo root, derived from a loaded module's own source path so docs
// generate correctly under both -load_module (dev) and daspkg-install (CI).
def dasvulkan_root() : string {
    let m = find_module("vulkan_boost")
    assert(m != null, "vulkan_boost not loaded — cannot locate dasVulkan root")
    return dir_name(dir_name(string(m.fileName)))
}

[export]
def main {
    ast_gc_guard() {
        let dasvulkan_doc = dasvulkan_root() + "/doc/source/stdlib"
        topic_root = "{dasvulkan_doc}/generated"
        handmade_root = dasvulkan_doc

        document_module_vulkan_runtime()
        document_module_vulkan_handles()
        document_module_vulkan_commands()
        document_module_vulkan_boost()
        document_module_vulkan_window()
    }
}
