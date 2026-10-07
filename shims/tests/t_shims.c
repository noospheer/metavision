// Host test for mv_shims.c: stand-ins for the three Klepton symbols it uses,
// then each shim with behaviour worth checking.
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "../mv_shims.h"

// ---- Klepton stand-ins ----
void *(*kl_shim_override)(const char *name);
static int g_dlopen_flags = -1;
static void *fake_dlopen(const char *p, int f) { (void)p; g_dlopen_flags = f; return (void *)0x1234; }
static ssize_t fake_pread(int fd, void *b, size_t n, int64_t off) { (void)fd; memset(b, 'x', n); return (ssize_t)n + (ssize_t)off; }
void *kl_shim_lookup(const char *name) {
    if (kl_shim_override) { void *o = kl_shim_override(name); if (o) return o; }
    if (!strcmp(name, "dlopen")) return (void *)fake_dlopen;
    if (!strcmp(name, "pread")) return (void *)fake_pread;
    return NULL;
}
FILE *kl_host_file(void *g) { return (FILE *)g; }
static int g_real_dlopen_calls;
// Klepton's own dlopen: android_dlopen_ext reaches it through the dlopen wrapper.
void *klb_dlopen(const char *p, int f) { (void)p; g_real_dlopen_calls++; g_dlopen_flags = f; return (void *)0x1234; }
void *klb_dlsym(void *h, const char *n) { (void)h; (void)n; return (void *)0x9abc; }

#define FN(t, n) ((t)mv_lookup(n))

static void *barrier_worker(void *b) {
    int (*w)(void *) = FN(int (*)(void *), "pthread_barrier_wait");
    return (void *)(intptr_t)w(b);
}

int main(void) {
    // installed by the constructor, and answers through the override
    assert(kl_shim_override != NULL);
    assert(kl_shim_lookup("ptrace") == mv_lookup("ptrace"));
    assert(mv_lookup("definitely_not_a_shim") == NULL);

    // names are unique
    for (size_t i = 0; i < mv_shim_count; i++)
        for (size_t j = i + 1; j < mv_shim_count; j++)
            assert(strcmp(mv_shim_table[i].name, mv_shim_table[j].name) != 0);

    // ptrace: EPERM
    long (*pt)(int, int, void *, void *) = FN(long (*)(int, int, void *, void *), "ptrace");
    errno = 0; assert(pt(0, 0, 0, 0) == -1 && errno == EPERM);

    // android_dlopen_ext forwards flags unchanged to the guest dlopen (via the wrapper)
    void *(*dle)(const char *, int, const void *) = FN(void *(*)(const char *, int, const void *), "android_dlopen_ext");
    assert(dle("libfoo.so", 0x102, (void *)1) == (void *)0x1234 && g_dlopen_flags == 0x102);

    // __pread_chk forwards to the guest pread
    char buf[8];
    ssize_t (*prc)(int, void *, size_t, int64_t, size_t) = FN(ssize_t (*)(int, void *, size_t, int64_t, size_t), "__pread_chk");
    assert(prc(3, buf, 4, 10, sizeof buf) == 14 && buf[0] == 'x');

    // __strlcpy_chk truncates and returns the source length
    size_t (*slc)(char *, const char *, size_t, size_t) = FN(size_t (*)(char *, const char *, size_t, size_t), "__strlcpy_chk");
    char d[4]; assert(slc(d, "abcdef", sizeof d, sizeof d) == 6 && !strcmp(d, "abc"));

    // barrier: exactly one serial thread per cycle, reusable
    uint64_t storage[4] = {0};
    int (*bi)(void *, const void *, unsigned) = FN(int (*)(void *, const void *, unsigned), "pthread_barrier_init");
    int (*bd)(void *) = FN(int (*)(void *), "pthread_barrier_destroy");
    assert(bi(storage, NULL, 4) == 0);
    for (int cycle = 0; cycle < 3; cycle++) {
        pthread_t t[4]; int serial = 0;
        for (int i = 0; i < 4; i++) pthread_create(&t[i], NULL, barrier_worker, storage);
        for (int i = 0; i < 4; i++) { void *r; pthread_join(t[i], &r); serial += (intptr_t)r == -1; }
        assert(serial == 1);
    }
    assert(bd(storage) == 0);

    // clock_nanosleep: relative and absolute (bionic MONOTONIC=1, TIMER_ABSTIME=1)
    int (*cn)(int, int, const struct timespec *, struct timespec *) = FN(int (*)(int, int, const struct timespec *, struct timespec *), "clock_nanosleep");
    struct timespec a, b, req = {0, 20 * 1000 * 1000};
    clock_gettime(CLOCK_MONOTONIC, &a);
    assert(cn(1, 0, &req, NULL) == 0);
    struct timespec abs_ = a; abs_.tv_nsec += 60 * 1000 * 1000;
    if (abs_.tv_nsec >= 1000000000L) { abs_.tv_nsec -= 1000000000L; abs_.tv_sec++; }
    assert(cn(1, 1, &abs_, NULL) == 0);
    clock_gettime(CLOCK_MONOTONIC, &b);
    double ms = (b.tv_sec - a.tv_sec) * 1e3 + (b.tv_nsec - a.tv_nsec) / 1e6;
    assert(ms >= 55 && ms < 500);

    // NativeActivity input queue is always empty
    int32_t (*ge)(void *, void **) = FN(int32_t (*)(void *, void **), "AInputQueue_getEvent");
    void *ev = (void *)1; assert(ge(NULL, &ev) == -1 && ev == NULL);

    // timezone is data
    assert(*(long *)mv_lookup("timezone") == 0);

    // libossdk stand-in: synthetic handle, harmless handler chain, everything else forwarded
    void *(*dlo)(const char *, int) = FN(void *(*)(const char *, int), "dlopen");
    void *(*dls)(void *, const char *) = FN(void *(*)(void *, const char *), "dlsym");
    void *h = dlo("libossdk.oculus.so", 0);
    int before = g_real_dlopen_calls;
    assert(h && g_real_dlopen_calls == before);       // the stand-in never reaches klb_dlopen
    void *(*create)(void) = (void *(*)(void))dls(h, "createTelemetryHandler");
    void **obj = create();                            // the handler
    void *(*m0)(void *, const char *) = (void *(*)(void *, const char *))((void **)obj[0])[0];
    void **again = m0(obj, "event");                  // a method on it: another dummy
    assert(again && ((void **)again[0])[5] != NULL);  // and its methods are callable too
    assert(dlo("/system/lib64/libfoo.so", 0) == (void *)0x1234 && g_real_dlopen_calls == before + 1);
    assert(dls((void *)0x1234, "x") == (void *)0x9abc);

    printf("mv_shims: %zu shims, all checks passed\n", mv_shim_count);
    return 0;
}
