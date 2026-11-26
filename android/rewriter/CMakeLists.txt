cmake_minimum_required(VERSION 3.18)
project(s2arm_rewriter_jni LANGUAGES C)
set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
# Also applies to the Capstone OBJECT target used by the static shared core.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

if(ANDROID AND NOT ANDROID_ABI STREQUAL "arm64-v8a")
    message(FATAL_ERROR "The Android preparation library requires arm64-v8a")
endif()

get_filename_component(rewriter_repo "${CMAKE_CURRENT_LIST_DIR}/../.." ABSOLUTE)
# The shared core requires S2A_REWRITER_DEPS with pinned, already prepared
# Capstone/LZ4 sources. Its CMake never downloads dependencies.
add_subdirectory("${rewriter_repo}/runtime/rewriter" core)
set_target_properties(s2a_rewriter capstone PROPERTIES POSITION_INDEPENDENT_CODE ON)
find_package(Threads REQUIRED)

add_library(s2arm_rewriter SHARED jni.c)
target_link_libraries(s2arm_rewriter PRIVATE s2a_rewriter Threads::Threads)
if(NOT ANDROID)
    # JNI is supplied by the calling VM. Only headers are needed, never libjvm.
    # Without COMPONENTS, FindJNI also demands AWT, which headless JDKs (Linux gate hosts) do not ship.
    find_package(JNI REQUIRED COMPONENTS JVM)
    target_include_directories(s2arm_rewriter PRIVATE ${JNI_INCLUDE_DIRS})
endif()
if(CMAKE_C_COMPILER_ID MATCHES "Clang|GNU")
    target_compile_options(s2arm_rewriter PRIVATE -Wall -Wextra -Werror -fvisibility=hidden)
endif()

if(APPLE)
    target_link_options(s2arm_rewriter PRIVATE
        "-Wl,-exported_symbol,_Java_org_s2arm_android_NativeRewriter_rewrite0"
        "-Wl,-undefined,error")
else()
    target_link_options(s2arm_rewriter PRIVATE
        "-Wl,--version-script=${CMAKE_CURRENT_LIST_DIR}/exports.map"
        "-Wl,--exclude-libs,ALL" "-Wl,-z,defs")
    set_property(TARGET s2arm_rewriter APPEND PROPERTY LINK_DEPENDS
        "${CMAKE_CURRENT_LIST_DIR}/exports.map")
    if(ANDROID)
        target_link_options(s2arm_rewriter PRIVATE
            "-Wl,-z,max-page-size=16384" "-Wl,-z,common-page-size=16384")
    endif()
endif()
