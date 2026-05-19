#ifndef GPU_DETECTION_H
#define GPU_DETECTION_H

#ifdef USE_GPU

#include <stdbool.h>
#include <stdint.h>

#ifdef WIN32
    #ifdef EXPORT_SYMBOLS
        #define GPU_API __declspec(dllexport)
    #else
        #define GPU_API __declspec(dllimport)
    #endif
#else
    #define GPU_API
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* Only check_gpu_capability is called from cpu-miner.c */
GPU_API int check_gpu_capability(char *use_gpu, char *gpu_id, int batch_size, int threads);

#ifdef __cplusplus
}
#endif

#endif /* USE_GPU */
#endif /* GPU_DETECTION_H */
