#include "dasVULKAN.h"

namespace das {

// volk lifecycle — bound by hand; everything else dispatches through volk's
// loaded pointers and is generated.
static int32_t das_volkInitialize() {
    return int32_t(volkInitialize());
}

static uint32_t das_volkGetInstanceVersion() {
    return volkGetInstanceVersion();
}

static void das_volkLoadInstance(VkInstance instance) {
    volkLoadInstance(instance);
}

static void das_volkLoadDevice(VkDevice device) {
    volkLoadDevice(device);
}

static void das_volkFinalize() {
    volkFinalize();
}

Module_dasVULKAN::Module_dasVULKAN() : Module("vulkan") {
    DAS_PROFILE_SECTION("Module_dasVULKAN");
    ModuleLibrary lib(this);
    lib.addBuiltInModule();
    das_vulkan_init_generated(*this, lib);
    addExtern<DAS_BIND_FUN(das_volkInitialize)>(*this, lib, "volkInitialize",
        SideEffects::modifyExternal, "das_volkInitialize");
    addExtern<DAS_BIND_FUN(das_volkGetInstanceVersion)>(*this, lib, "volkGetInstanceVersion",
        SideEffects::accessExternal, "das_volkGetInstanceVersion");
    addExtern<DAS_BIND_FUN(das_volkLoadInstance)>(*this, lib, "volkLoadInstance",
        SideEffects::modifyExternal, "das_volkLoadInstance")->args({"instance"});
    addExtern<DAS_BIND_FUN(das_volkLoadDevice)>(*this, lib, "volkLoadDevice",
        SideEffects::modifyExternal, "das_volkLoadDevice")->args({"device"});
    addExtern<DAS_BIND_FUN(das_volkFinalize)>(*this, lib, "volkFinalize",
        SideEffects::modifyExternal, "das_volkFinalize");
    verifyAotReady();
}

ModuleAotType Module_dasVULKAN::aotRequire(TextWriter & tw) const {
    tw << "#include <volk.h>\n";
    return ModuleAotType::cpp;
}

}

REGISTER_MODULE_IN_NAMESPACE(Module_dasVULKAN, das);
