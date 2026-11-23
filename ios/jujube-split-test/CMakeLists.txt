cmake_minimum_required(VERSION 3.24)
project(JujubeSplitProbe LANGUAGES C CXX OBJC OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

# Tested against ggml-org/llama.cpp revision:
# 56eea9e4b0f5d125da16b75b551440b170aa8b1f (November 2026).
set(JUJUBE_LLAMA_SOURCE "" CACHE PATH "Version-pinned llama.cpp source directory")
set(JUJUBE_IOS_BUILD "" CACHE PATH "llama.cpp iPhoneOS RPC build directory")
set(JUJUBE_TEAM_ID "" CACHE STRING "Local Apple Developer Team for signing")
set(JUJUBE_BUNDLE_ID "org.example.jujube.splitprobe" CACHE STRING "Unique app bundle identifier")
set(JUJUBE_OPTIONAL_QWEN_GGUF "" CACHE FILEPATH "Optional separately obtained Qwen GGUF, never redistributed")

if(NOT EXISTS "${JUJUBE_LLAMA_SOURCE}/include/llama.h")
    message(FATAL_ERROR "Set -DJUJUBE_LLAMA_SOURCE=/path/to/llama.cpp")
endif()
if(NOT EXISTS "${JUJUBE_IOS_BUILD}/src/Release-iphoneos/libllama.a")
    message(FATAL_ERROR "Set -DJUJUBE_IOS_BUILD=/path/to/ios/rpc/build")
endif()

add_executable(StrataSplitProbe MACOSX_BUNDLE Probe.mm IPhoneTlsBridge.mm IPhoneTlsBridge.h)
set_target_properties(StrataSplitProbe PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_LIST_DIR}/Info.plist"
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "${JUJUBE_BUNDLE_ID}"
    XCODE_ATTRIBUTE_CODE_SIGN_STYLE "Automatic"
    XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC "YES"
    XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++17"
    XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1"
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "18.0")
if(JUJUBE_TEAM_ID)
    set_target_properties(StrataSplitProbe PROPERTIES XCODE_ATTRIBUTE_DEVELOPMENT_TEAM "${JUJUBE_TEAM_ID}")
endif()

target_include_directories(StrataSplitProbe PRIVATE
    "${JUJUBE_LLAMA_SOURCE}/include"
    "${JUJUBE_LLAMA_SOURCE}/ggml/include")
target_link_libraries(StrataSplitProbe PRIVATE
    "-Wl,-all_load"
    "${JUJUBE_IOS_BUILD}/src/Release-iphoneos/libllama.a"
    "${JUJUBE_IOS_BUILD}/ggml/src/Release-iphoneos/libggml.a"
    "${JUJUBE_IOS_BUILD}/ggml/src/Release-iphoneos/libggml-cpu.a"
    "${JUJUBE_IOS_BUILD}/ggml/src/Release-iphoneos/libggml-base.a"
    "${JUJUBE_IOS_BUILD}/ggml/src/ggml-blas/Release-iphoneos/libggml-blas.a"
    "${JUJUBE_IOS_BUILD}/ggml/src/ggml-rpc/Release-iphoneos/libggml-rpc.a"
    "-framework UIKit" "-framework CoreGraphics" "-framework Foundation"
    "-framework Accelerate" "-framework Security" "-lc++")
if(JUJUBE_OPTIONAL_QWEN_GGUF)
    set_source_files_properties("${JUJUBE_OPTIONAL_QWEN_GGUF}" PROPERTIES MACOSX_PACKAGE_LOCATION Resources)
    target_sources(StrataSplitProbe PRIVATE "${JUJUBE_OPTIONAL_QWEN_GGUF}")
endif()
