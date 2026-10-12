// Host test for mv_mixslots.h, the audio mixer's producer slots: register,
// release, reuse, a full table, producers coming and going on several threads
// under one write lock while a reader advances (as in kl_audio.c), and the
// gate that lets a close free the ring under writers waiting in it.
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
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

// ---- the gate: close/reopen frees the ring while writers wait in it ----
static pthread_mutex_t gwlock = PTHREAD_MUTEX_INITIALIZER;
static atomic_int gexcl;
static float *gring;                   // touched only under gwlock
static int gopen;
static _Atomic int gstop;
static _Atomic long gwrites, gbailed;

static uint64_t now_ms(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}
static void nap_ms(int ms) { struct timespec t = {0, ms * 1000000L}; nanosleep(&t, NULL); }

static void *gate_writer(void *a) {
    (void)a;
    while (!atomic_load(&gstop)) {
        mv_mix_write_enter(&gwlock, &gexcl);
        if (!gopen || !gring) { mv_mix_write_leave(&gwlock); nap_ms(1); continue; }
        // a device rebuilt from inside the write (the writer's watchdog) does
        // not take the lock again
        int took = mv_mix_exclude(&gwlock, &gexcl);
        assert(!took);
        mv_mix_admit(&gwlock, &gexcl, took);
        // the ring is full and nothing drains it: wait as kl_audio does, up to
        // a 2 s deadline, unless someone needs the ring
        uint64_t deadline = now_ms() + 2000;
        while (!mv_mix_write_yield(&gexcl) && now_ms() < deadline) nap_ms(2);
        if (mv_mix_write_yield(&gexcl)) atomic_fetch_add(&gbailed, 1);
        memset(gring, 0, 4096 * sizeof(float));   // still ours: no one freed it
        atomic_fetch_add(&gwrites, 1);
        mv_mix_write_leave(&gwlock);
    }
    return NULL;
}

static void gate(void) {
    gring = calloc(4096, sizeof(float)); gopen = 1;
    pthread_t w[4];
    for (int i = 0; i < 4; i++) pthread_create(&w[i], NULL, gate_writer, NULL);
    nap_ms(20);
    uint64_t worst = 0;
    for (int round = 0; round < 100; round++) {
        uint64_t t0 = now_ms();
        int took = mv_mix_exclude(&gwlock, &gexcl);          // close
        uint64_t waited = now_ms() - t0;
        if (waited > worst) worst = waited;
        assert(took);
        free(gring); gring = NULL; gopen = 0;
        mv_mix_admit(&gwlock, &gexcl, took);
        took = mv_mix_exclude(&gwlock, &gexcl);              // open again
        gring = calloc(4096, sizeof(float)); gopen = 1;
        mv_mix_admit(&gwlock, &gexcl, took);
        nap_ms(3);
    }
    atomic_store(&gstop, 1);
    for (int i = 0; i < 4; i++) pthread_join(w[i], NULL);
    free(gring);
    // writers parked in their wait were let out at once, not after the deadline
    assert(worst < 500);
    assert(atomic_load(&gbailed) > 0);
    printf("t_mixslots: gate ok (100 close/open with 4 waiting writers, worst wait %llu ms, "
           "%ld writes, %ld let out early)\n", (unsigned long long)worst,
           atomic_load(&gwrites), atomic_load(&gbailed));
}

int main(void) {
    basics();
    threads();
    gate();
    printf("t_mixslots: ok (%d slots; threaded run: %ld writes, %ld reclaimed, %ld refused)\n",
           MV_MIX_MAX_SRC, atomic_load(&writes), atomic_load(&reclaimed_n),
           atomic_load(&refused));
    return 0;
}
