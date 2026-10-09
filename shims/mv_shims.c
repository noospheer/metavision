// mv_shims.c — bionic/NDK names the archive imports and Klepton does not answer.
//
// The work list is tools/metavision-gaps: each entry here is a name that some
// archived title imports, that none of the title's own libraries export, and
// that no resolver tier in vendor/klepton/runtime answers. They are added
// through kl_shim_override, which kl_shim_lookup consults before every tier,
// so the submodule stays untouched and an upstream implementation can never
// be shadowed by accident: mv_lookup only answers names in its own table, and
// the table is checked against upstream by `make -C shims test` — apart from
// the declared wrappers (dlopen, dlsym), which handle one case and forward.
//
// Conventions, inherited from the runtime:
//   * errno: set Darwin's. bionic's __errno() is klb_errno, which translates
//     the host value on every read.
//   * Anything Klepton already translates (guest FILE*, sockaddr, dlopen
//     flags, asset handles) is FORWARDED to Klepton's guest-facing entry via
//     kl_shim_lookup, never re-implemented against the host.
//   * Variadic bionic entry points: on Linux AArch64 the first variadic
//     arguments arrive in x-registers exactly like named ones, so they are
//     declared here as plain uint64_t parameters. Never declare them `...` —
//     Darwin would read them from the stack.
#include <errno.h>
#include <fenv.h>
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <math.h>

#include "mv_shims.h"
#include "mv_hands.h"

// ---- Klepton runtime (vendor/klepton/runtime/klepton.h) ----
void *kl_shim_lookup(const char *name);
FILE *kl_host_file(void *guest);
extern void *(*kl_shim_override)(const char *name);

static void *guest_fn(const char *name) {
    // The guest-facing implementation, as the guest itself would get it. Our
    // override only answers names in g_mv, so this cannot recurse into us.
    return kl_shim_lookup(name);
}

#define MV_FATAL(...) do { fprintf(stderr, "[mv-shim] " __VA_ARGS__); fputc('\n', stderr); abort(); } while (0)

// ---------------------------------------------------------------- debugging
// Unity's crash handler and several native plugins probe for a debugger with
// ptrace(PTRACE_TRACEME). "Not permitted" is what a sandboxed Android process
// gets too, and every caller treats it as "no debugger attached".
static long mv_ptrace(int req, int pid, void *addr, void *data) {
    (void)req; (void)pid; (void)addr; (void)data;
    errno = EPERM;
    return -1;
}

// Crash reporters (Crashlytics, Sentry) read another thread's memory this way.
static long mv_process_vm_readv(int pid, const void *l, unsigned long ln,
                                const void *r, unsigned long rn, unsigned long fl) {
    (void)pid; (void)l; (void)ln; (void)r; (void)rn; (void)fl;
    errno = ENOSYS;
    return -1;
}

// tgkill: only the liveness probe (signal 0) is answered; delivering a real
// signal to a specific guest thread needs Klepton's signal translation.
static int mv_tgkill(int tgid, int tid, int sig) {
    (void)tgid; (void)tid;
    if (sig == 0) return 0;
    errno = ENOSYS;
    return -1;
}

// ---------------------------------------------------------------- dynamic linking
// android_dlopen_ext(path, flags, extinfo): the extinfo asks for namespaces or
// a reserved address range, neither of which the translated images can honour,
// so it is dropped and the call becomes a plain guest dlopen (bionic flags,
// which klb_dlopen expects).
static void *mv_android_dlopen_ext(const char *path, int flags, const void *extinfo) {
    (void)extinfo;
    void *(*dl)(const char *, int) = (void *(*)(const char *, int))guest_fn("dlopen");
    if (!dl) { errno = ENOSYS; return NULL; }
    return dl(path, flags);
}

// ---------------------------------------------------------------- _FORTIFY_SOURCE
// The *_chk family is the compiler's bounds-checked spelling of a plain call:
// check, then do exactly what the plain call does — through Klepton's version
// of it where Klepton translates the arguments.
static ssize_t mv___pread_chk(int fd, void *buf, size_t n, int64_t off, size_t buflen) {
    if (n > buflen) MV_FATAL("__pread_chk: %zu > buffer %zu", n, buflen);
    ssize_t (*f)(int, void *, size_t, int64_t) = (ssize_t (*)(int, void *, size_t, int64_t))guest_fn("pread");
    return f(fd, buf, n, off);
}

static ssize_t mv___pwrite_chk(int fd, const void *buf, size_t n, int64_t off, size_t buflen) {
    if (n > buflen) MV_FATAL("__pwrite_chk: %zu > buffer %zu", n, buflen);
    ssize_t (*f)(int, const void *, size_t, int64_t) = (ssize_t (*)(int, const void *, size_t, int64_t))guest_fn("pwrite");
    return f(fd, buf, n, off);
}

static void *mv___memchr_chk(const void *s, int c, size_t n, size_t buflen) {
    if (n > buflen) MV_FATAL("__memchr_chk: %zu > buffer %zu", n, buflen);
    return memchr(s, c, n);
}

static size_t mv___fread_chk(void *ptr, size_t buflen, size_t size, size_t n, void *fp) {
    if (size && n > buflen / size) MV_FATAL("__fread_chk: %zu*%zu > buffer %zu", size, n, buflen);
    size_t (*f)(void *, size_t, size_t, void *) = (size_t (*)(void *, size_t, size_t, void *))guest_fn("fread");
    return f(ptr, size, n, fp);
}

static size_t mv___strlcpy_chk(char *dst, const char *src, size_t size, size_t dstlen) {
    if (size > dstlen) MV_FATAL("__strlcpy_chk: %zu > buffer %zu", size, dstlen);
    size_t len = strlen(src);
    if (size) {
        size_t k = len < size - 1 ? len : size - 1;
        memcpy(dst, src, k);
        dst[k] = 0;
    }
    return len;
}

static ssize_t mv___sendto_chk(int fd, const void *buf, size_t n, size_t buflen, int flags,
                               const void *addr, uint32_t alen) {
    if (n > buflen) MV_FATAL("__sendto_chk: %zu > buffer %zu", n, buflen);
    ssize_t (*f)(int, const void *, size_t, int, const void *, uint32_t) =
        (ssize_t (*)(int, const void *, size_t, int, const void *, uint32_t))guest_fn("sendto");
    return f(fd, buf, n, flags, addr, alen);
}

// ---------------------------------------------------------------- logging
// Variadic in bionic; the format arguments are deliberately not formatted
// (they sit in registers we would have to guess the types of). These are the
// assert path, so the message and the call site's text is what matters.
static void mv___android_log_assert(const char *cond, const char *tag, const char *fmt,
                                    uint64_t a3, uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7) {
    (void)a3; (void)a4; (void)a5; (void)a6; (void)a7;
    MV_FATAL("assert %s: %s (%s)", tag ? tag : "?", fmt ? fmt : "", cond ? cond : "");
}

static int mv___android_log_buf_print(int buf, int prio, const char *tag, const char *fmt,
                                      uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7) {
    (void)buf; (void)a4; (void)a5; (void)a6; (void)a7;
    return fprintf(stderr, "[%d/%s] %s (unformatted)\n", prio, tag ? tag : "?", fmt ? fmt : "");
}

// ---------------------------------------------------------------- scheduling and time
static int mv_sched_getcpu(void) { return 0; }
static int mv_sched_getscheduler(int pid) { (void)pid; return 0; }       // SCHED_OTHER

static int mv_pthread_attr_getschedpolicy(const void *attr, int *policy) {
    (void)attr; if (policy) *policy = 0; return 0;
}
static int mv_pthread_attr_setschedparam(void *attr, const void *param) {
    (void)attr; (void)param; return 0;   // priorities are the host scheduler's to decide
}
static int mv_pthread_getcpuclockid(pthread_t t, void *clock) {
    (void)t; (void)clock; return ENOENT;
}

// clock_nanosleep(clockid, flags, req, rem) returns an error NUMBER, not -1.
// bionic clock ids: 0 REALTIME, 1 MONOTONIC (others behave as MONOTONIC here);
// flag 1 is TIMER_ABSTIME. timespec is two 64-bit fields on both sides.
static int mv_clock_nanosleep(int clk, int flags, const struct timespec *req, struct timespec *rem) {
    if (!req) return EFAULT;
    struct timespec d = *req;
    if (flags & 1) {
        struct timespec now;
        clock_gettime(clk == 0 ? CLOCK_REALTIME : CLOCK_MONOTONIC, &now);
        d.tv_sec -= now.tv_sec;
        d.tv_nsec -= now.tv_nsec;
        if (d.tv_nsec < 0) { d.tv_nsec += 1000000000L; d.tv_sec--; }
        if (d.tv_sec < 0) return 0;
        rem = NULL;
    }
    return nanosleep(&d, rem) ? errno : 0;
}

long mv_timezone_data;                 // `extern long timezone` — a DATA import

// ---------------------------------------------------------------- pthread barriers
// Darwin has none. bionic's pthread_barrier_t is 32 opaque bytes; the guest's
// storage holds a pointer to a host-side barrier built from a mutex and a cond.
typedef struct { pthread_mutex_t m; pthread_cond_t c; unsigned count, waiting, cycle; } mv_barrier;

static int mv_pthread_barrier_init(void *b, const void *attr, unsigned count) {
    (void)attr;
    if (!count) return EINVAL;
    mv_barrier *x = calloc(1, sizeof *x);
    if (!x) return ENOMEM;
    pthread_mutex_init(&x->m, NULL);
    pthread_cond_init(&x->c, NULL);
    x->count = count;
    *(mv_barrier **)b = x;
    return 0;
}

static int mv_pthread_barrier_wait(void *b) {
    mv_barrier *x = *(mv_barrier **)b;
    pthread_mutex_lock(&x->m);
    unsigned cycle = x->cycle;
    if (++x->waiting == x->count) {
        x->waiting = 0;
        x->cycle++;
        pthread_cond_broadcast(&x->c);
        pthread_mutex_unlock(&x->m);
        return -1;                     // PTHREAD_BARRIER_SERIAL_THREAD
    }
    while (cycle == x->cycle) pthread_cond_wait(&x->c, &x->m);
    pthread_mutex_unlock(&x->m);
    return 0;
}

static int mv_pthread_barrier_destroy(void *b) {
    mv_barrier *x = *(mv_barrier **)b;
    if (!x) return EINVAL;
    pthread_mutex_destroy(&x->m);
    pthread_cond_destroy(&x->c);
    free(x);
    *(mv_barrier **)b = NULL;
    return 0;
}

// ---------------------------------------------------------------- libc odds and ends
static char *mv_strndup(const char *s, size_t n) { return strndup(s, n); }
static int mv_putenv(char *s) { return putenv(s); }
static int mv_isnanf(float f) { return isnan(f); }
// FE_* rounding values are the FPCR RMode bits on AArch64 — identical on both.
static int mv_fesetround(int r) { return fesetround(r); }

static ssize_t mv_getline(char **line, size_t *cap, void *guest_fp) {
    FILE *fp = kl_host_file(guest_fp);
    if (!fp) { errno = EBADF; return -1; }
    return getline(line, cap, fp);
}

static const char *mv_getprogname(void) { return "metavision"; }

// recvmmsg/sendmmsg: struct msghdr differs between bionic and Darwin and
// Klepton translates neither batch call. Callers (QUIC/WebRTC stacks) fall back
// to the single-message calls on ENOSYS.
static int mv_recvmmsg(int fd, void *v, unsigned n, int fl, void *t) {
    (void)fd; (void)v; (void)n; (void)fl; (void)t; errno = ENOSYS; return -1;
}
static int mv_sendmmsg(int fd, void *v, unsigned n, int fl) {
    (void)fd; (void)v; (void)n; (void)fl; errno = ENOSYS; return -1;
}

// ---------------------------------------------------------------- NDK
// Build.VERSION.SDK_INT through the NDK; kl_jni answers the same question as 29.
static int32_t mv_AConfiguration_getSdkVersion(const void *cfg) { (void)cfg; return 29; }

static int32_t mv_AAsset_seek(void *asset, int32_t off, int whence) {
    int64_t (*f)(void *, int64_t, int) = (int64_t (*)(void *, int64_t, int))guest_fn("AAsset_seek64");
    if (!f) return -1;
    int64_t r = f(asset, off, whence);
    return r > INT32_MAX ? -1 : (int32_t)r;
}

// The NativeActivity input queue. Klepton never hands a guest an AInputQueue:
// controller and hand input reach titles through OVRPlugin/OpenXR/VrApi, which
// is how they read it on a Quest too. UE4 still links the whole API, so it
// resolves to a queue that is always empty.
static void    mv_AInputQueue_attachLooper(void *q, void *l, int id, void *cb, void *d) { (void)q; (void)l; (void)id; (void)cb; (void)d; }
static void    mv_AInputQueue_detachLooper(void *q) { (void)q; }
static int32_t mv_AInputQueue_getEvent(void *q, void **ev) { (void)q; if (ev) *ev = NULL; return -1; }
static int32_t mv_AInputQueue_preDispatchEvent(void *q, void *ev) { (void)q; (void)ev; return 0; }
static void    mv_AInputQueue_finishEvent(void *q, void *ev, int handled) { (void)q; (void)ev; (void)handled; }
static int32_t mv_AInputEvent_zero(const void *ev) { (void)ev; return 0; }
static int32_t mv_AMotionEvent_zero_i(const void *ev, size_t i) { (void)ev; (void)i; return 0; }
static float   mv_AMotionEvent_zero_f(const void *ev, size_t i) { (void)ev; (void)i; return 0.0f; }
static size_t  mv_AMotionEvent_getPointerCount(const void *ev) { (void)ev; return 0; }

// AMidi: no MIDI devices exist, so opening one is unsupported.
#define AMEDIA_ERROR_UNSUPPORTED (-10000)
static int32_t mv_amidi_unsupported(void) { return AMEDIA_ERROR_UNSUPPORTED; }
static void    mv_AMidiDevice_release(void *d) { (void)d; }

static const char *mv_AMediaFormat_toString(void *f) { (void)f; return "{}"; }
static void        mv_AMediaFormat_setBuffer(void *f, const char *k, const void *d, size_t n) { (void)f; (void)k; (void)d; (void)n; }
static void       *mv_AMediaCodec_createEncoderByType(const char *mime) { (void)mime; return NULL; }

// VrApi: a clock-level request is advice to the Quest's governor. Success.
static int32_t mv_vrapi_SetClockLevels(void *ovr, int32_t cpu, int32_t gpu) { (void)ovr; (void)cpu; (void)gpu; return 0; }

// ---------------------------------------------------------------- Quest system libraries
// Some titles dlopen libraries that ship with the Quest's OS, not the APK. The
// one that matters: Meta's Interaction SDK (in most Unity titles since 2023)
// loads libossdk.oculus.so for telemetry, gets nothing here, and then calls a
// method on the handler it never received (TelemetrySender's constructor,
// SIGSEGV at 0x0) — on a Quest the library always exists, so nothing checks.
//
// The stand-in: dlopen("libossdk.oculus.so") answers a synthetic handle, and
// every symbol looked up through it is a function returning a dummy object
// whose methods all return that same dummy object — so a chain of calls off
// the "handler" stays harmless, and nothing is ever sent anywhere.
//
// These two are WRAPPERS of Klepton's own dlopen/dlsym, not replacements:
// every other name goes straight to klb_dlopen/klb_dlsym.
void *klb_dlopen(const char *path, int flags);
void *klb_dlsym(void *handle, const char *name);

static void *g_dummy_vtbl[64];
static struct { void **vtbl; uint64_t fields[31]; } g_dummy_obj;
static char g_ossdk_handle;          // its address is the synthetic handle

static void *mv_dummy_method(void) { return &g_dummy_obj; }

static void mv_dummy_init(void) {
    for (size_t i = 0; i < sizeof g_dummy_vtbl / sizeof g_dummy_vtbl[0]; i++)
        g_dummy_vtbl[i] = (void *)mv_dummy_method;
    g_dummy_obj.vtbl = g_dummy_vtbl;
}

static const char *base_name(const char *p) {
    const char *b = strrchr(p, '/');
    return b ? b + 1 : p;
}

// Android's own NDK libraries, opened by name rather than linked (Unreal and
// Unity probe libandroid.so for ANativeWindow_* and friends). Klepton serves
// those functions to every image already; the handle just makes dlsym find
// them, where a plain dlopen looks for the file among the title's libraries.
static char g_ndk_handle;

// Meta XR Audio's native plugin: Klepton refuses it by name (it patches its own
// code pages, which visionOS kills a process for), so every P/Invoke into it
// threw DllNotFoundException each frame. A stand-in whose every entry point
// answers 0 — ovrAudio's success, no effect definitions, NULL handles — leaves
// audio unspatialised instead of throwing.
static char g_zero_handle;
static const char *const k_zero_libs[] = { "MetaXRAudioUnity", "libMetaXRAudioUnity.so" };
static long mv_zero(void) { return 0; }
static const char *const k_ndk_libs[] = { "libandroid.so", "libnativewindow.so" };

static void *mv_dlopen(const char *path, int flags) {
    for (size_t i = 0; path && i < sizeof k_zero_libs / sizeof k_zero_libs[0]; i++)
        if (strcmp(base_name(path), k_zero_libs[i]) == 0) return &g_zero_handle;
    for (size_t i = 0; path && i < sizeof k_ndk_libs / sizeof k_ndk_libs[0]; i++)
        if (strcmp(base_name(path), k_ndk_libs[i]) == 0) return &g_ndk_handle;
    if (path && strcmp(base_name(path), "libossdk.oculus.so") == 0) {
        static int said;
        if (!said++) fprintf(stderr, "  [mv-shim] %s -> stand-in (Quest OS telemetry; nothing is sent)\n", path);
        return &g_ossdk_handle;
    }
    return klb_dlopen(path, flags);
}

// ---- OVRPlugin capability questions Klepton does not answer
// Klepton stops a title, by name, at any OVRPlugin entry point it lacks — the
// right default, since a guessed answer can be worse than a clear stop. These
// are the exception: "is <feature> enabled / supported?" with the plugin's
// usual shape, ovrpResult f(ovrpBool *out). "No" is true on this device
// (no body/face tracking through OVRPlugin, no Quest-only display features),
// and it is what sends a title down its controller path. The list is the
// archive's referenced names minus Klepton's own (tools/metavision-gaps --ovrp).
int kl_ovrp_is_handle(const void *h);
static const char *const k_ovrp_no[] = {
    "ovrp_GetBodyTrackingEnabled",
    "ovrp_GetBodyTrackingSupported",
    "ovrp_GetDynamicObjectKeyboardSupported",
    "ovrp_GetDynamicObjectTrackerSupported",
    "ovrp_GetEnvironmentDepthHandRemovalSupported",
    "ovrp_GetEnvironmentDepthSupported",
    "ovrp_GetEnvironmentRaycastSupported",
    "ovrp_GetEyeOcclusionMeshEnabled",
    "ovrp_GetEyeTextureArrayEnabled",
    "ovrp_GetFaceTracking2Enabled",
    "ovrp_GetFaceTracking2Supported",
    "ovrp_GetFaceTrackingEnabled",
    "ovrp_GetFaceTrackingSupported",
    "ovrp_GetFaceTrackingVisemesSupported",
    "ovrp_GetGPUUtilSupported",
    "ovrp_GetLocalDimmingSupported",
    "ovrp_GetMarkerTrackingSupported",
    "ovrp_GetSystemHmd3DofModeEnabled",
};
#define OVRP_SUCCESS 0
static int32_t mv_ovrp_answer_no(char *out) {
    if (out) *out = 0;
    return OVRP_SUCCESS;
}

// Value questions with one honest answer on this device.
// ovrpHandedness: 0 Unsupported, 1 LeftHanded, 2 RightHanded. Right, which is
// also the controller the hands-free pointer supplies.
static int32_t mv_ovrp_dominant_hand(int32_t *out) {
    if (out) *out = 2;
    return OVRP_SUCCESS;
}

// OpenXR actions an SDK helper defines on its own (a stylus profile, …): with
// no such device bound, OVRPlugin answers success and an inactive value — a
// false button, a zero axis, an identity pose — and that is what is true here.
// Signatures per OVRPlugin's C#: (string actionName, ref/out value), and
// GetActionStatePose2 adds a Hand before the out-param. Posef is {qx,qy,qz,qw,px,py,pz}.
static void mv_action_said(const char *fn, const char *n) {
    static int said;
    if (said++ < 3) fprintf(stderr, "  [mv-shim] %s(\"%s\") -> inactive\n", fn, n ? n : "");
}
static int32_t mv_ovrp_action_bool(const char *n, int32_t *out) { mv_action_said("ovrp_GetActionStateBoolean", n); if (out) *out = 0; return 0; }
static int32_t mv_ovrp_action_float(const char *n, float *out) { mv_action_said("ovrp_GetActionStateFloat", n); if (out) *out = 0; return 0; }
static int32_t mv_ovrp_action_vec2(const char *n, float *out) { (void)n; if (out) out[0] = out[1] = 0; return 0; }
static int32_t mv_ovrp_action_pose(const char *n, float *pose) {
    mv_action_said("ovrp_GetActionStatePose", n);
    if (pose) { memset(pose, 0, 7 * sizeof *pose); pose[3] = 1; }
    return 0;
}
static int32_t mv_ovrp_action_pose2(const char *n, int32_t hand, float *pose) {
    (void)hand;
    return mv_ovrp_action_pose(n, pose);
}

static const struct { const char *name; void *fn; } k_ovrp_answers[] = {
    { "ovrp_GetDominantHand",       (void *)mv_ovrp_dominant_hand },
    { "ovrp_GetActionStateBoolean", (void *)mv_ovrp_action_bool },
    { "ovrp_GetActionStateFloat",   (void *)mv_ovrp_action_float },
    { "ovrp_GetActionStateVector2", (void *)mv_ovrp_action_vec2 },
    { "ovrp_GetActionStatePose",    (void *)mv_ovrp_action_pose },
    { "ovrp_GetActionStatePose2",   (void *)mv_ovrp_action_pose2 },
};

static void *mv_dlsym(void *handle, const char *name) {
    if (handle == &g_ossdk_handle)
        return (void *)mv_dummy_method;   // createTelemetryHandler, destroy*, anything
    if (handle == &g_zero_handle)
        return (void *)mv_zero;                      // Meta XR Audio stand-in: 0 everywhere
    if (handle == &g_ndk_handle)
        return name ? kl_shim_lookup(name) : NULL;   // Klepton's NDK functions, or NULL
    if (name && kl_ovrp_is_handle(handle)) {
        void *h = mv_hands_ovrp(name);   // hand tracking: mv_hands.c
        if (h) return h;
        for (size_t i = 0; i < sizeof k_ovrp_no / sizeof k_ovrp_no[0]; i++)
            if (strcmp(name, k_ovrp_no[i]) == 0) return (void *)mv_ovrp_answer_no;
        for (size_t i = 0; i < sizeof k_ovrp_answers / sizeof k_ovrp_answers[0]; i++)
            if (strcmp(name, k_ovrp_answers[i].name) == 0) return k_ovrp_answers[i].fn;
    }
    return klb_dlsym(handle, name);
}

// ---------------------------------------------------------------- table
#define MV(name, fn) { name, (void *)(fn) }
const mv_entry mv_shim_table[] = {
    MV("ptrace", mv_ptrace),
    MV("process_vm_readv", mv_process_vm_readv),
    MV("tgkill", mv_tgkill),
    MV("android_dlopen_ext", mv_android_dlopen_ext),
    MV("__pread_chk", mv___pread_chk),
    MV("__pwrite_chk", mv___pwrite_chk),
    MV("__memchr_chk", mv___memchr_chk),
    MV("__fread_chk", mv___fread_chk),
    MV("__strlcpy_chk", mv___strlcpy_chk),
    MV("__sendto_chk", mv___sendto_chk),
    MV("__android_log_assert", mv___android_log_assert),
    MV("__android_log_buf_print", mv___android_log_buf_print),
    MV("sched_getcpu", mv_sched_getcpu),
    MV("sched_getscheduler", mv_sched_getscheduler),
    MV("pthread_attr_getschedpolicy", mv_pthread_attr_getschedpolicy),
    MV("pthread_attr_setschedparam", mv_pthread_attr_setschedparam),
    MV("pthread_getcpuclockid", mv_pthread_getcpuclockid),
    MV("clock_nanosleep", mv_clock_nanosleep),
    MV("timezone", &mv_timezone_data),
    MV("pthread_barrier_init", mv_pthread_barrier_init),
    MV("pthread_barrier_wait", mv_pthread_barrier_wait),
    MV("pthread_barrier_destroy", mv_pthread_barrier_destroy),
    MV("strndup", mv_strndup),
    MV("putenv", mv_putenv),
    MV("isnanf", mv_isnanf),
    MV("fesetround", mv_fesetround),
    MV("getline", mv_getline),
    MV("getprogname", mv_getprogname),
    MV("recvmmsg", mv_recvmmsg),
    MV("sendmmsg", mv_sendmmsg),
    MV("AConfiguration_getSdkVersion", mv_AConfiguration_getSdkVersion),
    MV("AAsset_seek", mv_AAsset_seek),
    MV("AInputQueue_attachLooper", mv_AInputQueue_attachLooper),
    MV("AInputQueue_detachLooper", mv_AInputQueue_detachLooper),
    MV("AInputQueue_getEvent", mv_AInputQueue_getEvent),
    MV("AInputQueue_preDispatchEvent", mv_AInputQueue_preDispatchEvent),
    MV("AInputQueue_finishEvent", mv_AInputQueue_finishEvent),
    MV("AInputEvent_getType", mv_AInputEvent_zero),
    MV("AInputEvent_getSource", mv_AInputEvent_zero),
    MV("AInputEvent_getDeviceId", mv_AInputEvent_zero),
    MV("AKeyEvent_getAction", mv_AInputEvent_zero),
    MV("AKeyEvent_getKeyCode", mv_AInputEvent_zero),
    MV("AKeyEvent_getMetaState", mv_AInputEvent_zero),
    MV("AKeyEvent_getFlags", mv_AInputEvent_zero),
    MV("AMotionEvent_getAction", mv_AInputEvent_zero),
    MV("AMotionEvent_getButtonState", mv_AInputEvent_zero),
    MV("AMotionEvent_getPointerCount", mv_AMotionEvent_getPointerCount),
    MV("AMotionEvent_getPointerId", mv_AMotionEvent_zero_i),
    MV("AMotionEvent_getX", mv_AMotionEvent_zero_f),
    MV("AMotionEvent_getY", mv_AMotionEvent_zero_f),
    MV("AMidiDevice_fromJava", mv_amidi_unsupported),
    MV("AMidiInputPort_open", mv_amidi_unsupported),
    MV("AMidiOutputPort_open", mv_amidi_unsupported),
    MV("AMidiInputPort_send", mv_amidi_unsupported),
    MV("AMidiOutputPort_receive", mv_amidi_unsupported),
    MV("AMidiDevice_release", mv_AMidiDevice_release),
    MV("AMediaFormat_toString", mv_AMediaFormat_toString),
    MV("AMediaFormat_setBuffer", mv_AMediaFormat_setBuffer),
    MV("AMediaCodec_createEncoderByType", mv_AMediaCodec_createEncoderByType),
    MV("vrapi_SetClockLevels", mv_vrapi_SetClockLevels),
    MV("dlopen", mv_dlopen),          // wrapper: one Quest OS library, then klb_dlopen
    MV("dlsym", mv_dlsym),            // wrapper: the stand-in's symbols, then klb_dlsym
};
const size_t mv_shim_count = sizeof mv_shim_table / sizeof mv_shim_table[0];

void *mv_lookup(const char *name) {
    for (size_t i = 0; i < mv_shim_count; i++)
        if (strcmp(mv_shim_table[i].name, name) == 0) return mv_shim_table[i].fn;
    return NULL;
}

// ---------------------------------------------------------------- install
// Chain rather than replace: kl_dl and kl_metadump install diagnostic
// overrides of their own, and whichever runs first must keep working.
static void *(*g_prev_override)(const char *);

static void *mv_override(const char *name) {
    if (g_prev_override) { void *p = g_prev_override(name); if (p) return p; }
    return mv_lookup(name);
}

void mv_shims_install(void) {
    mv_dummy_init();
    if (kl_shim_override == mv_override) return;
    g_prev_override = kl_shim_override;
    kl_shim_override = mv_override;
}

__attribute__((constructor)) static void mv_shims_ctor(void) { mv_shims_install(); }
