cmake_minimum_required(VERSION 3.21)
project(OpenXML1PlayVuProbe LANGUAGES C CXX)

set(PLAY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.tools/Play-VU" CACHE PATH "Pinned Play! reference checkout")
function(require_revision path revision)
    execute_process(COMMAND git -C "${path}" rev-parse HEAD OUTPUT_VARIABLE actual
        OUTPUT_STRIP_TRAILING_WHITESPACE RESULT_VARIABLE status)
    if(NOT status EQUAL 0 OR NOT actual STREQUAL revision)
        message(FATAL_ERROR "Unexpected source revision in ${path}: ${actual}; expected ${revision}")
    endif()
endfunction()
require_revision("${PLAY_ROOT}" 83700b2c31e593bc94e845b4b31b797be84dda59)
require_revision("${PLAY_ROOT}/deps/CodeGen" a5009f7dca062695b8e5aebbd71e67b4ddfa9251)
require_revision("${PLAY_ROOT}/deps/Framework" 587f278917acc0026bf5fc34b39f995fc26bd015)
require_revision("${PLAY_ROOT}/deps/Dependencies" 8a5f6b1dea0b888b5a42b821e79470142bbea4e3)
require_revision("${PLAY_ROOT}/deps/Dependencies/xxHash" e626a72bc2321cd320e953a0ccf1584cad60f363)
function(require_patch path patch)
    execute_process(COMMAND git -C "${path}" apply --reverse --check
        "${CMAKE_CURRENT_SOURCE_DIR}/${patch}" RESULT_VARIABLE status ERROR_VARIABLE error)
    if(NOT status EQUAL 0)
        message(FATAL_ERROR "Apply ${patch} as documented in README.md: ${error}")
    endif()
endfunction()
require_patch("${PLAY_ROOT}/deps/CodeGen" codegen-win64-simd.patch)
require_patch("${PLAY_ROOT}" play-vu-memory-observer.patch)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
if(NOT MSVC OR NOT CMAKE_SIZEOF_VOID_P EQUAL 8)
    message(FATAL_ERROR "This isolated probe currently requires MSVC x64")
endif()
add_compile_options($<$<COMPILE_LANGUAGE:C,CXX>:/MP1>)
add_compile_definitions(_CRT_SECURE_NO_WARNINGS _SCL_SECURE_NO_WARNINGS
    _ENABLE_EXTENDED_ALIGNED_STORAGE LOGGING_ENABLED=0)

# Only stream/XML support used by the VU compiler, not media or emulator devices.
set(FRAMEWORK_ROOT "${PLAY_ROOT}/deps/Framework")
add_library(Framework STATIC
    "${FRAMEWORK_ROOT}/src/Stream.cpp"
    "${FRAMEWORK_ROOT}/src/MemStream.cpp"
    "${FRAMEWORK_ROOT}/src/PtrStream.cpp"
    "${FRAMEWORK_ROOT}/src/StdStream.cpp"
    "${FRAMEWORK_ROOT}/src/StringUtils.cpp"
    "${FRAMEWORK_ROOT}/src/xml/Node.cpp"
    "${FRAMEWORK_ROOT}/src/xml/FilteringNodeIterator.cpp")
target_include_directories(Framework PUBLIC "${FRAMEWORK_ROOT}/include")
add_subdirectory("${PLAY_ROOT}/deps/CodeGen" CodeGen EXCLUDE_FROM_ALL)

set(PLAY_SOURCE "${PLAY_ROOT}/Source")
add_library(play_vu_core STATIC
    "${PLAY_SOURCE}/BasicBlock.cpp"
    "${PLAY_SOURCE}/FpUtils.cpp"
    "${PLAY_SOURCE}/MIPS.cpp"
    "${PLAY_SOURCE}/MIPSAnalysis.cpp"
    "${PLAY_SOURCE}/MIPSArchitecture.cpp"
    "${PLAY_SOURCE}/MIPSReflection.cpp"
    "${PLAY_SOURCE}/MIPSInstructionFactory.cpp"
    "${PLAY_SOURCE}/MIPSTags.cpp"
    "${PLAY_SOURCE}/MipsJitter.cpp"
    "${PLAY_SOURCE}/MemoryMap.cpp"
    "${PLAY_SOURCE}/MemoryUtils.cpp"
    "${PLAY_SOURCE}/ee/MA_VU.cpp"
    "${PLAY_SOURCE}/ee/FpAddTruncate.cpp"
    "${PLAY_SOURCE}/ee/MA_VU_Lower.cpp"
    "${PLAY_SOURCE}/ee/MA_VU_LowerReflection.cpp"
    "${PLAY_SOURCE}/ee/MA_VU_Upper.cpp"
    "${PLAY_SOURCE}/ee/MA_VU_UpperReflection.cpp"
    "${PLAY_SOURCE}/ee/VUShared.cpp"
    "${PLAY_SOURCE}/ee/VUShared_Reflection.cpp"
    "${PLAY_SOURCE}/ee/VuBasicBlock.cpp"
    "${PLAY_SOURCE}/ee/VuExecutor.cpp"
    "${PLAY_ROOT}/deps/Dependencies/xxHash/xxhash.c")
target_include_directories(play_vu_core PUBLIC "${PLAY_SOURCE}" "${PLAY_SOURCE}/ee"
    "${PLAY_SOURCE}/app_shared" "${PLAY_ROOT}/deps/Dependencies/xxHash")
target_link_libraries(play_vu_core PUBLIC CodeGen)

set(VU_TEST_ROOT "${PLAY_ROOT}/tools/VuTest")
file(GLOB VU_TEST_SOURCES CONFIGURE_DEPENDS "${VU_TEST_ROOT}/*.cpp")
list(REMOVE_ITEM VU_TEST_SOURCES "${VU_TEST_ROOT}/Main.cpp")
enable_language(ASM_MASM)
add_library(play_vu_session STATIC compiled_session.cpp transfer_timeline.cpp scalar_flags.cpp fmac.cpp)
set_source_files_properties(fmac.cpp PROPERTIES COMPILE_OPTIONS "/fp:strict")
add_library(play_vu_fmac_avx2 OBJECT fmac.cpp)
target_link_libraries(play_vu_fmac_avx2 PRIVATE play_vu_core)
target_compile_definitions(play_vu_fmac_avx2 PRIVATE FMAC_USE_AVX2=1)
target_compile_options(play_vu_fmac_avx2 PRIVATE /arch:AVX2)
target_sources(play_vu_session PRIVATE $<TARGET_OBJECTS:play_vu_fmac_avx2>)
target_include_directories(play_vu_session PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}")
target_link_libraries(play_vu_session PUBLIC play_vu_core)
add_library(play_vu_runtime_bridge STATIC runtime_bridge.cpp)
target_compile_features(play_vu_runtime_bridge PUBLIC cxx_std_20)
# Keep the parent include directory out: its types.h shadows Framework's Types.h on Windows.
target_include_directories(play_vu_runtime_bridge PUBLIC "${CMAKE_CURRENT_SOURCE_DIR}/../../PS2Recomp/ps2xRuntime/include/runtime")
target_link_libraries(play_vu_runtime_bridge PUBLIC play_vu_session)
add_executable(play_vu_probe probe_main.cpp replay_diagnostic.cpp compiled_session_tests.cpp
    runtime_bridge_tests.cpp scalar_flags_tests.cpp fmac_tests.cpp transfer_tests.cpp win64_register_test.asm ${VU_TEST_SOURCES})
target_include_directories(play_vu_probe PRIVATE "${VU_TEST_ROOT}")
target_link_libraries(play_vu_probe PRIVATE play_vu_runtime_bridge)
enable_testing()
add_test(NAME play_vu_upstream COMMAND play_vu_probe)
