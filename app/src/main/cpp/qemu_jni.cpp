#include <jni.h>

namespace {
constexpr char kQemuVersion[] = "9.2.0";
constexpr char kRuntimeState[] =
    "QEMU 9.2.0 runtime is not packaged in this build";
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
    return env->NewStringUTF(kRuntimeState);
}
