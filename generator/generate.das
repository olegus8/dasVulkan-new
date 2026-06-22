options gen2
options indenting = 4

require daslib/clargs
require vk_model
require vk_emit
require vk_emit_boost

[CommandLineArgs]
struct Config {
    @clarg_doc = "path to vk.xml (default: vendor/Vulkan-Headers/registry/vk.xml)"
    xml : string
    @clarg_doc = "output directory for generated C++ sources (default: src)"
    out : string
    @clarg_doc = "output directory for generated boost daslang (default: daslib)"
    boost_out : string
    @clarg_doc = "skip C++ emission; regenerate only the boost daslang (fast boost iteration)"
    no_cpp : bool
    @clarg_doc = "print registry statistics and exit"
    stats : bool
    @clarg_short = "?"
    @clarg_name = "show-help"
    @clarg_doc = "Show this help and exit"
    help : bool
}

def dump_stats(reg : VkRegistry) {
    var enabled_structs = 0
    var alias_structs = 0
    for (s in reg.structs) {
        if (!empty(s.alias)) {
            alias_structs++
        } elif (key_exists(reg.enabled_types, s.name)) {
            enabled_structs++
        }
    }
    var enabled_cmds = 0
    var alias_cmds = 0
    for (c in reg.commands) {
        if (!empty(c.alias)) {
            alias_cmds++
        } elif (key_exists(reg.enabled_commands, c.name)) {
            enabled_cmds++
        }
    }
    var total_enum_entries = 0
    var bitmask_enums = 0
    for (e in reg.enums) {
        total_enum_entries += length(e.entries)
        if (e.is_bitmask) {
            bitmask_enums++
        }
    }
    to_log(LOG_INFO, "vendor tags:      {length(reg.vendor_tags)}\n")
    to_log(LOG_INFO, "platforms:        {length(reg.platform_protect)}\n")
    to_log(LOG_INFO, "base types:       {length(reg.base_types)}\n")
    to_log(LOG_INFO, "func pointers:    {length(reg.func_pointers)}\n")
    to_log(LOG_INFO, "handles:          {length(reg.handles)}\n")
    to_log(LOG_INFO, "enums:            {length(reg.enums)} ({bitmask_enums} bitmask), {total_enum_entries} entries\n")
    to_log(LOG_INFO, "bitmask typedefs: {length(reg.bitmasks)}\n")
    to_log(LOG_INFO, "structs/unions:   {length(reg.structs)} ({alias_structs} aliases, {enabled_structs} enabled)\n")
    to_log(LOG_INFO, "commands:         {length(reg.commands)} ({alias_cmds} aliases, {enabled_cmds} enabled)\n")
    to_log(LOG_INFO, "constants:        {length(reg.constants)}\n")
    to_log(LOG_INFO, "enabled types:    {length(reg.enabled_types)}\n")
    to_log(LOG_INFO, "enabled commands: {length(reg.enabled_commands)}\n")
}

[export]
def main() : int {
    var r <- parse_args(type<Config>)
    if (r |> is_err()) {
        to_log(LOG_ERROR, "error: {r |> unwrap_err()}\n\n")
        print_help(get_command_info(type<Config>), "generate")
        return 1
    }
    let cfg <- r |> move_unwrap()
    if (cfg.help) {
        print_help(get_command_info(type<Config>), "generate")
        return 0
    }
    let xml_path = empty(cfg.xml) ? "vendor/Vulkan-Headers/registry/vk.xml" : cfg.xml
    let reg <- parse_vk_xml(xml_path)
    dump_stats(reg)
    if (cfg.stats) {
        return 0
    }
    let out_dir = empty(cfg.out) ? "src" : cfg.out
    let boost_dir = empty(cfg.boost_out) ? "daslib" : cfg.boost_out
    let em <- build_emit_model(reg)
    if (!cfg.no_cpp) {
        emit_all(reg, em, out_dir)
    }
    emit_boost(reg, em, boost_dir)
    return 0
}
