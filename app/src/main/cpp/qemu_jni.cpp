#include <jni.h>
#include <SDL.h>
#include <SDL_config.h>

#include <cstdio>
#include <cstring>

#if !defined(SDL_AUDIO_DRIVER_AAUDIO)
#error "SDL2 must be built with its Android AAudio audio backend"
#endif

namespace {
constexpr char kQemuVersion[] = "9.2.0";
constexpr char kAudioDriver[] = "aaudio";
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

extern "C" JNIEXPORT jboolean JNICALL
Java_com_waizusora_emu_QemuRuntime_nativePrepareAudio(
    JNIEnv* /* env */, jobject /* thiz */) {
    // Set this before SDL_Init(SDL_INIT_AUDIO); AAudio is preferred explicitly
    // instead of falling back to SDL's Java AudioTrack backend.
    return SDL_SetHint(SDL_HINT_AUDIODRIVER, kAudioDriver) == SDL_TRUE
        ? JNI_TRUE
        : JNI_FALSE;
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_waizusora_emu_QemuRuntime_nativeGetStatus(
    JNIEnv* env, jobject /* thiz */) {
    SDL_version version{};
    SDL_GetVersion(&version);

    bool aaudioCompiled = false;
    const int driverCount = SDL_GetNumAudioDrivers();
    for (int index = 0; index < driverCount; ++index) {
        const char* driver = SDL_GetAudioDriver(index);
        if (driver != nullptr && std::strcmp(driver, kAudioDriver) == 0) {
            aaudioCompiled = true;
            break;
        }
    }

    char status[192]{};
    std::snprintf(
        status, sizeof(status),
        "QEMU %s runtime is not packaged; SDL2 %u.%u.%u is linked; AAudio backend %s",
        kQemuVersion, version.major, version.minor, version.patch,
        aaudioCompiled ? "compiled" : "missing");
    return env->NewStringUTF(status);
}
