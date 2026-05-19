#ifndef ARGON2D_GPU_GATE_H
#define ARGON2D_GPU_GATE_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef WIN32
#define DLLEXPORT
#else
    #ifdef EXPORT_SYMBOLS
        #define DLLEXPORT __declspec(dllexport)
    #else
        #define DLLEXPORT __declspec(dllimport)
    #endif
#endif

typedef struct argon2_gpu_hasher_thread_ {
    void *processing_unit;
    uint32_t *vhash;
    uint32_t *endiandata;
} argon2_gpu_hasher_thread;

DLLEXPORT int                      check_gpu_capability(char *use_gpu, char *gpu_id, int batch_size, int threads);
DLLEXPORT argon2_gpu_hasher_thread *get_gpu_thread_data(int thr_id);
DLLEXPORT void                     gpu_argon2_raw_hash(argon2_gpu_hasher_thread *thread_data);
DLLEXPORT bool                     init_thread_argon2id1024_gpu(int thr_id);

#ifdef __cplusplus
}
#endif

#endif /* ARGON2D_GPU_GATE_H */
