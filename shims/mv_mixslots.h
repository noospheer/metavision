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
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <time.h>

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

// ---- the gate between writers and whoever replaces the ring (step 168) ----
//
// A write holds the mixer's write lock for its whole length, including its
// wait for room in the ring. Closing, reopening or rebuilding the device frees
// and replaces the ring, so it must exclude writes: it raises `excl` (a writer
// waiting for room sees it and returns short at once, as on a stop) and then
// takes the write lock, so it never waits out a writer's full deadline. A
// writer re-checks that the device is open once it holds the lock. The device
// can be rebuilt from inside a write (the writer's own watchdog); that thread
// already holds the lock and is marked in-write, so it does not take it again.
static _Thread_local int mv_mix_in_write;

// A writer arriving while the ring is being replaced stands back until it is
// done: the lock is not fair, and a feeder that writes back to back would
// otherwise take it again ahead of the closer, over and over.
static inline void mv_mix_write_enter(pthread_mutex_t *wlock, atomic_int *excl) {
    while (atomic_load_explicit(excl, memory_order_acquire) > 0) {
        struct timespec t = {0, 500000};
        nanosleep(&t, NULL);
    }
    pthread_mutex_lock(wlock);
    mv_mix_in_write = 1;
}
static inline void mv_mix_write_leave(pthread_mutex_t *wlock) {
    mv_mix_in_write = 0;
    pthread_mutex_unlock(wlock);
}
// A writer waiting for room gives up when this is set.
static inline int mv_mix_write_yield(atomic_int *excl) {
    return atomic_load_explicit(excl, memory_order_acquire) > 0;
}
// Returns whether it took the lock (pass that to mv_mix_admit).
static inline int mv_mix_exclude(pthread_mutex_t *wlock, atomic_int *excl) {
    if (mv_mix_in_write) return 0;
    atomic_fetch_add_explicit(excl, 1, memory_order_acq_rel);
    pthread_mutex_lock(wlock);
    return 1;
}
static inline void mv_mix_admit(pthread_mutex_t *wlock, atomic_int *excl, int took) {
    if (!took) return;
    pthread_mutex_unlock(wlock);
    atomic_fetch_sub_explicit(excl, 1, memory_order_acq_rel);
}
