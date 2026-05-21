cmake_minimum_required(VERSION 3.18)

project(argon2-gpu CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# ============================================================
#  MSVC runtime: MultiThreadedDLL (/MD)
# ============================================================
if(MSVC)
    set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreadedDLL")
endif()

# ============================================================
#  OpenCL
#  Caller: -DOpenCL_LIBRARY=... -DOpenCL_INCLUDE_DIR=...
# ============================================================
find_package(OpenCL REQUIRED)

# ============================================================
#  CUDA  -- LEGACY find_package(CUDA) approach.
#
#  Не требует CUDA VS Integration / MSBuild files.
#  Ищет через CUDA_TOOLKIT_ROOT_DIR (передаётся из bat).
#  cuda_add_library() компилирует .cu напрямую через nvcc
#  без enable_language(CUDA), поэтому нет "No CUDA toolset found".
# ============================================================
set(HAVE_CUDA FALSE)

if(NOT NO_CUDA)
    find_package(CUDA QUIET)
    if(CUDA_FOUND)
        set(HAVE_CUDA TRUE)
        message(STATUS "CUDA ${CUDA_VERSION} found -- GPU build enabled")
        add_compile_definitions(HAVE_CUDA=1)

        # Архитектуры: Pascal / Turing / Ampere
        set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS}
            -gencode arch=compute_61,code=sm_61
            -gencode arch=compute_75,code=sm_75
            -gencode arch=compute_80,code=sm_80
            -gencode arch=compute_86,code=sm_86
            -gencode arch=compute_86,code=compute_86
            -O3 --ptxas-options=-v -lineinfo
        )
        if(MSVC)
            # nvcc использует тот же /MD что и весь проект
            set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} -Xcompiler=/MD)
        else()
            set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} --compiler-options=-fPIC)
        endif()
    else()
        message(STATUS "CUDA not found -- building without CUDA")
    endif()
endif()

if(NOT HAVE_CUDA)
    add_compile_definitions(HAVE_CUDA=0)
    message(STATUS "Building without CUDA support")
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
#  argon2-cuda -- CUDA backend или stub
# ============================================================
if(HAVE_CUDA)
    # cuda_add_library: legacy macro, не требует enable_language(CUDA)
    cuda_add_library(argon2-cuda STATIC
        lib/argon2-cuda/device.cpp
        lib/argon2-cuda/globalcontext.cpp
        lib/argon2-cuda/programcontext.cpp
        lib/argon2-cuda/processingunit.cpp
        lib/argon2-cuda/kernels.cu
    )
    target_include_directories(argon2-cuda PRIVATE
        ${CUDA_INCLUDE_DIRS}
        include/argon2-cuda
        lib/argon2-cuda
    )
    target_link_libraries(argon2-cuda
        PUBLIC  argon2-gpu-common
        PRIVATE ${CUDA_LIBRARIES}
    )
else()
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
#  mm_gpu_gate -- итоговая shared library
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
    target_link_libraries(mm_gpu_gate PRIVATE ${CUDA_LIBRARIES})
endif()

if(MSVC)
    set_target_properties(mm_gpu_gate PROPERTIES
        PREFIX        "lib"
        SUFFIX        ".dll"
        IMPORT_PREFIX "lib"
        IMPORT_SUFFIX ".dll.a"
    )
elseif(MINGW)
    set_target_properties(mm_gpu_gate PROPERTIES
        PREFIX "lib"
        SUFFIX ".dll"
    )
endif()
