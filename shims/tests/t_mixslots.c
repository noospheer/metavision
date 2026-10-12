// Host test for mv_mixslots.h, the audio mixer's producer slots: register,
// release, reuse, a full table, and producers coming and going on several
// threads under one write lock while a reader advances (as in kl_audio.c).
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include "../mv_mixslots.h"

#define CAP 48001u

static const void *keys[MV_MIX_MAX_SRC];
static uint64_t    pos[MV_MIX_MAX_SRC];
static int         n;

static int get(const void *k, uint64_t r0, int *rec) {
    return mv_mix_slot_get(keys, pos, &n, MV_MIX_MAX_SRC, k, r0, CAP, rec);
}

static void basics(void) {
    static char k[MV_MIX_MAX_SRC + 4];
    int rec;
    // register, find again, release, idempotent release
    assert(get(&k[0], 0, &rec) == 0 && !rec && n == 1);
    assert(get(&k[0], 0, &rec) == 0 && n == 1);
    assert(mv_mix_slot_release(keys, pos, &n, &k[0]) == 1 && n == 0);
    assert(mv_mix_slot_release(keys, pos, &n, &k[0]) == 0 && n == 0);
    assert(mv_mix_slot_release(keys, pos, &n, NULL) == 0);

    // fill every slot with live producers (cursor ahead of the reader)
    uint64_t r0 = 1000;
    for (int i = 0; i < MV_MIX_MAX_SRC; i++) {
        int s = get(&k[i], r0, &rec);
        assert(s == i && !rec);
        pos[s] = r0 + 100 + (uint64_t)i;
    }
    assert(n == MV_MIX_MAX_SRC);
    // one more: refused, and nothing live is taken
    assert(get(&k[MV_MIX_MAX_SRC], r0, &rec) == -1 && !rec);
    for (int i = 0; i < MV_MIX_MAX_SRC; i++) assert(keys[i] == &k[i]);

    // releasing one in the middle keeps the others' cursors with their keys
    assert(mv_mix_slot_release(keys, pos, &n, &k[5]) == 1 && n == MV_MIX_MAX_SRC - 1);
    for (int i = 0; i < n; i++) {
        int orig = (int)((const char *)keys[i] - k);
        assert(orig != 5 && pos[i] == r0 + 100 + (uint64_t)orig);
    }
    // ...and the freed slot is reused by the next newcomer
    int s = get(&k[MV_MIX_MAX_SRC], r0, &rec);
    assert(s == MV_MIX_MAX_SRC - 1 && !rec && n == MV_MIX_MAX_SRC);
    pos[s] = r0 + 50;

    // a producer that fell behind the reader is idle: its slot is reclaimed
    pos[3] = r0 - 1;
    s = get(&k[MV_MIX_MAX_SRC + 1], r0, &rec);
    assert(s == 3 && rec && keys[3] == &k[MV_MIX_MAX_SRC + 1] && pos[3] == 0);
    // the reclaimed producer comes back: refused (all live again), not merged
    pos[3] = r0 + 10;
    assert(get(&k[3], r0, &rec) == -1);
    // its release is a no-op: the slot is someone else's now
    assert(mv_mix_slot_release(keys, pos, &n, &k[3]) == 0 && keys[3] == &k[MV_MIX_MAX_SRC + 1]);

    // a cursor from before a device reopen (beyond the ring) is idle too
    pos[7] = r0 + CAP + 1;
    assert(get(&k[MV_MIX_MAX_SRC + 2], r0, &rec) == 7 && rec);
    pos[7] = r0 + 10;
    // a producer exactly at the reader still has its slot
    pos[8] = r0;
    assert(get(&k[MV_MIX_MAX_SRC + 3], r0, &rec) == -1);

    while (n) mv_mix_slot_release(keys, pos, &n, keys[0]);
}

// ---- threads: producers come and go, a reader advances ----
#define PRODUCERS 24      // more than the slots, so the table fills and refuses
#define ROUNDS    4000

static pthread_mutex_t wlock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t g_r;
static _Atomic int done;
static _Atomic long refused, reclaimed_n, writes;

static void *reader(void *a) {
    (void)a;
    while (!atomic_load(&done)) atomic_fetch_add(&g_r, 7);
    return NULL;
}

static void *producer(void *a) {
    char key;                              // a distinct address per producer
    (void)a;
    for (int round = 0; round < ROUNDS; round++) {
        pthread_mutex_lock(&wlock);
        uint64_t r0 = atomic_load(&g_r);
        int rec;
        int s = mv_mix_slot_get(keys, pos, &n, MV_MIX_MAX_SRC, &key, r0, CAP, &rec);
        if (s < 0) {
            atomic_fetch_add(&refused, 1);
        } else {
            if (rec) atomic_fetch_add(&reclaimed_n, 1);
            assert(keys[s] == &key);
            // no key is ever in two slots
            for (int i = 0; i < n; i++) assert(i == s || keys[i] != &key);
            assert(n <= MV_MIX_MAX_SRC);
            pos[s] = r0 + 64;              // a write: audio ahead of the reader
            atomic_fetch_add(&writes, 1);
        }
        // every so often the producer is destroyed (released) or just stops
        if (round % 13 == 0) mv_mix_slot_release(keys, pos, &n, &key);
        pthread_mutex_unlock(&wlock);
    }
    pthread_mutex_lock(&wlock);
    mv_mix_slot_release(keys, pos, &n, &key);
    // the release is idempotent, and nothing of ours is left behind
    assert(mv_mix_slot_release(keys, pos, &n, &key) == 0);
    for (int i = 0; i < n; i++) assert(keys[i] != &key);
    pthread_mutex_unlock(&wlock);
    return NULL;
}

static void threads(void) {
    pthread_t rd, p[PRODUCERS];
    pthread_create(&rd, NULL, reader, NULL);
    for (int i = 0; i < PRODUCERS; i++) pthread_create(&p[i], NULL, producer, NULL);
    for (int i = 0; i < PRODUCERS; i++) pthread_join(p[i], NULL);
    atomic_store(&done, 1);
    pthread_join(rd, NULL);
    assert(n == 0);                        // every producer released its slot
    assert(atomic_load(&writes) > 0);
}

int main(void) {
    basics();
    threads();
    printf("t_mixslots: ok (%d slots; threaded run: %ld writes, %ld reclaimed, %ld refused)\n",
           MV_MIX_MAX_SRC, atomic_load(&writes), atomic_load(&reclaimed_n),
           atomic_load(&refused));
    return 0;
}
