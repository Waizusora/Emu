cmake_minimum_required(VERSION 3.22.1)
project(emu_qemu_bridge LANGUAGES C CXX)

add_library(emu-qemu SHARED qemu_jni.cpp)
target_compile_features(emu-qemu PRIVATE cxx_std_17)
target_compile_options(emu-qemu PRIVATE -Wall -Wextra -Werror)
target_link_libraries(emu-qemu PRIVATE android log)
