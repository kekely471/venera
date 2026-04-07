// Venera waifu2x JNI bridge
// Author: kirk

#include <jni.h>
#include <android/log.h>
#include <android/asset_manager.h>
#include <android/asset_manager_jni.h>
#include <string>
#include <vector>

#include "gpu.h"
#include "waifu2x.h"
#include "png_image.h"
#include "jpeg_image.h"
#include "webp_image.h"

#define TAG "VeneraWaifu2x"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// PNG memory write helper
struct png_write_context {
    std::vector<unsigned char> buffer;
};

static void png_write_fn_mem(png_structp png_ptr, png_bytep data, png_size_t length) {
    png_write_context* ctx = (png_write_context*)png_get_io_ptr(png_ptr);
    ctx->buffer.insert(ctx->buffer.end(), data, data + length);
}

static void png_flush_fn_mem(png_structp /*png_ptr*/) {}

static int png_save_to_memory(int w, int h, int c, const unsigned char* pixeldata,
                              std::vector<unsigned char>& out) {
    png_structp png_ptr = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (!png_ptr) return 0;

    png_infop info_ptr = png_create_info_struct(png_ptr);
    if (!info_ptr) {
        png_destroy_write_struct(&png_ptr, NULL);
        return 0;
    }

    if (setjmp(png_jmpbuf(png_ptr))) {
        png_destroy_write_struct(&png_ptr, &info_ptr);
        return 0;
    }

    png_write_context ctx;
    png_set_write_fn(png_ptr, &ctx, png_write_fn_mem, png_flush_fn_mem);

    png_set_IHDR(png_ptr, info_ptr, w, h, 8,
                 c == 3 ? PNG_COLOR_TYPE_RGB : PNG_COLOR_TYPE_RGBA,
                 PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_DEFAULT,
                 PNG_FILTER_TYPE_DEFAULT);

    png_write_info(png_ptr, info_ptr);

    std::vector<png_bytep> row_pointers(h);
    for (int i = 0; i < h; i++)
        row_pointers[i] = const_cast<png_bytep>(pixeldata + (size_t)i * w * c);

    png_write_image(png_ptr, row_pointers.data());
    png_write_end(png_ptr, info_ptr);
    png_destroy_write_struct(&png_ptr, &info_ptr);

    out = std::move(ctx.buffer);
    return 1;
}

// Detect image format from header bytes
enum ImageFormat { FORMAT_PNG, FORMAT_JPEG, FORMAT_WEBP, FORMAT_UNKNOWN };

static ImageFormat detect_format(const unsigned char* data, int len) {
    if (len >= 8 && data[0] == 0x89 && data[1] == 'P' && data[2] == 'N' && data[3] == 'G')
        return FORMAT_PNG;
    if (len >= 2 && data[0] == 0xFF && data[1] == 0xD8)
        return FORMAT_JPEG;
    if (len >= 12 && data[0] == 'R' && data[1] == 'I' && data[2] == 'F' && data[3] == 'F'
        && data[8] == 'W' && data[9] == 'E' && data[10] == 'B' && data[11] == 'P')
        return FORMAT_WEBP;
    return FORMAT_UNKNOWN;
}

// Global AssetManager reference (set from Kotlin before first use)
static AAssetManager* g_asset_manager = nullptr;

extern "C" {

JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void* /*reserved*/) {
    LOGI("JNI_OnLoad: initializing GPU instance");
    ncnn::create_gpu_instance();
    return JNI_VERSION_1_6;
}

JNIEXPORT void JNI_OnUnload(JavaVM* vm, void* /*reserved*/) {
    LOGI("JNI_OnUnload: destroying GPU instance");
    ncnn::destroy_gpu_instance();
}

JNIEXPORT void JNICALL
Java_com_github_wgh136_venera_Waifu2xProcessor_nativeSetAssetManager(
    JNIEnv* env, jclass /*clazz*/, jobject assetManager)
{
    g_asset_manager = AAssetManager_fromJava(env, assetManager);
    LOGI("AssetManager set: %p", g_asset_manager);
}

JNIEXPORT jbyteArray JNICALL
Java_com_github_wgh136_venera_Waifu2xProcessor_nativeEnhance(
    JNIEnv* env, jobject /*thiz*/,
    jbyteArray imageBytes, jint noiseLevel, jint scale, jint tileSize)
{
    // Get input bytes
    jsize inputLen = env->GetArrayLength(imageBytes);
    jbyte* inputData = env->GetByteArrayElements(imageBytes, NULL);
    if (!inputData || inputLen <= 0) {
        if (inputData) env->ReleaseByteArrayElements(imageBytes, inputData, JNI_ABORT);
        env->ThrowNew(env->FindClass("java/lang/IllegalArgumentException"),
                      "Invalid input image data");
        return NULL;
    }

    const unsigned char* rawInput = reinterpret_cast<const unsigned char*>(inputData);

    // Decode image
    int w = 0, h = 0, c = 0;
    unsigned char* pixeldata = NULL;
    ImageFormat fmt = detect_format(rawInput, inputLen);

    switch (fmt) {
        case FORMAT_PNG:
            pixeldata = png_load(rawInput, inputLen, &w, &h, &c);
            break;
        case FORMAT_JPEG:
            pixeldata = jpeg_load(rawInput, inputLen, &w, &h, &c);
            break;
        case FORMAT_WEBP:
            pixeldata = webp_load(rawInput, inputLen, &w, &h, &c);
            break;
        default:
            pixeldata = png_load(rawInput, inputLen, &w, &h, &c);
            if (!pixeldata) pixeldata = jpeg_load(rawInput, inputLen, &w, &h, &c);
            break;
    }

    env->ReleaseByteArrayElements(imageBytes, inputData, JNI_ABORT);

    if (!pixeldata || w <= 0 || h <= 0) {
        if (pixeldata) free(pixeldata);
        env->ThrowNew(env->FindClass("java/lang/RuntimeException"),
                      "Failed to decode input image");
        return NULL;
    }

    LOGI("Decoded image: %dx%d, channels=%d", w, h, c);

    // Clamp parameters
    int actualScale = (scale >= 2) ? 2 : 1;
    int actualNoise = (noiseLevel < -1) ? -1 : ((noiseLevel > 3) ? 3 : noiseLevel);
    int actualTileSize = (tileSize < 32) ? 32 : tileSize;

    // Setup waifu2x
    int gpuid = ncnn::get_default_gpu_index();
    Waifu2x waifu2x(gpuid, false, 1);
    waifu2x.noise = actualNoise;
    waifu2x.scale = actualScale;
    waifu2x.tilesize = actualTileSize;

    // Determine prepadding for models-cunet
    int prepadding = 0;
    if (actualNoise == -1) {
        prepadding = 18;
    } else if (actualScale == 1) {
        prepadding = 28;
    } else {
        prepadding = 18;
    }
    waifu2x.prepadding = prepadding;

    // Determine model paths
    std::string paramName, modelName;
    if (actualNoise >= 0 && actualScale >= 2) {
        paramName = "noise" + std::to_string(actualNoise) + "_scale2.0x_model.param";
        modelName = "noise" + std::to_string(actualNoise) + "_scale2.0x_model.bin";
    } else if (actualScale >= 2) {
        paramName = "scale2.0x_model.param";
        modelName = "scale2.0x_model.bin";
    } else {
        paramName = "noise" + std::to_string(actualNoise) + "_model.param";
        modelName = "noise" + std::to_string(actualNoise) + "_model.bin";
    }

    std::string paramPath = "models-cunet/" + paramName;
    std::string modelPath = "models-cunet/" + modelName;

    LOGI("Loading model: %s, %s", paramPath.c_str(), modelPath.c_str());

    if (!g_asset_manager) {
        free(pixeldata);
        LOGE("AssetManager not set");
        env->ThrowNew(env->FindClass("java/lang/RuntimeException"),
                      "AssetManager not initialized");
        return NULL;
    }

    int ret = waifu2x.load(g_asset_manager, paramPath, modelPath);
    if (ret != 0) {
        free(pixeldata);
        LOGE("Failed to load waifu2x model: %d", ret);
        env->ThrowNew(env->FindClass("java/lang/RuntimeException"),
                      "Failed to load waifu2x model");
        return NULL;
    }

    // Process
    int outW = w * actualScale;
    int outH = h * actualScale;

    ncnn::Mat inimage(w, h, (void*)pixeldata, (size_t)c, c);
    ncnn::Mat outimage(outW, outH, (size_t)c, c);

    ret = waifu2x.process(inimage, outimage);
    free(pixeldata);

    if (ret != 0) {
        LOGE("waifu2x process failed: %d", ret);
        env->ThrowNew(env->FindClass("java/lang/RuntimeException"),
                      "waifu2x processing failed");
        return NULL;
    }

    LOGI("Process complete: %dx%d -> %dx%d", w, h, outW, outH);

    // Encode output as PNG to memory
    std::vector<unsigned char> outputPng;
    const unsigned char* outPixels = (const unsigned char*)outimage.data;

    if (!png_save_to_memory(outW, outH, c, outPixels, outputPng) || outputPng.empty()) {
        LOGE("Failed to encode output PNG");
        env->ThrowNew(env->FindClass("java/lang/RuntimeException"),
                      "Failed to encode output image");
        return NULL;
    }

    // Return as byte array
    jbyteArray result = env->NewByteArray(outputPng.size());
    if (!result) {
        env->ThrowNew(env->FindClass("java/lang/OutOfMemoryError"),
                      "Failed to allocate output byte array");
        return NULL;
    }
    env->SetByteArrayRegion(result, 0, outputPng.size(),
                            reinterpret_cast<const jbyte*>(outputPng.data()));

    return result;
}

} // extern "C"
