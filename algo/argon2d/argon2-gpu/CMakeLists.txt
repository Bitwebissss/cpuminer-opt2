cmake_minimum_required(VERSION 3.18)

project(argon2-gpu CXX)
set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ============================================================
#  OpenCL
# ============================================================
find_package(OpenCL REQUIRED)

# ============================================================
#  CUDA — modern CUDAToolkit (CMake 3.17+, no FindCUDA)
# ============================================================
set(CUDA_FOUND FALSE)
if(NOT NO_CUDA)
    include(CheckLanguage)
    check_language(CUDA)
    if(CMAKE_CUDA_COMPILER)
        enable_language(CUDA)
        find_package(CUDAToolkit REQUIRED)
        set(CUDA_FOUND TRUE)
        message(STATUS "Using CUDA version ${CUDAToolkit_VERSION}")
        add_definitions(-DHAVE_CUDA=1)
        set(CMAKE_CUDA_STANDARD 17)
        set(CMAKE_CUDA_STANDARD_REQUIRED ON)
        # sm_61 GTX10xx | sm_75 RTX20xx | sm_80 A100 | sm_86 RTX30xx
        # 86-virtual = embed PTX so future GPUs (SM89, SM90...) can JIT-compile
        set(CMAKE_CUDA_ARCHITECTURES 61-real 75-real 80-real 86-real 86-virtual)
    else()
        message(STATUS "Building without CUDA support")
        add_definitions(-DHAVE_CUDA=0)
    endif()
else()
    message(STATUS "Building without CUDA support (NO_CUDA=TRUE)")
    add_definitions(-DHAVE_CUDA=0)
endif()

# ============================================================
#  argon2 submodule
# ============================================================
add_subdirectory(ext/argon2)

# ============================================================
#  Static helper libraries
# ============================================================
add_library(argon2-gpu-common STATIC
    lib/argon2-gpu-common/argon2params.cpp
    lib/argon2-gpu-common/blake2b.cpp
)
target_include_directories(argon2-gpu-common
    INTERFACE $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
              $<INSTALL_INTERFACE:include>
    PRIVATE   include/argon2-gpu-common
              lib/argon2-gpu-common
)
include_directories(include)

# ============================================================
#  CUDA backend
# ============================================================
if(CUDA_FOUND)
    add_library(argon2-cuda STATIC
        lib/argon2-cuda/device.cpp
        lib/argon2-cuda/globalcontext.cpp
        lib/argon2-cuda/programcontext.cpp
        lib/argon2-cuda/processingunit.cpp
        lib/argon2-cuda/kernels.cu
    )
    set_target_properties(argon2-cuda PROPERTIES
        CUDA_STANDARD 17
        CUDA_STANDARD_REQUIRED ON
        CUDA_SEPARABLE_COMPILATION OFF
    )
    target_compile_options(argon2-cuda PRIVATE
        $<$<COMPILE_LANGUAGE:CUDA>:--ptxas-options=-v;-lineinfo;-O3>
    )
    target_link_libraries(argon2-cuda CUDA::cudart)
else()
    add_library(argon2-cuda STATIC lib/argon2-cuda/nocuda.cpp)
endif()

target_include_directories(argon2-cuda
    INTERFACE $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
              $<INSTALL_INTERFACE:include>
    PRIVATE   include/argon2-cuda
              lib/argon2-cuda
)
target_link_libraries(argon2-cuda argon2-gpu-common)

# ============================================================
#  OpenCL backend
# ============================================================
add_library(argon2-opencl STATIC
    lib/argon2-opencl/device.cpp
    lib/argon2-opencl/globalcontext.cpp
    lib/argon2-opencl/kernelloader.cpp
    lib/argon2-opencl/programcontext.cpp
    lib/argon2-opencl/processingunit.cpp
    lib/argon2-opencl/kernelrunner.cpp
)
target_include_directories(argon2-opencl
    INTERFACE $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
              $<INSTALL_INTERFACE:include>
    PRIVATE   include/argon2-opencl
              lib/argon2-opencl
)
target_link_libraries(argon2-opencl argon2-gpu-common OpenCL::OpenCL)

# ============================================================
#  mm_gpu_gate — shared library (the actual GPU gate)
# ============================================================
set(GATE_SOURCE ${CMAKE_CURRENT_SOURCE_DIR}/../argon2d-gpu-gate.cpp)
if(NOT EXISTS ${GATE_SOURCE})
    message(FATAL_ERROR "Cannot find ../argon2d-gpu-gate.cpp")
endif()

add_library(mm_gpu_gate SHARED ${GATE_SOURCE})
target_compile_definitions(mm_gpu_gate PRIVATE EXPORT_SYMBOLS)
target_include_directories(mm_gpu_gate PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/include/argon2-gpu-common
    ${CMAKE_CURRENT_SOURCE_DIR}/include/argon2-cuda
    ${CMAKE_CURRENT_SOURCE_DIR}/include/argon2-opencl
)
target_link_libraries(mm_gpu_gate
    argon2-cuda
    argon2-opencl
    argon2-gpu-common
    OpenCL::OpenCL
)
if(CUDA_FOUND)
    target_link_libraries(mm_gpu_gate CUDA::cudart)
endif()

# Output naming: ensure prefix is "lib" so configure.ac finds libmm_gpu_gate
if(MSVC)
    set_target_properties(mm_gpu_gate PROPERTIES
        PREFIX "lib" SUFFIX ".dll"
        IMPORT_PREFIX "lib" IMPORT_SUFFIX ".dll.a")
elseif(MINGW)
    set_target_properties(mm_gpu_gate PROPERTIES
        PREFIX "lib" SUFFIX ".dll")
endif()
