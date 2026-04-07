// Venera waifu2x C bridge for macOS
// Author: kirk

#ifndef WAIFU2X_BRIDGE_H
#define WAIFU2X_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

// Check if waifu2x is available (returns 1 if available, 0 otherwise)
int waifu2x_is_available(void);

// Initialize waifu2x with model directory path
// Returns 0 on success, non-zero on failure
int waifu2x_init(const char* model_dir);

// Enhance image
// input_data: raw image bytes (PNG/JPEG/WebP)
// input_len: length of input data
// noise_level: -1 to 3
// scale: 1 or 2
// tile_size: tile size for processing (e.g., 256)
// output_data: pointer to output buffer (caller must free with waifu2x_free)
// output_len: pointer to output length
// Returns 0 on success, non-zero on failure
int waifu2x_enhance(const unsigned char* input_data, int input_len,
                     int noise_level, int scale, int tile_size,
                     unsigned char** output_data, int* output_len);

// Free memory allocated by waifu2x_enhance
void waifu2x_free(unsigned char* data);

#ifdef __cplusplus
}
#endif

#endif // WAIFU2X_BRIDGE_H
