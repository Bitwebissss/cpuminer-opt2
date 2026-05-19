#ifndef GPU_DETECTION_H
#define GPU_DETECTION_H

#include <stdbool.h>
#include <stdint.h>

#ifdef USE_GPU

#ifdef WIN32
    #ifdef EXPORT_SYMBOLS
        #define GPU_API __declspec(dllexport)
    #else
        #define GPU_API __declspec(dllimport)
    #endif
#else
    #define GPU_API
#endif

GPU_API int  check_gpu_capability(char *use_gpu, char *gpu_id, int batch_size, int threads);
GPU_API void *get_gpu_thread_data(int thr_id);
GPU_API void gpu_argon2_raw_hash(void *thread_data);
GPU_API bool init_thread_argon2id1024_gpu(int thr_id);

#endif /* USE_GPU */
#endif /* GPU_DETECTION_H */
