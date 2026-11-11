#include <jni.h>
#include <SDL.h>

#include <cstdio>

namespace {
constexpr char kQemuVersion[] = "9.2.0";
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_waizusora_emu_QemuRuntime_nativeGetTargetVersion(
    JNIEnv* env, jobject /* thiz */) {
    return env->NewStringUTF(kQemuVersion);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_waizusora_emu_QemuRuntime_nativeIsAvailable(
    JNIEnv* /* env */, jobject /* thiz */) {
    // This bridge becomes true only when the QEMU engine is linked and packaged.
    return JNI_FALSE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_waizusora_emu_QemuRuntime_nativeGetStatus(
    JNIEnv* env, jobject /* thiz */) {
    SDL_version version{};
    SDL_GetVersion(&version);
    char status[128]{};
    std::snprintf(
        status, sizeof(status),
        "QEMU %s runtime is not packaged; SDL2 %u.%u.%u is linked",
        kQemuVersion, version.major, version.minor, version.patch);
    return env->NewStringUTF(status);
}
