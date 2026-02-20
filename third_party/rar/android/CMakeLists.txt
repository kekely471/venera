cmake_minimum_required(VERSION 3.10)

project(rar_native)

# Fetch libarchive
include(FetchContent)

set(LIBARCHIVE_VERSION "3.7.2")
set(LIBARCHIVE_LOCAL_ARCHIVE "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libarchive-${LIBARCHIVE_VERSION}.tar.gz")
set(LIBARCHIVE_REMOTE_ARCHIVE "https://codeload.github.com/libarchive/libarchive/tar.gz/refs/tags/v${LIBARCHIVE_VERSION}")

if(EXISTS "${LIBARCHIVE_LOCAL_ARCHIVE}")
  set(LIBARCHIVE_ARCHIVE_URL "${LIBARCHIVE_LOCAL_ARCHIVE}")
else()
  set(LIBARCHIVE_ARCHIVE_URL "${LIBARCHIVE_REMOTE_ARCHIVE}")
endif()

FetchContent_Declare(
  libarchive
  URL "${LIBARCHIVE_ARCHIVE_URL}"
  TIMEOUT 180
  INACTIVITY_TIMEOUT 30
)

FetchContent_GetProperties(libarchive)
if(NOT libarchive_POPULATED)
  FetchContent_Populate(libarchive)
  
  # Configure libarchive to build only what we need
  set(ENABLE_TEST OFF CACHE BOOL "" FORCE)
  set(ENABLE_TAR OFF CACHE BOOL "" FORCE)
  set(ENABLE_CPIO OFF CACHE BOOL "" FORCE)
  set(ENABLE_CAT OFF CACHE BOOL "" FORCE)
  set(ENABLE_XATTR OFF CACHE BOOL "" FORCE)
  set(ENABLE_ACL OFF CACHE BOOL "" FORCE)
  set(ENABLE_ICONV OFF CACHE BOOL "" FORCE)
  set(ENABLE_EXPAT OFF CACHE BOOL "" FORCE)
  set(ENABLE_LIBXML2 OFF CACHE BOOL "" FORCE)
  
  # We only need RAR support
  # Note: libarchive's RAR support is built-in, but we might need zlib/lzma/etc for other formats
  # For now, we rely on minimal dependencies
  
  add_subdirectory(${libarchive_SOURCE_DIR} ${libarchive_BINARY_DIR} EXCLUDE_FROM_ALL)
endif()

# Define our native library
add_library(rar_native SHARED
    ../src/rar_native.c
)

# Include directories
target_include_directories(rar_native PRIVATE
    ../src
    ${libarchive_SOURCE_DIR}/libarchive
    ${libarchive_BINARY_DIR} # For config.h
)

# Link against libarchive
target_link_libraries(rar_native
    archive_static
    log
)
