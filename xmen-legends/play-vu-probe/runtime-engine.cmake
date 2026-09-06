include("${CMAKE_CURRENT_LIST_DIR}/runtime-library.cmake")
target_link_libraries(ps2_runtime PRIVATE play_vu_runtime_adapter)
foreach(source IN ITEMS ps2_vu1_core.cpp ps2_vu1_replay.cpp)
    set_property(SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/src/lib/vu/${source}"
        APPEND PROPERTY COMPILE_DEFINITIONS PS2X_ENABLE_VU_COMPILED_ENGINE=1)
    set_property(SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/src/lib/vu/${source}"
        APPEND PROPERTY INCLUDE_DIRECTORIES "${CMAKE_CURRENT_LIST_DIR}")
endforeach()
option(OPENXML1_PLAY_GS_BACKEND "Include the opt-in Play Vulkan GS adapter" OFF)
if(OPENXML1_PLAY_GS_BACKEND)
    include("${CMAKE_CURRENT_LIST_DIR}/../play-gs-probe/runtime-engine.cmake")
endif()
