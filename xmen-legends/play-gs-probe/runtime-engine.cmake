include_guard(GLOBAL)
if(NOT TARGET ffmpeg_zlib)
    message(FATAL_ERROR "The game Vulkan adapter requires the runtime's existing ffmpeg_zlib target")
endif()
get_filename_component(gs_probe_source "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)
get_filename_component(gs_play_root "${gs_probe_source}/../../.tools/Play-VU" ABSOLUTE)
set(gs_probe_build "${gs_play_root}/out/vu-probe")
add_custom_target(play_gs_refresh
    COMMAND "${CMAKE_COMMAND}" --build "${gs_probe_build}" --config "$<CONFIG>"
        --target play_gs_adapter --parallel 1 VERBATIM)
add_dependencies(play_gs_refresh play_vu_session_refresh)
foreach(component IN ITEMS play_gs_adapter play_gs_bridge play_gs_vulkan play_gs_support
        Framework_Vulkan Nuanceur libzstd_zlibwrapper_static zstd_static)
    set(directory "${gs_probe_build}/play-gs-probe")
    if(component STREQUAL "libzstd_zlibwrapper_static")
        string(APPEND directory "/zstd-wrapper")
    elseif(component STREQUAL "zstd_static")
        string(APPEND directory "/zstd-wrapper/zstd/lib")
    endif()
    add_library(gs_integration_${component} STATIC IMPORTED GLOBAL)
    foreach(config IN ITEMS Debug Release RelWithDebInfo MinSizeRel)
        string(TOUPPER "${config}" upper)
        set_property(TARGET gs_integration_${component} APPEND PROPERTY IMPORTED_CONFIGURATIONS "${config}")
        set_target_properties(gs_integration_${component} PROPERTIES
            IMPORTED_LOCATION_${upper} "${directory}/${config}/${component}.lib")
    endforeach()
    list(APPEND gs_integration_libraries gs_integration_${component})
endforeach()
add_library(play_gs_runtime_config STATIC "${gs_probe_source}/runtime-config.cpp")
add_dependencies(play_gs_runtime_config play_gs_refresh)
target_compile_features(play_gs_runtime_config PRIVATE cxx_std_17)
target_compile_options(play_gs_runtime_config PRIVATE /MP1)
target_include_directories(play_gs_runtime_config BEFORE PRIVATE
    "${gs_play_root}/Source/app_shared" "${gs_play_root}/deps/Framework/include")
target_link_libraries(ps2_runtime PRIVATE play_gs_runtime_config ${gs_integration_libraries}
    integration_CodeGen integration_Framework ffmpeg_zlib shell32)
set_property(SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/src/lib/gs/gs_frontend.cpp"
    APPEND PROPERTY COMPILE_DEFINITIONS PS2X_ENABLE_PLAY_GS_BACKEND=1)
