#ifndef ARGON2D_GPU_GATE_H
#define ARGON2D_GPU_GATE_H

#include "gpu_detection.h"

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

#ifdef __cplusplus
}
#endif

#endif
