// Venera waifu2x C bridge for macOS (CPU-only mode)
// Author: kirk

#include "waifu2x_bridge.h"
#include "waifu2x.h"
#include "png_image.h"
#include "jpeg_image.h"
#include "webp_image.h"

#include <string>
#include <vector>
#include <cstring>
#include <cstdlib>

// PNG memory write helper
struct png_write_ctx {
    std::vector<unsigned char> buffer;
};

static void png_write_fn_bridge(png_structp png_ptr, png_bytep data, png_size_t length) {
    png_write_ctx* ctx = (png_write_ctx*)png_get_io_ptr(png_ptr);
    ctx->buffer.insert(ctx->buffer.end(), data, data + length);
}

static void png_flush_fn_bridge(png_structp) {}

static int png_encode_to_memory(int w, int h, int c, const unsigned char* pixeldata,
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

    png_write_ctx ctx;
    png_set_write_fn(png_ptr, &ctx, png_write_fn_bridge, png_flush_fn_bridge);

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

// Detect image format
enum ImgFormat { IMG_PNG, IMG_JPEG, IMG_WEBP, IMG_UNKNOWN };

static ImgFormat detect_img_format(const unsigned char* data, int len) {
    if (len >= 8 && data[0] == 0x89 && data[1] == 'P' && data[2] == 'N' && data[3] == 'G')
        return IMG_PNG;
    if (len >= 2 && data[0] == 0xFF && data[1] == 0xD8)
        return IMG_JPEG;
    if (len >= 12 && data[0] == 'R' && data[1] == 'I' && data[2] == 'F' && data[3] == 'F'
        && data[8] == 'W' && data[9] == 'E' && data[10] == 'B' && data[11] == 'P')
        return IMG_WEBP;
    return IMG_UNKNOWN;
}

static std::string g_model_dir;
static bool g_initialized = false;

extern "C" {

int waifu2x_is_available(void) {
    return 1; // CPU-only mode always available
}

int waifu2x_init(const char* model_dir) {
    if (!model_dir) return -1;
    g_model_dir = model_dir;
    g_initialized = true;
    return 0;
}

int waifu2x_enhance(const unsigned char* input_data, int input_len,
                     int noise_level, int scale, int tile_size,
                     unsigned char** output_data, int* output_len)
{
    if (!g_initialized || !input_data || input_len <= 0 || !output_data || !output_len)
        return -1;

    // Decode image
    int w = 0, h = 0, c = 0;
    unsigned char* pixeldata = NULL;
    ImgFormat fmt = detect_img_format(input_data, input_len);

    switch (fmt) {
        case IMG_PNG:
            pixeldata = png_load(input_data, input_len, &w, &h, &c);
            break;
        case IMG_JPEG:
            pixeldata = jpeg_load(input_data, input_len, &w, &h, &c);
            break;
        case IMG_WEBP:
            pixeldata = webp_load(input_data, input_len, &w, &h, &c);
            break;
        default:
            pixeldata = png_load(input_data, input_len, &w, &h, &c);
            if (!pixeldata) pixeldata = jpeg_load(input_data, input_len, &w, &h, &c);
            break;
    }

    if (!pixeldata || w <= 0 || h <= 0) {
        if (pixeldata) free(pixeldata);
        return -2;
    }

    // Clamp parameters
    int actualScale = (scale >= 2) ? 2 : 1;
    int actualNoise = (noise_level < -1) ? -1 : ((noise_level > 3) ? 3 : noise_level);
    int actualTileSize = (tile_size < 32) ? 32 : tile_size;

    // CPU-only: gpuid = -1
    Waifu2x waifu2x(-1, false, 1);
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

    std::string paramPath = g_model_dir + "/" + paramName;
    std::string modelPath = g_model_dir + "/" + modelName;

    int ret = waifu2x.load(paramPath, modelPath);
    if (ret != 0) {
        free(pixeldata);
        return -3;
    }

    // Process
    int outW = w * actualScale;
    int outH = h * actualScale;

    ncnn::Mat inimage(w, h, (void*)pixeldata, (size_t)c, c);
    ncnn::Mat outimage(outW, outH, (size_t)c, c);

    ret = waifu2x.process_cpu(inimage, outimage);
    free(pixeldata);

    if (ret != 0) {
        return -4;
    }

    // Encode output as PNG
    std::vector<unsigned char> outputPng;
    const unsigned char* outPixels = (const unsigned char*)outimage.data;

    if (!png_encode_to_memory(outW, outH, c, outPixels, outputPng) || outputPng.empty()) {
        return -5;
    }

    // Allocate output buffer
    *output_len = (int)outputPng.size();
    *output_data = (unsigned char*)malloc(outputPng.size());
    if (!*output_data) {
        return -6;
    }
    memcpy(*output_data, outputPng.data(), outputPng.size());

    return 0;
}

void waifu2x_free(unsigned char* data) {
    free(data);
}

} // extern "C"
