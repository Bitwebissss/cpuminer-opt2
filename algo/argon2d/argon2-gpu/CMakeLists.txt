cmake_minimum_required(VERSION 3.18...4.0)

project(argon2-gpu CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ============================================================
#  MSVC runtime: MultiThreadedDLL (/MD) to prevent LNK2038.
#  Must be set BEFORE enable_language(CUDA) so nvcc inherits it.
# ============================================================
if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
endif()

# ============================================================
#  OpenCL
#  Caller passes: -DOpenCL_LIBRARY=... -DOpenCL_INCLUDE_DIR=...
# ============================================================
find_package(OpenCL REQUIRED)

# ============================================================
#  CUDA (modern CUDAToolkit, requires CMake 3.17+)
#  Caller passes: -DNO_CUDA=FALSE to enable GPU build.
# ============================================================
set(HAVE_CUDA FALSE)

if(NOT NO_CUDA)
    find_package(CUDAToolkit QUIET)
    if(CUDAToolkit_FOUND)
        set(CMAKE_CUDA_ARCHITECTURES 61 75 80 86-real 86-virtual)
        enable_language(CUDA)
        set(HAVE_CUDA TRUE)
        message(STATUS "CUDA ${CUDAToolkit_VERSION} found -- GPU build enabled")
        add_compile_definitions(HAVE_CUDA=1)
    else()
        message(STATUS "CUDAToolkit not found -- building without CUDA")
    endif()
endif()

if(NOT HAVE_CUDA)
    add_compile_definitions(HAVE_CUDA=0)
    message(STATUS "Building without CUDA support")
endif()

# ============================================================
#  CUDA compiler flags
# ============================================================
if(HAVE_CUDA)
    set(CUDA_EXTRA_FLAGS -O3 --ptxas-options=-v -lineinfo)
    if(MSVC)
        list(APPEND CUDA_EXTRA_FLAGS -Xcompiler=/MD)
    else()
        list(APPEND CUDA_EXTRA_FLAGS --compiler-options=-fPIC)
    endif()
endif()

# ============================================================
#  argon2-gpu-common
# ============================================================
add_library(argon2-gpu-common STATIC
    lib/argon2-gpu-common/argon2params.cpp
    lib/argon2-gpu-common/blake2b.cpp
)
target_include_directories(argon2-gpu-common
    PUBLIC
        $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    PRIVATE
        include/argon2-gpu-common
        lib/argon2-gpu-common
)

# ============================================================
#  argon2-cuda -- CUDA backend or stub (nocuda.cpp)
#
#  nocuda.cpp is a BUILD-TIME stub: used when CUDA SDK is absent
#  (NO_CUDA=TRUE) so the build succeeds without CUDA support.
#  It is NOT a runtime fallback — for runtime AMD/OpenCL support
#  on a CUDA-enabled build, /DELAYLOAD:nvcuda.dll handles that.
# ============================================================
if(HAVE_CUDA)
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
        $<$<COMPILE_LANGUAGE:CUDA>:${CUDA_EXTRA_FLAGS}>
    )
    target_include_directories(argon2-cuda PRIVATE
        ${CUDAToolkit_INCLUDE_DIRS}
        include/argon2-cuda
        lib/argon2-cuda
    )
    target_link_libraries(argon2-cuda
        PUBLIC  argon2-gpu-common
        PRIVATE CUDA::cudart_static
    )
else()
    # nocuda.cpp = intentionally empty file, produces an empty .a
    # so that targets linking argon2-cuda don't break when CUDA SDK
    # is not installed on the build machine.
    add_library(argon2-cuda STATIC
        lib/argon2-cuda/nocuda.cpp
    )
    target_include_directories(argon2-cuda PRIVATE
        include/argon2-cuda
        lib/argon2-cuda
    )
    target_link_libraries(argon2-cuda PUBLIC argon2-gpu-common)
endif()

target_include_directories(argon2-cuda
    PUBLIC $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
)

# ============================================================
#  argon2-opencl -- OpenCL backend
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
    PUBLIC  $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
    PRIVATE include/argon2-opencl
            lib/argon2-opencl
)
target_link_libraries(argon2-opencl
    PUBLIC  argon2-gpu-common
    PRIVATE OpenCL::OpenCL
)

# ============================================================
#  mm_gpu_gate -- final shared library
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
    PRIVATE
        argon2-cuda
        argon2-opencl
        argon2-gpu-common
        OpenCL::OpenCL
)

if(HAVE_CUDA)
    target_link_libraries(mm_gpu_gate PRIVATE CUDA::cudart_static)
    if(MSVC)
        # /DELAYLOAD:nvcuda.dll — nvcuda.dll is the NVIDIA driver DLL.
        # Without delay-load it appears in the import table and Windows
        # tries to resolve it at startup, which fails on AMD/Intel systems
        # where no NVIDIA driver is installed.
        #
        # With delay-load, nvcuda.dll is resolved only on the first actual
        # CUDA call. The gate already routes all calls through use_gpu[0]=='C',
        # so on OpenCL systems nvcuda.dll is never touched at all.
        #
        # delayimp.lib provides __delayLoadHelper2 (built into MSVC SDK,
        # no extra download needed).
        target_link_options(mm_gpu_gate PRIVATE
            /DELAYLOAD:nvcuda.dll
            /NODEFAULTLIB:LIBCMT
        )
        target_link_libraries(mm_gpu_gate PRIVATE delayimp)
    endif()
endif()

# bat expects the output named libmm_gpu_gate.dll
if(MSVC)
    set_target_properties(mm_gpu_gate PROPERTIES
        PREFIX        "lib"
        SUFFIX        ".dll"
        IMPORT_PREFIX "lib"
        IMPORT_SUFFIX ".dll.a"
    )
endif()
