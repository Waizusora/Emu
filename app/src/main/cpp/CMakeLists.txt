cmake_minimum_required(VERSION 3.22.1)
project(emu_qemu_bridge LANGUAGES C CXX)

# SDL2 is cross-built by the native-dependencies CI job and staged per ABI
# before Gradle configures this Android JNI target.
set(SDL2_ROOT "${CMAKE_CURRENT_LIST_DIR}/../../../../.work/sdl2/${ANDROID_ABI}")
set(SDL2_STATIC_LIBRARY "${SDL2_ROOT}/usr/lib/libSDL2.a")
set(SDL2_INCLUDE_DIR "${SDL2_ROOT}/usr/include/SDL2")
if(NOT EXISTS "${SDL2_STATIC_LIBRARY}" OR NOT EXISTS "${SDL2_INCLUDE_DIR}/SDL.h")
    message(FATAL_ERROR "Missing ABI-matched SDL2 artifact for ${ANDROID_ABI}: ${SDL2_ROOT}")
endif()

add_library(SDL2::SDL2 STATIC IMPORTED GLOBAL)
set_target_properties(SDL2::SDL2 PROPERTIES
    IMPORTED_LOCATION "${SDL2_STATIC_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${SDL2_INCLUDE_DIR}"
)

add_library(emu-qemu SHARED qemu_jni.cpp)
target_compile_features(emu-qemu PRIVATE cxx_std_17)
target_compile_options(emu-qemu PRIVATE -Wall -Wextra -Werror)
target_link_libraries(emu-qemu PRIVATE SDL2::SDL2 android log)
