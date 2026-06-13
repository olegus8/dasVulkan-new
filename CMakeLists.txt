cmake_minimum_required(VERSION 3.16)
project(dasVulkan CXX C)

# DASLANG_DIR must point to the daslang SDK root
if(NOT DEFINED DASLANG_DIR)
    message(FATAL_ERROR "DASLANG_DIR must be set to the daslang SDK root")
endif()

SET(DAS_VULKAN_DIR ${CMAKE_CURRENT_LIST_DIR})
SET(VULKAN_HEADERS_INCLUDE ${DAS_VULKAN_DIR}/vendor/Vulkan-Headers/include)
SET(VOLK_DIR ${DAS_VULKAN_DIR}/vendor/volk)

# generated binding sources (produced by generator/generate.das). The chunk count
# varies with the bound-surface size, so glob — delete src/dasVULKAN.gen_*.cpp
# before regenerating, then re-run CMake configure so this glob re-evaluates.
file(GLOB DAS_VULKAN_GEN_SRC "${DAS_VULKAN_DIR}/src/dasVULKAN.gen_*.cpp")
SET(DAS_VULKAN_SRC
    ${DAS_VULKAN_DIR}/src/dasVULKAN.main.cpp
    ${DAS_VULKAN_GEN_SRC}
    ${VOLK_DIR}/volk.c
)

add_library(dasModuleVulkan SHARED ${DAS_VULKAN_SRC})
target_compile_features(dasModuleVulkan PRIVATE cxx_std_17)
target_compile_definitions(dasModuleVulkan PRIVATE
    DAS_MOD_EXPORTS DAS_ENABLE_DLL=1
    VK_NO_PROTOTYPES
    $<$<CONFIG:Release>:DAS_NO_ASSERTIONS>
    $<$<CONFIG:MinSizeRel>:DAS_NO_ASSERTIONS>
    $<$<CONFIG:RelWithDebInfo>:DAS_NO_ASSERTIONS>
)
if(WIN32)
    target_compile_definitions(dasModuleVulkan PRIVATE VK_USE_PLATFORM_WIN32_KHR)
elseif(APPLE)
    target_compile_definitions(dasModuleVulkan PRIVATE VK_USE_PLATFORM_METAL_EXT)
else()
    target_compile_definitions(dasModuleVulkan PRIVATE VK_USE_PLATFORM_XLIB_KHR VK_USE_PLATFORM_WAYLAND_KHR)
endif()
target_include_directories(dasModuleVulkan PRIVATE
    ${DASLANG_DIR}/include
    ${VULKAN_HEADERS_INCLUDE}
    ${VOLK_DIR}
    ${DAS_VULKAN_DIR}/src
)
if(WIN32)
    if(EXISTS "${DASLANG_DIR}/lib/Release/libDaScriptDyn.lib")
        target_link_libraries(dasModuleVulkan PRIVATE
            ${DASLANG_DIR}/lib/Release/libDaScriptDyn.lib
            ${DASLANG_DIR}/lib/Release/libDaScriptDyn_runtime.lib
        )
    else()
        target_link_libraries(dasModuleVulkan PRIVATE
            ${DASLANG_DIR}/lib/libDaScriptDyn.lib
            ${DASLANG_DIR}/lib/libDaScriptDyn_runtime.lib
        )
    endif()
elseif(APPLE)
    target_link_libraries(dasModuleVulkan PRIVATE
        ${DASLANG_DIR}/lib/liblibDaScriptDyn.dylib
        ${DASLANG_DIR}/lib/liblibDaScriptDyn_runtime.dylib
    )
else()
    target_link_libraries(dasModuleVulkan PRIVATE
        ${DASLANG_DIR}/lib/liblibDaScriptDyn.so
        ${DASLANG_DIR}/lib/liblibDaScriptDyn_runtime.so
    )
endif()
if(MSVC)
    target_compile_options(dasModuleVulkan PRIVATE /wd4005 /bigobj)
else()
    # daslang runtime libs are built -fno-rtti for optimized configs; match the ABI
    # or the .shared_module mislinks.
    target_compile_options(dasModuleVulkan PRIVATE
        $<$<CONFIG:Release>:-fno-rtti>
        $<$<CONFIG:MinSizeRel>:-fno-rtti>
        $<$<CONFIG:RelWithDebInfo>:-fno-rtti>)
endif()
set_target_properties(dasModuleVulkan PROPERTIES
    SUFFIX ".shared_module"
    PREFIX ""
    RUNTIME_OUTPUT_DIRECTORY_RELEASE "${DAS_VULKAN_DIR}"
    LIBRARY_OUTPUT_DIRECTORY "${DAS_VULKAN_DIR}"
)
