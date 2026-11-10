package com.waizusora.emu

/**
 * JNI boundary for the native QEMU engine.
 *
 * The current build packages only the bridge library. It intentionally reports
 * the engine as unavailable until qemu-system-aarch64 is built for the host ABI.
 */
object QemuRuntime {
    const val TARGET_VERSION = "9.2.0"

    private val libraryLoaded: Boolean = runCatching {
        System.loadLibrary("emu-qemu")
    }.isSuccess

    val isNativeBridgeLoaded: Boolean
        get() = libraryLoaded

    fun isAvailable(): Boolean =
        libraryLoaded && nativeIsAvailable()

    fun status(): String =
        if (libraryLoaded) nativeGetStatus() else "Native QEMU bridge failed to load"

    fun targetVersion(): String =
        if (libraryLoaded) nativeGetTargetVersion() else TARGET_VERSION

    private external fun nativeGetTargetVersion(): String
    private external fun nativeIsAvailable(): Boolean
    private external fun nativeGetStatus(): String
}
