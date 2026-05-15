cmake_minimum_required(VERSION 3.10)
project(flutter_live2d C CXX)

set(CMAKE_CXX_STANDARD 14)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# All paths are relative to android/ (this file's directory)
set(CPP_PATH       ${CMAKE_CURRENT_SOURCE_DIR}/src/main/cpp)
set(CORE_INC       ${CPP_PATH}/CubismCore/include)
set(FRAMEWORK_PATH ${CPP_PATH}/CubismFramework)
set(STB_PATH       ${CPP_PATH})          # stb_image.h is copied here
set(CORE_LIB_PATH  ${CMAKE_CURRENT_SOURCE_DIR}/libs/${ANDROID_ABI}/libLive2DCubismCore.a)

# ---- Cubism Core (embedded static library) ----
add_library(Live2DCubismCore STATIC IMPORTED)
set_target_properties(Live2DCubismCore PROPERTIES
  IMPORTED_LOCATION           ${CORE_LIB_PATH}
  INTERFACE_INCLUDE_DIRECTORIES ${CORE_INC}
)

# ---- Cubism Framework (OpenGL ES2 renderer) ----
# Build Framework as a static lib from embedded sources
file(GLOB_RECURSE FRAMEWORK_SOURCES
  "${FRAMEWORK_PATH}/*.cpp"
)
# Exclude D3D / Vulkan / Metal backends that don't apply to Android
list(FILTER FRAMEWORK_SOURCES EXCLUDE REGEX ".*/D3D9/.*")
list(FILTER FRAMEWORK_SOURCES EXCLUDE REGEX ".*/D3D11/.*")
list(FILTER FRAMEWORK_SOURCES EXCLUDE REGEX ".*/Vulkan/.*")
list(FILTER FRAMEWORK_SOURCES EXCLUDE REGEX ".*/Metal/.*")

add_library(CubismFramework STATIC ${FRAMEWORK_SOURCES})
target_include_directories(CubismFramework
  PUBLIC  ${FRAMEWORK_PATH}
  PRIVATE ${CORE_INC}
)
target_compile_definitions(CubismFramework PUBLIC CSM_TARGET_ANDROID_ES2)

# ---- flutter_live2d plugin shared library ----
add_library(flutter_live2d SHARED
  ${CPP_PATH}/live2d_flutter.cpp
  ${CPP_PATH}/Live2DAllocator.cpp
  ${CPP_PATH}/Live2DPal.cpp
  ${CPP_PATH}/Live2DTextureManager.cpp
  ${CPP_PATH}/Live2DModel.cpp
)

target_include_directories(flutter_live2d
  PRIVATE
    ${CPP_PATH}
    ${CORE_INC}
    ${STB_PATH}
)

target_link_libraries(flutter_live2d
  CubismFramework
  Live2DCubismCore
  GLESv2
  EGL
  log
  android
)

# 16 KB page-size alignment (compatible with CMake 3.10)
set_target_properties(flutter_live2d PROPERTIES LINK_FLAGS "-Wl,-z,max-page-size=16384")
