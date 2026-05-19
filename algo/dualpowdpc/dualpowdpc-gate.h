#ifndef DUALPOWDPC_GATE_H__
#define DUALPOWDPC_GATE_H__

#include "algo-gate-api.h"
#include <stdint.h>
#include <stdbool.h>

bool register_dualpowdpc_algo(algo_gate_t *gate);

int scanhash_dualpowdpc(struct work *work, uint32_t max_nonce,
                        uint64_t *hashes_done, struct thr_info *mythr);

#endif /* DUALPOWDPC_GATE_H__ */
