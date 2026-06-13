#include "dasVULKAN.h"

#if defined(_WIN32)
// volk forward-declares the Win32 handle TYPES (HWND/HINSTANCE) but does not pull
// in <windows.h>, so GetModuleHandle is unavailable here. __ImageBase is the
// linker-provided base address of this module == its HINSTANCE; use it directly.
extern "C" char __ImageBase;
#endif

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

// GLFW exposes the native window/display handles but not glfwCreateWindowSurface,
// so bridge them to a VkSurfaceKHR via the platform surface extension here. Takes
// raw void* handles (HWND / X11 Window+Display) -- no GLFW dependency. Returns the
// surface as uint64 (0 on failure); the instance must have been created with the
// matching platform surface extension enabled and volkLoadInstance already called.
static uint64_t das_vk_surface_from_native(VkInstance instance, void * native_window, void * native_display) {
    VkSurfaceKHR surface = VK_NULL_HANDLE;
#if defined(_WIN32)
    VkWin32SurfaceCreateInfoKHR ci{};
    ci.sType = VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR;
    ci.hinstance = (HINSTANCE) &__ImageBase;
    ci.hwnd = (HWND) native_window;
    if (vkCreateWin32SurfaceKHR(instance, &ci, nullptr, &surface) != VK_SUCCESS) {
        surface = VK_NULL_HANDLE;
    }
#elif defined(__linux__)
    VkXlibSurfaceCreateInfoKHR ci{};
    ci.sType = VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR;
    ci.dpy = (Display *) native_display;
    ci.window = (Window) (uintptr_t) native_window;
    if (vkCreateXlibSurfaceKHR(instance, &ci, nullptr, &surface) != VK_SUCCESS) {
        surface = VK_NULL_HANDLE;
    }
#else
    (void) instance; (void) native_window; (void) native_display;
#endif
    return (uint64_t) surface;
}

Module_dasVULKAN::Module_dasVULKAN() : Module("vulkan") {
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
    addExtern<DAS_BIND_FUN(das_vk_surface_from_native)>(*this, lib, "vk_surface_from_native",
        SideEffects::modifyExternal, "das_vk_surface_from_native")->args({"instance", "native_window", "native_display"});
    verifyAotReady();
}

ModuleAotType Module_dasVULKAN::aotRequire(TextWriter & tw) const {
    tw << "#include <volk.h>\n";
    return ModuleAotType::cpp;
}

REGISTER_DYN_MODULE(Module_dasVULKAN, Module_dasVULKAN);

}

REGISTER_MODULE_IN_NAMESPACE(Module_dasVULKAN, das);
