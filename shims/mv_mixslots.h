// Producer slots of the runtime's audio mixer (runtime/media/kl_audio.c,
// overlay step 165). Header-only so the runtime and the host test compile the
// same code.
//
// The mixer keeps, per producer key (an OpenSL player, an AAudio stream, the
// video plugin's mix), the ring frame that producer writes next. Only the
// producers touch these slots, all under the mixer's write lock; the render
// thread reads the ring and never a slot, so a slot can change at any time the
// caller holds that lock.
//
// A slot is IDLE when its next write position is behind the reader or beyond
// the ring (a cursor from before the device was reopened, whose counters
// restart at 0). Such a producer has nothing left to play, and its next write
// resyncs against the reader whatever the slot says, so taking the slot from
// it changes nothing audible: if it writes again it registers anew. A slot
// whose producer still has audio ahead of the reader is LIVE and is never
// taken.
#pragma once
#include <stdint.h>

#define MV_MIX_MAX_SRC 16

static inline int mv_mix_slot_idle(uint64_t pos, uint64_t r0, uint64_t cap) {
    return pos < r0 || pos > r0 + cap;
}

// The slot for `key` (non-NULL): its own, else a free one, else an idle one
// (*reclaimed = 1). -1 when every slot is live: the caller must not mix this
// producer, and nothing live is evicted.
static inline int mv_mix_slot_get(const void **keys, uint64_t *pos, int *n, int max,
                                  const void *key, uint64_t r0, uint64_t cap,
                                  int *reclaimed) {
    if (reclaimed) *reclaimed = 0;
    for (int i = 0; i < *n; i++)
        if (keys[i] == key) return i;
    if (*n < max) {
        keys[*n] = key;
        pos[*n] = 0;
        return (*n)++;
    }
    for (int i = 0; i < *n; i++) {
        if (!mv_mix_slot_idle(pos[i], r0, cap)) continue;
        keys[i] = key;
        pos[i] = 0;
        if (reclaimed) *reclaimed = 1;
        return i;
    }
    return -1;
}

// Gives `key`'s slot back; the others keep their cursors. 1 if it held one,
// 0 if not (already released, reclaimed, or never registered).
static inline int mv_mix_slot_release(const void **keys, uint64_t *pos, int *n,
                                      const void *key) {
    if (!key) return 0;
    for (int i = 0; i < *n; i++) {
        if (keys[i] != key) continue;
        for (int j = i; j + 1 < *n; j++) {
            keys[j] = keys[j + 1];
            pos[j] = pos[j + 1];
        }
        (*n)--;
        keys[*n] = 0;
        pos[*n] = 0;
        return 1;
    }
    return 0;
}
