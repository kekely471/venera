package com.github.wgh136.venera

import android.content.res.AssetManager
import android.util.Log

class Waifu2xProcessor {
    fun enhance(
        imageBytes: ByteArray,
        noiseLevel: Int,
        scale: Int,
        tileSize: Int,
    ): ByteArray {
        check(isAvailable()) { "waifu2x native library is unavailable" }
        return nativeEnhance(imageBytes, noiseLevel, scale, tileSize)
    }

    private external fun nativeEnhance(
        imageBytes: ByteArray,
        noiseLevel: Int,
        scale: Int,
        tileSize: Int,
    ): ByteArray

    companion object {
        private var libraryLoaded = false

        init {
            try {
                System.loadLibrary("venera_waifu2x")
                libraryLoaded = true
            } catch (e: UnsatisfiedLinkError) {
                Log.w("Venera", "waifu2x library not loaded: ${e.message}")
            } catch (e: SecurityException) {
                Log.w("Venera", "waifu2x library blocked: ${e.message}")
            }
        }

        fun isAvailable(): Boolean {
            return libraryLoaded
        }

        @JvmStatic
        private external fun nativeSetAssetManager(assetManager: AssetManager)

        fun initAssetManager(assetManager: AssetManager) {
            if (libraryLoaded) {
                nativeSetAssetManager(assetManager)
            }
        }
    }
}
