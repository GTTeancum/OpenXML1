set(VULKAN_HEADERS_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../.tools/Vulkan-Headers" CACHE PATH "Pinned Vulkan headers")
require_revision("${VULKAN_HEADERS_ROOT}" ee2ec5fd83dafce291024683b50dc89219333076)
add_executable(play_gs_capabilities gpu_capabilities.cpp)
target_include_directories(play_gs_capabilities PRIVATE "${VULKAN_HEADERS_ROOT}/include")
target_compile_definitions(play_gs_capabilities PRIVATE NOMINMAX VK_NO_PROTOTYPES)

# Library-only recipes avoid the full Vulkan SDK and unrelated emulator/test apps.
require_revision("${PLAY_ROOT}/deps/Nuanceur" d96578b5a18edc67a268ed4811f0a035c56de7a0)
require_revision("${PLAY_ROOT}/deps/Dependencies/zlib" 5a82f71ed1dfc0bec044d9702463dbdf84ea3b71)
add_subdirectory("${PLAY_ROOT}/deps/Dependencies/build_cmake/zlib" zlib EXCLUDE_FROM_ALL)
require_revision("${PLAY_ROOT}/deps/Dependencies/zstd" f8745da6ff1ad1e7bab384bd1f9d742439278e99)
add_subdirectory("${PLAY_ROOT}/deps/Dependencies/build_cmake/zstd_zlibwrapper" zstd-wrapper EXCLUDE_FROM_ALL)
add_library(play_gs_support STATIC
    "${FRAMEWORK_ROOT}/src/Config.cpp"
    "${FRAMEWORK_ROOT}/src/PathUtils.cpp"
    "${FRAMEWORK_ROOT}/src/ThreadUtils.cpp"
    "${FRAMEWORK_ROOT}/src/Utf8.cpp"
    "${FRAMEWORK_ROOT}/src/string_cast.cpp"
    "${FRAMEWORK_ROOT}/src/bitmap/Bitmap.cpp"
    "${FRAMEWORK_ROOT}/src/xml/Parser.cpp"
    "${FRAMEWORK_ROOT}/src/xml/Writer.cpp"
    "${FRAMEWORK_ROOT}/src/xml/Utils.cpp"
    "${FRAMEWORK_ROOT}/src/zip/ZipArchiveReader.cpp"
    "${FRAMEWORK_ROOT}/src/zip/ZipArchiveWriter.cpp"
    "${FRAMEWORK_ROOT}/src/zip/ZipFile.cpp"
    "${FRAMEWORK_ROOT}/src/zip/ZipStoreStream.cpp"
    "${FRAMEWORK_ROOT}/src/zip/ZipInflateStream.cpp"
    "${FRAMEWORK_ROOT}/src/zip/ZipDeflateStream.cpp"
    "${PLAY_SOURCE}/app_shared/AppConfig.cpp"
    "${PLAY_SOURCE}/app_shared/Log.cpp"
    "${PLAY_SOURCE}/MailBox.cpp"
    "${PLAY_SOURCE}/FrameDump.cpp"
    "${PLAY_SOURCE}/states/MemoryStateFile.cpp"
    "${PLAY_SOURCE}/states/RegisterStateFile.cpp"
    "${PLAY_SOURCE}/states/RegisterState.cpp"
    "${PLAY_SOURCE}/ee/INTC.cpp"
    "${PLAY_SOURCE}/gs/GSHandler.cpp"
    "${PLAY_SOURCE}/gs/GsCachedArea.cpp"
    "${PLAY_SOURCE}/gs/GsPixelFormats.cpp")
target_include_directories(play_gs_support PUBLIC "${PLAY_SOURCE}" "${PLAY_SOURCE}/app_shared")
target_link_libraries(play_gs_support PUBLIC Framework CodeGen libzstd_zlibwrapper_static shell32)

add_library(Framework_Vulkan STATIC
    "${FRAMEWORK_ROOT}/src/vulkan/Buffer.cpp"
    "${FRAMEWORK_ROOT}/src/vulkan/CommandBufferPool.cpp"
    "${FRAMEWORK_ROOT}/src/vulkan/Device.cpp"
    "${FRAMEWORK_ROOT}/src/vulkan/Image.cpp"
    "${FRAMEWORK_ROOT}/src/vulkan/Instance.cpp"
    "${FRAMEWORK_ROOT}/src/vulkan/Loader.cpp"
    "${FRAMEWORK_ROOT}/src/vulkan/ShaderModule.cpp"
    "${FRAMEWORK_ROOT}/src/vulkan/Utils.cpp")
target_include_directories(Framework_Vulkan PUBLIC "${VULKAN_HEADERS_ROOT}/include")
target_link_libraries(Framework_Vulkan PUBLIC Framework)

set(NUANCEUR_ROOT "${PLAY_ROOT}/deps/Nuanceur")
add_library(Nuanceur STATIC
    "${NUANCEUR_ROOT}/src/builder/Operations.cpp"
    "${NUANCEUR_ROOT}/src/builder/ShaderBuilder.cpp"
    "${NUANCEUR_ROOT}/src/generators/GlslShaderGenerator.cpp"
    "${NUANCEUR_ROOT}/src/generators/HlslShaderGenerator.cpp"
    "${NUANCEUR_ROOT}/src/generators/SpirvShaderGenerator.cpp")
target_include_directories(Nuanceur PUBLIC "${NUANCEUR_ROOT}/include")
target_link_libraries(Nuanceur PUBLIC Framework)

file(GLOB GS_VULKAN_SOURCES CONFIGURE_DEPENDS "${PLAY_SOURCE}/gs/GSH_Vulkan/*.cpp")
add_library(play_gs_vulkan STATIC ${GS_VULKAN_SOURCES})
target_link_libraries(play_gs_vulkan PUBLIC play_gs_support Framework_Vulkan Nuanceur)
add_executable(play_gs_offscreen offscreen_main.cpp)
target_link_libraries(play_gs_offscreen PRIVATE play_gs_vulkan)
