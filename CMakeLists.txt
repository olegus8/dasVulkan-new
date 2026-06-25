IF((NOT DAS_VULKAN_INCLUDED) AND ((NOT ${DAS_VULKAN_DISABLED}) OR (NOT DEFINED DAS_VULKAN_DISABLED)))
    SET(DAS_VULKAN_INCLUDED TRUE)
    MESSAGE(STATUS "dasVulkan module included.")
    SET(DAS_VULKAN_DIR ${CMAKE_SOURCE_DIR}/modules/dasVulkan)
    SET(VULKAN_HEADERS_INCLUDE ${DAS_VULKAN_DIR}/vendor/Vulkan-Headers/include)
    SET(VOLK_DIR ${DAS_VULKAN_DIR}/vendor/volk)

    # Generated binding sources (produced by generator/generate.das). The chunk
    # count varies with the bound-surface size, so glob -- delete
    # src/dasVULKAN.gen_*.cpp before regenerating, then re-run CMake configure
    # so this glob re-evaluates.
    FILE(GLOB DAS_VULKAN_GEN_SRC "${DAS_VULKAN_DIR}/src/dasVULKAN.gen_*.cpp")
    SET(DAS_VULKAN_MODULE_SRC
        ${DAS_VULKAN_DIR}/src/dasVULKAN.main.cpp
        ${DAS_VULKAN_GEN_SRC}
        ${VOLK_DIR}/volk.c
    )
    IF(APPLE)
        # Objective-C++ TU bridging NSWindow -> CAMetalLayer for the MoltenVK
        # surface; isolated so Cocoa/QuartzCore stay out of the plain-C++ TUs.
        LIST(APPEND DAS_VULKAN_MODULE_SRC ${DAS_VULKAN_DIR}/src/dasVULKAN.metal.mm)
    ENDIF()

    # Static lib links into the app via ${DAS_MODULES_LIBS}; ADD_MODULE_CPP
    # emits NEED/DECLARE/PULL(Module_dasVULKAN) so the app needs no manual
    # registration, and each ADD_MODULE_DAS registers a boost path so
    # `require vulkan/<name>` resolves in-tree (getDasRoot()/modules/
    # dasVulkan/daslib/<name>.das).  Mirrors the 13 paths the .das_module
    # registers for the DLL/daspkg flow, minus register_dynamic_module.
    ADD_MODULE_CPP(dasVULKAN)
    ADD_MODULE_DAS(vulkan daslib vulkan_runtime)
    ADD_MODULE_DAS(vulkan daslib vulkan_ctors)
    ADD_MODULE_DAS(vulkan daslib vulkan_handles)
    ADD_MODULE_DAS(vulkan daslib vulkan_structs)
    ADD_MODULE_DAS(vulkan daslib vulkan_commands)
    ADD_MODULE_DAS(vulkan daslib vulkan_cmds)
    ADD_MODULE_DAS(vulkan daslib vulkan_boost)
    ADD_MODULE_DAS(vulkan daslib vulkan_window)
    ADD_MODULE_DAS(vulkan daslib vulkan_reflect)
    ADD_MODULE_DAS(vulkan daslib vulkan_lint_data)
    ADD_MODULE_DAS(vulkan daslib vulkan_lint)
    ADD_MODULE_DAS(vulkan daslib spirv_vulkan_shader)
    ADD_MODULE_DAS(vulkan daslib vulkan_assets)
    ADD_MODULE_LIB(libDasModuleVulkan dasModuleVulkan ${DAS_VULKAN_MODULE_SRC})

    MACRO(SETUP_VULKAN vulkan_mod_lib)
        TARGET_INCLUDE_DIRECTORIES(${vulkan_mod_lib} PRIVATE
            ${VULKAN_HEADERS_INCLUDE}
            ${VOLK_DIR}
            ${DAS_VULKAN_DIR}/src
        )
        TARGET_COMPILE_DEFINITIONS(${vulkan_mod_lib} PRIVATE VK_NO_PROTOTYPES)
        IF(WIN32)
            TARGET_COMPILE_DEFINITIONS(${vulkan_mod_lib} PRIVATE VK_USE_PLATFORM_WIN32_KHR)
        ELSEIF(APPLE)
            TARGET_COMPILE_DEFINITIONS(${vulkan_mod_lib} PRIVATE VK_USE_PLATFORM_METAL_EXT)
        ELSE()
            TARGET_COMPILE_DEFINITIONS(${vulkan_mod_lib} PRIVATE VK_USE_PLATFORM_XLIB_KHR VK_USE_PLATFORM_WAYLAND_KHR)
        ENDIF()
        IF(MSVC)
            TARGET_COMPILE_OPTIONS(${vulkan_mod_lib} PRIVATE /bigobj /wd4005)
        ENDIF()
        SETUP_CPP11(${vulkan_mod_lib})
    ENDMACRO()
    SETUP_VULKAN(libDasModuleVulkan)
    SETUP_VULKAN(dasModuleVulkan)
    IF(APPLE)
        TARGET_LINK_LIBRARIES(libDasModuleVulkan PUBLIC "-framework Cocoa" "-framework QuartzCore")
        TARGET_LINK_LIBRARIES(dasModuleVulkan PUBLIC "-framework Cocoa" "-framework QuartzCore")
    ENDIF()

    # The engine authors its shaders in GLSL, so it needs a GLSL -> SPIR-V
    # step.  Boris's dasVulkan compiles daScript shaders and ships no such
    # macro, so DAS_VULKAN_COMPILE_SHADER is ours: the generated app CMake
    # calls it per shader.  It drives the Vulkan SDK tools found on PATH;
    # the binding itself never touches the SDK (vendored headers + volk).
    FIND_PROGRAM(DAS_VULKAN_GLSLANG_VALIDATOR_EXE glslangValidator)
    FIND_PROGRAM(DAS_VULKAN_SPIRV_OPT_EXE spirv-opt)
    FIND_PROGRAM(DAS_VULKAN_SPIRV_DIS_EXE spirv-dis)

    MACRO(DAS_VULKAN_COMPILE_SHADER input extra_deps)
        CMAKE_PARSE_ARGUMENTS(DS "" ""
            "GLSLANG_PRE_ARGS;GLSLANG_ARGS;SPIRV_OPT_ARGS" ${ARGN})
        get_filename_component(input_src ${input} ABSOLUTE)
        get_filename_component(input_dir ${input_src} DIRECTORY)
        get_filename_component(input_name ${input} NAME_WE)
        get_filename_component(input_name_ext ${input} NAME)
        # Preprocessed GLSL, kept for inspection.  glslangValidator -E
        # writes to stdout, so redirect it (hence no VERBATIM here).
        ADD_CUSTOM_COMMAND(
            DEPENDS ${input_src} ${extra_deps}
            OUTPUT ${input_dir}/${input_name}.pre.glsl
            WORKING_DIRECTORY ${input_dir}
            USES_TERMINAL
            COMMAND_EXPAND_LISTS
            COMMAND ${DAS_VULKAN_GLSLANG_VALIDATOR_EXE} ${DS_GLSLANG_PRE_ARGS}
                ${input_name_ext} > ${input_name}.pre.glsl
            COMMENT "glslangValidator -E ${input} to ${input_name}.pre.glsl")
        ADD_CUSTOM_COMMAND(
            DEPENDS ${input_src} ${extra_deps}
            OUTPUT ${input_dir}/${input_name}.base.spv
            WORKING_DIRECTORY ${input_dir}
            VERBATIM
            USES_TERMINAL
            COMMAND_EXPAND_LISTS
            COMMAND ${DAS_VULKAN_GLSLANG_VALIDATOR_EXE} ${DS_GLSLANG_ARGS}
                ${input_name_ext} -o ${input_name}.base.spv
            COMMENT "glslangValidator ${input} to ${input_name}.base.spv")
        ADD_CUSTOM_COMMAND(
            DEPENDS ${input_dir}/${input_name}.base.spv
            OUTPUT ${input_dir}/${input_name}.base.spvasm
            WORKING_DIRECTORY ${input_dir}
            VERBATIM
            COMMAND_EXPAND_LISTS
            COMMAND ${DAS_VULKAN_SPIRV_DIS_EXE} --nested-indent --comment
                --no-color ${input_dir}/${input_name}.base.spv
                -o ${input_name}.base.spvasm
            COMMENT "spirv-dis ${input_name}.base.spv")
        ADD_CUSTOM_COMMAND(
            DEPENDS ${input_dir}/${input_name}.base.spv
            OUTPUT ${input_dir}/${input_name}.spv
            WORKING_DIRECTORY ${input_dir}
            VERBATIM
            COMMAND_EXPAND_LISTS
            COMMAND ${DAS_VULKAN_SPIRV_OPT_EXE} ${DS_SPIRV_OPT_ARGS}
                ${input_dir}/${input_name}.base.spv -o ${input_name}.spv
            COMMENT "spirv-opt ${input_name}.base.spv to ${input_name}.spv")
        ADD_CUSTOM_COMMAND(
            DEPENDS ${input_dir}/${input_name}.spv
            OUTPUT ${input_dir}/${input_name}.spvasm
            WORKING_DIRECTORY ${input_dir}
            VERBATIM
            COMMAND_EXPAND_LISTS
            COMMAND ${DAS_VULKAN_SPIRV_DIS_EXE} --nested-indent --comment
                --no-color ${input_dir}/${input_name}.spv
                -o ${input_name}.spvasm
            COMMENT "spirv-dis ${input_name}.spv")
    ENDMACRO()

    # Install the boost daslib so daspkg / DLL consumers resolve it from the
    # install tree; the static in-tree build resolves it via ADD_MODULE_DAS.
    FILE(GLOB DAS_VULKAN_DASLIB ${DAS_VULKAN_DIR}/daslib/*.das)
    INSTALL(FILES ${DAS_VULKAN_DASLIB}
        DESTINATION ${DAS_INSTALL_MODULESDIR}/dasVulkan/daslib
    )
ENDIF()
