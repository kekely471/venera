# Venera waifu2x native library
# Author: kirk

cmake_minimum_required(VERSION 3.10)
project(venera_waifu2x)

set(WAIFU2X_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../third_party/waifu2x/waifu2x-ncnn-vulkan/src")

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Choose the type of build" FORCE)
endif()

find_package(Threads)
find_package(OpenMP)

if(OPENMP_FOUND)
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} ${OpenMP_C_FLAGS}")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${OpenMP_CXX_FLAGS}")
    set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} ${OpenMP_EXE_LINKER_FLAGS}")
endif()

# Optimization flags
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fomit-frame-pointer -fstrict-aliasing -ffast-math")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fomit-frame-pointer -fstrict-aliasing -ffast-math")
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fvisibility=hidden")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fvisibility=hidden -fvisibility-inlines-hidden")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fno-rtti -fno-exceptions")

# Static OpenMP for NDK 21+
if(DEFINED ANDROID_NDK_MAJOR AND ${ANDROID_NDK_MAJOR} GREATER 20)
    set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -static-openmp")
endif()

include_directories(${CMAKE_CURRENT_BINARY_DIR})
include_directories(${WAIFU2X_SRC_DIR})

# Shader preprocessing
macro(waifu2x_add_shader SHADER_SRC)
    get_filename_component(SHADER_SRC_NAME_WE ${SHADER_SRC} NAME_WE)
    set(SHADER_COMP_HEADER ${CMAKE_CURRENT_BINARY_DIR}/${SHADER_SRC_NAME_WE}.comp.hex.h)

    add_custom_command(
        OUTPUT ${SHADER_COMP_HEADER}
        COMMAND ${CMAKE_COMMAND} -DSHADER_SRC=${WAIFU2X_SRC_DIR}/${SHADER_SRC} -DSHADER_COMP_HEADER=${SHADER_COMP_HEADER} -P "${WAIFU2X_SRC_DIR}/generate_shader_comp_header.cmake"
        DEPENDS ${WAIFU2X_SRC_DIR}/${SHADER_SRC}
        COMMENT "Preprocessing shader source ${SHADER_SRC_NAME_WE}.comp"
        VERBATIM
    )
    set_source_files_properties(${SHADER_COMP_HEADER} PROPERTIES GENERATED TRUE)
    list(APPEND SHADER_SPV_HEX_FILES ${SHADER_COMP_HEADER})
endmacro()

waifu2x_add_shader(waifu2x_preproc.comp)
waifu2x_add_shader(waifu2x_postproc.comp)
waifu2x_add_shader(waifu2x_preproc_tta.comp)
waifu2x_add_shader(waifu2x_postproc_tta.comp)

add_custom_target(generate-spirv DEPENDS ${SHADER_SPV_HEX_FILES})

# ncnn (build from source)
option(NCNN_INSTALL_SDK "" OFF)
option(NCNN_PIXEL_ROTATE "" OFF)
option(NCNN_PIXEL_AFFINE "" OFF)
option(NCNN_PIXEL_DRAWING "" OFF)
option(NCNN_VULKAN "" ON)
option(NCNN_SIMPLEVK "" ON)
option(NCNN_BUILD_BENCHMARK "" OFF)
option(NCNN_BUILD_TESTS "" OFF)
option(NCNN_BUILD_TOOLS "" OFF)
option(NCNN_BUILD_EXAMPLES "" OFF)
option(NCNN_DISABLE_RTTI "" ON)
option(NCNN_DISABLE_EXCEPTION "" ON)
option(NCNN_INT8 "" OFF)
option(NCNN_BF16 "" OFF)

# Only enable layers needed by waifu2x
option(WITH_LAYER_absval "" OFF)
option(WITH_LAYER_argmax "" OFF)
option(WITH_LAYER_batchnorm "" OFF)
option(WITH_LAYER_bias "" OFF)
option(WITH_LAYER_bnll "" OFF)
option(WITH_LAYER_concat "" OFF)
option(WITH_LAYER_convolution "" ON)
option(WITH_LAYER_crop "" ON)
option(WITH_LAYER_deconvolution "" ON)
option(WITH_LAYER_dropout "" OFF)
option(WITH_LAYER_eltwise "" ON)
option(WITH_LAYER_elu "" OFF)
option(WITH_LAYER_embed "" OFF)
option(WITH_LAYER_exp "" OFF)
option(WITH_LAYER_flatten "" ON)
option(WITH_LAYER_innerproduct "" ON)
option(WITH_LAYER_input "" ON)
option(WITH_LAYER_log "" OFF)
option(WITH_LAYER_lrn "" OFF)
option(WITH_LAYER_memorydata "" OFF)
option(WITH_LAYER_mvn "" OFF)
option(WITH_LAYER_pooling "" ON)
option(WITH_LAYER_power "" OFF)
option(WITH_LAYER_prelu "" OFF)
option(WITH_LAYER_proposal "" OFF)
option(WITH_LAYER_reduction "" OFF)
option(WITH_LAYER_relu "" ON)
option(WITH_LAYER_reshape "" OFF)
option(WITH_LAYER_roipooling "" OFF)
option(WITH_LAYER_scale "" ON)
option(WITH_LAYER_sigmoid "" OFF)
option(WITH_LAYER_slice "" OFF)
option(WITH_LAYER_softmax "" OFF)
option(WITH_LAYER_split "" ON)
option(WITH_LAYER_spp "" OFF)
option(WITH_LAYER_tanh "" OFF)
option(WITH_LAYER_threshold "" OFF)
option(WITH_LAYER_tile "" OFF)
option(WITH_LAYER_rnn "" OFF)
option(WITH_LAYER_lstm "" OFF)
option(WITH_LAYER_binaryop "" OFF)
option(WITH_LAYER_unaryop "" OFF)
option(WITH_LAYER_convolutiondepthwise "" OFF)
option(WITH_LAYER_padding "" ON)
option(WITH_LAYER_squeeze "" OFF)
option(WITH_LAYER_expanddims "" OFF)
option(WITH_LAYER_normalize "" OFF)
option(WITH_LAYER_permute "" OFF)
option(WITH_LAYER_priorbox "" OFF)
option(WITH_LAYER_detectionoutput "" OFF)
option(WITH_LAYER_interp "" ON)
option(WITH_LAYER_deconvolutiondepthwise "" OFF)
option(WITH_LAYER_shufflechannel "" OFF)
option(WITH_LAYER_instancenorm "" OFF)
option(WITH_LAYER_clip "" OFF)
option(WITH_LAYER_reorg "" OFF)
option(WITH_LAYER_yolodetectionoutput "" OFF)
option(WITH_LAYER_quantize "" OFF)
option(WITH_LAYER_dequantize "" OFF)
option(WITH_LAYER_yolov3detectionoutput "" OFF)
option(WITH_LAYER_psroipooling "" OFF)
option(WITH_LAYER_roialign "" OFF)
option(WITH_LAYER_packing "" ON)
option(WITH_LAYER_requantize "" OFF)
option(WITH_LAYER_cast "" ON)
option(WITH_LAYER_hardsigmoid "" OFF)
option(WITH_LAYER_selu "" OFF)
option(WITH_LAYER_hardswish "" OFF)
option(WITH_LAYER_noop "" OFF)
option(WITH_LAYER_pixelshuffle "" OFF)
option(WITH_LAYER_deepcopy "" OFF)
option(WITH_LAYER_mish "" OFF)
option(WITH_LAYER_statisticspooling "" OFF)
option(WITH_LAYER_swish "" OFF)
option(WITH_LAYER_gemm "" OFF)
option(WITH_LAYER_groupnorm "" OFF)
option(WITH_LAYER_layernorm "" OFF)
option(WITH_LAYER_softplus "" OFF)
option(WITH_LAYER_gru "" OFF)
option(WITH_LAYER_multiheadattention "" OFF)
option(WITH_LAYER_gelu "" OFF)
option(WITH_LAYER_convolution1d "" OFF)
option(WITH_LAYER_pooling1d "" OFF)
option(WITH_LAYER_convolutiondepthwise1d "" OFF)
option(WITH_LAYER_convolution3d "" OFF)
option(WITH_LAYER_convolutiondepthwise3d "" OFF)
option(WITH_LAYER_pooling3d "" OFF)
option(WITH_LAYER_matmul "" OFF)
option(WITH_LAYER_deconvolution1d "" OFF)
option(WITH_LAYER_deconvolutiondepthwise1d "" OFF)
option(WITH_LAYER_deconvolution3d "" OFF)
option(WITH_LAYER_deconvolutiondepthwise3d "" OFF)
option(WITH_LAYER_einsum "" OFF)
option(WITH_LAYER_deformableconv2d "" OFF)
option(WITH_LAYER_glu "" OFF)
option(WITH_LAYER_fold "" OFF)
option(WITH_LAYER_unfold "" OFF)
option(WITH_LAYER_gridsample "" OFF)
option(WITH_LAYER_cumulativesum "" OFF)
option(WITH_LAYER_copyto "" OFF)
option(WITH_LAYER_erf "" OFF)
option(WITH_LAYER_diag "" OFF)
option(WITH_LAYER_celu "" OFF)
option(WITH_LAYER_shrink "" OFF)
option(WITH_LAYER_rmsnorm "" OFF)
option(WITH_LAYER_spectrogram "" OFF)
option(WITH_LAYER_inversespectrogram "" OFF)

add_subdirectory(${WAIFU2X_SRC_DIR}/ncnn ${CMAKE_CURRENT_BINARY_DIR}/ncnn)

# Image codec libraries (build from source as static)
include(ExternalProject)

# zlib-ng
ExternalProject_Add(deps-zlib-ng
    SOURCE_DIR "${WAIFU2X_SRC_DIR}/zlib-ng"
    BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/zlib-ng"
    INSTALL_DIR "${CMAKE_CURRENT_BINARY_DIR}/deps-install"
    CMAKE_ARGS
        -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
        -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
        -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}
        -DANDROID_ABI=${ANDROID_ABI}
        -DANDROID_PLATFORM=${ANDROID_PLATFORM}
        -DBUILD_SHARED_LIBS=OFF
        -DWITH_GZFILEOP=OFF
        -DZLIB_COMPAT=ON
        -DZLIB_ENABLE_TESTS=OFF
        -DZLIBNG_ENABLE_TESTS=OFF
        -DWITH_GTEST=OFF
        -DWITH_FUZZERS=OFF
        -DWITH_BENCHMARKS=OFF
        -DWITH_OPTIM=ON
        -DWITH_REDUCED_MEM=OFF
        -DWITH_NEW_STRATEGIES=ON
        -DWITH_RUNTIME_CPU_DETECTION=ON
    BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --config ${CMAKE_BUILD_TYPE}
    INSTALL_COMMAND ${CMAKE_COMMAND} --install <BINARY_DIR> --config ${CMAKE_BUILD_TYPE}
)

# libpng
ExternalProject_Add(deps-libpng
    SOURCE_DIR "${WAIFU2X_SRC_DIR}/libpng"
    BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/libpng"
    INSTALL_DIR "${CMAKE_CURRENT_BINARY_DIR}/deps-install"
    CMAKE_ARGS
        -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
        -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
        -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}
        -DANDROID_ABI=${ANDROID_ABI}
        -DANDROID_PLATFORM=${ANDROID_PLATFORM}
        -DPNG_SHARED=OFF
        -DPNG_STATIC=ON
        -DPNG_TESTS=OFF
        -DPNG_TOOLS=OFF
        -DPNG_HARDWARE_OPTIMIZATIONS=ON
        -DZLIB_ROOT=<INSTALL_DIR>
        -DZLIB_USE_STATIC_LIBS=TRUE
    BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --config ${CMAKE_BUILD_TYPE}
    INSTALL_COMMAND ${CMAKE_COMMAND} --install <BINARY_DIR> --config ${CMAKE_BUILD_TYPE}
)
add_dependencies(deps-libpng deps-zlib-ng)

# libjpeg-turbo
ExternalProject_Add(deps-libjpeg-turbo
    SOURCE_DIR "${WAIFU2X_SRC_DIR}/libjpeg-turbo"
    BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/libjpeg-turbo"
    INSTALL_DIR "${CMAKE_CURRENT_BINARY_DIR}/deps-install"
    CMAKE_ARGS
        -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
        -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
        -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}
        -DANDROID_ABI=${ANDROID_ABI}
        -DANDROID_PLATFORM=${ANDROID_PLATFORM}
        -DENABLE_SHARED=OFF
        -DENABLE_STATIC=ON
        -DWITH_TURBOJPEG=OFF
    BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --config ${CMAKE_BUILD_TYPE}
    INSTALL_COMMAND ${CMAKE_COMMAND} --install <BINARY_DIR> --config ${CMAKE_BUILD_TYPE}
)

# libwebp
ExternalProject_Add(deps-libwebp
    SOURCE_DIR "${WAIFU2X_SRC_DIR}/libwebp"
    BINARY_DIR "${CMAKE_CURRENT_BINARY_DIR}/libwebp"
    INSTALL_DIR "${CMAKE_CURRENT_BINARY_DIR}/deps-install"
    CMAKE_ARGS
        -DCMAKE_INSTALL_PREFIX=<INSTALL_DIR>
        -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
        -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}
        -DANDROID_ABI=${ANDROID_ABI}
        -DANDROID_PLATFORM=${ANDROID_PLATFORM}
        -DBUILD_SHARED_LIBS=OFF
        -DWEBP_ENABLE_SIMD=ON
        -DWEBP_BUILD_ANIM_UTILS=OFF
        -DWEBP_BUILD_CWEBP=OFF
        -DWEBP_BUILD_DWEBP=OFF
        -DWEBP_BUILD_GIF2WEBP=OFF
        -DWEBP_BUILD_IMG2WEBP=OFF
        -DWEBP_BUILD_VWEBP=OFF
        -DWEBP_BUILD_WEBPINFO=OFF
        -DWEBP_BUILD_WEBPMUX=OFF
        -DWEBP_BUILD_EXTRAS=OFF
        -DWEBP_BUILD_WEBP_JS=OFF
        -DWEBP_NEAR_LOSSLESS=OFF
        -DWEBP_ENABLE_SWAP_16BIT_CSP=OFF
    BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --config ${CMAKE_BUILD_TYPE}
    INSTALL_COMMAND ${CMAKE_COMMAND} --install <BINARY_DIR> --config ${CMAKE_BUILD_TYPE}
)

# Main shared library
add_library(venera_waifu2x SHARED
    venera_waifu2x_jni.cpp
    ${WAIFU2X_SRC_DIR}/waifu2x.cpp
)

add_dependencies(venera_waifu2x generate-spirv deps-libpng deps-libjpeg-turbo deps-libwebp deps-zlib-ng)

target_include_directories(venera_waifu2x PRIVATE
    "${CMAKE_CURRENT_BINARY_DIR}/deps-install/include"
)

target_link_directories(venera_waifu2x PRIVATE
    "${CMAKE_CURRENT_BINARY_DIR}/deps-install/lib"
)

target_link_libraries(venera_waifu2x
    ncnn
    webp webpdecoder webpdemux webpmux sharpyuv
    jpeg
    png
    z
    android
    log
    jnigraphics
    vulkan
)
