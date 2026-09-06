include("${CMAKE_CURRENT_LIST_DIR}/runtime-library.cmake")
get_filename_component(play_root "${CMAKE_CURRENT_LIST_DIR}/../../.tools/Play-VU" ABSOLUTE)
target_sources(ps2_test_lib PRIVATE "${CMAKE_CURRENT_LIST_DIR}/runtime_integration_tests.cpp")
target_link_libraries(ps2_test_lib PRIVATE play_vu_runtime_adapter)
set_property(SOURCE "${CMAKE_CURRENT_LIST_DIR}/runtime_integration_tests.cpp"
    APPEND PROPERTY INCLUDE_DIRECTORIES "${play_root}/Source"
        "${play_root}/deps/Framework/include" "${play_root}/deps/CodeGen/include"
        "${CMAKE_SOURCE_DIR}/ps2xRuntime/include/runtime")
set_property(SOURCE "${CMAKE_CURRENT_SOURCE_DIR}/src/ps2_vu1_tests.cpp"
    APPEND PROPERTY COMPILE_DEFINITIONS PS2X_TEST_COMPILED_VU_PRODUCER=1)
if(PS2X_VU_COMPILED_ENGINE_DIR)
    set_property(SOURCE "${CMAKE_CURRENT_LIST_DIR}/runtime_integration_tests.cpp"
        APPEND PROPERTY COMPILE_DEFINITIONS PS2X_TEST_COMPILED_VU_HOOK=1)
endif()
