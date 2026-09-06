include_guard(GLOBAL)
if(NOT MSVC OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "Compiled VU integration tests currently require MSVC x64")
endif()
set(probe_source "${CMAKE_CURRENT_LIST_DIR}")
get_filename_component(play_root "${probe_source}/../../.tools/Play-VU" ABSOLUTE)
set(probe_build "${play_root}/out/vu-probe")
if(NOT EXISTS "${probe_build}/CMakeCache.txt")
    message(FATAL_ERROR "Configure the pinned standalone Play VU probe first")
endif()

# Reuse its small core libraries, but compile the runtime-facing translation units
# with the real runtime's conditional class layout. Do not import its bridge.lib.
add_custom_target(play_vu_session_refresh
    COMMAND "${CMAKE_COMMAND}" --build "${probe_build}" --config "$<CONFIG>"
        --target play_vu_session --parallel 1
    VERBATIM)
foreach(component IN ITEMS play_vu_session play_vu_core Framework CodeGen)
    add_library(integration_${component} STATIC IMPORTED GLOBAL)
    if(component STREQUAL "CodeGen")
        set(lib_dir "${probe_build}/CodeGen")
    else()
        set(lib_dir "${probe_build}")
    endif()
    foreach(config IN ITEMS Debug Release RelWithDebInfo MinSizeRel)
        string(TOUPPER "${config}" config_upper)
        set_property(TARGET integration_${component} APPEND PROPERTY IMPORTED_CONFIGURATIONS "${config}")
        set_target_properties(integration_${component} PROPERTIES
            IMPORTED_LOCATION_${config_upper} "${lib_dir}/${config}/${component}.lib")
    endforeach()
endforeach()

add_library(play_vu_runtime_adapter STATIC
    "${probe_source}/runtime_adapter.cpp" "${probe_source}/runtime_bridge.cpp")
add_dependencies(play_vu_runtime_adapter play_vu_session_refresh)
target_compile_features(play_vu_runtime_adapter PRIVATE cxx_std_20)
target_compile_options(play_vu_runtime_adapter PRIVATE /MP1)
target_compile_definitions(play_vu_runtime_adapter PRIVATE
    _CRT_SECURE_NO_WARNINGS _SCL_SECURE_NO_WARNINGS _ENABLE_EXTENDED_ALIGNED_STORAGE LOGGING_ENABLED=0
    $<TARGET_PROPERTY:ps2_runtime,INTERFACE_COMPILE_DEFINITIONS>)
# The runtime's parent include directory shadows Framework's Types.h on Windows.
target_include_directories(play_vu_runtime_adapter PRIVATE
    "${CMAKE_SOURCE_DIR}/ps2xRuntime/include/runtime"
    "${play_root}/Source" "${play_root}/deps/Framework/include"
    "${play_root}/deps/CodeGen/include"
    "${CMAKE_SOURCE_DIR}/ps2xRuntime/include")
target_link_libraries(play_vu_runtime_adapter PRIVATE integration_play_vu_session
    integration_play_vu_core integration_CodeGen integration_Framework)
