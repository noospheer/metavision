/* Convention and lifecycle. Both are pure, and both are the kind of bug that
 * does not fail — a transposed rotation turns the world the wrong way, and a
 * stale handle reads plausible nonsense. */
#define _POSIX_C_SOURCE 200809L
#include "../kl_vrapi.h"

#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static int failures = 0;
static void ok(const char *what, int cond)
{
    if (!cond) { printf("  FAIL  %-46s\n", what); failures++; }
    else       { printf("  ok    %-46s\n", what); }
}
static void expect(const char *what, long got, long want)
{
    if (got != want) { printf("  FAIL  %-46s got %ld, want %ld\n", what, got, want); failures++; }
    else             { printf("  ok    %-46s %ld\n", what, got); }
}
static int close_to(float a, float b) { return fabsf(a - b) < 1e-4f; }

static void *stub_open(void *ctx) { (void)ctx; return (void *)0xABCD; }
static int g_closed;
static void stub_close(void *s, void *ctx) { (void)s; (void)ctx; g_closed++; }

static int aborts_using(ovrMobile *ovr)
{
    fflush(NULL);
    pid_t pid = fork();
    if (pid == 0) {
        int n = open("/dev/null", O_WRONLY); if (n >= 0) dup2(n, 2);
        kl_vrapi_session(ovr);
        _exit(0);
    }
    int st = 0; waitpid(pid, &st, 0);
    return WIFSIGNALED(st) && WTERMSIG(st) == SIGABRT;
}

int main(void)
{
    puts("matrix convention");
    ovrMatrix4f m; memset(&m, 0, sizeof m);
    /* 90 degrees about Y, written row-major as VrApi spells it. */
    m.M[0][0] = 0; m.M[0][2] = 1;
    m.M[1][1] = 1;
    m.M[2][0] = -1; m.M[2][2] = 0;
    m.M[3][3] = 1;

    ovrVector4f q;
    kl_quat_from_matrix(&m, &q);
    ok("90deg about Y -> y = sin(45)", close_to(q.y, 0.70710678f));
    ok("                w = cos(45)", close_to(q.w, 0.70710678f));
    ok("                x is zero", close_to(q.x, 0.0f));
    ok("                z is zero", close_to(q.z, 0.0f));

    ovrMatrix4f back;
    kl_matrix_from_quat(&q, &back);
    int same = 1;
    for (int r = 0; r < 3; r++)
        for (int c = 0; c < 3; c++)
            if (!close_to(back.M[r][c], m.M[r][c])) same = 0;
    ok("matrix -> quat -> matrix round-trips", same);

    /* The bug this pins: a transposed matrix is a different rotation, so a
     * column-major buffer read as row-major inverts every turn. */
    ovrMatrix4f t; kl_matrix_transpose(&m, &t);
    ovrVector4f qt; kl_quat_from_matrix(&t, &qt);
    ok("transpose yields the inverse rotation", close_to(qt.y, -q.y));
    ok("transpose is not a no-op", !close_to(t.M[0][2], m.M[0][2]));

    ovrMatrix4f tt; kl_matrix_transpose(&t, &tt);
    int involutive = 1;
    for (int r = 0; r < 4; r++)
        for (int c = 0; c < 4; c++)
            if (!close_to(tt.M[r][c], m.M[r][c])) involutive = 0;
    ok("transposing twice is identity", involutive);

    puts("near-180 rotations stay stable");
    /* The trace-only form divides by nearly zero here, which is where a user
     * turning around actually lives. */
    ovrMatrix4f flip; memset(&flip, 0, sizeof flip);
    flip.M[0][0] = -1; flip.M[1][1] = 1; flip.M[2][2] = -1; flip.M[3][3] = 1;
    ovrVector4f qf; kl_quat_from_matrix(&flip, &qf);
    float norm = sqrtf(qf.x*qf.x + qf.y*qf.y + qf.z*qf.z + qf.w*qf.w);
    ok("180deg about Y is unit-norm", close_to(norm, 1.0f));
    ok("  and is not NaN", qf.y == qf.y);

    puts("predicted display time");
    double t0 = kl_vrapi_predicted_display_time(100.0, 10, 10, 90.0f);
    double t1 = kl_vrapi_predicted_display_time(100.0, 11, 10, 90.0f);
    ok("one frame ahead of now", close_to((float)(t0 - 100.0), 1.0f/90.0f));
    /* Slope is what titles differentiate to pace animation; a wrong rate is
     * slow motion rather than an error. */
    ok("each frame advances by one refresh period",
       close_to((float)(t1 - t0), 1.0f/90.0f));
    ok("zero refresh falls back, not divides by zero",
       kl_vrapi_predicted_display_time(100.0, 1, 0, 0.0f) > 100.0);

    puts("mode lifecycle");
    kl_vrapi_set_session_hooks(stub_open, stub_close, NULL);
    expect("starts uninitialized", kl_vrapi_state(), KL_VR_UNINITIALIZED);
    expect("initialize succeeds", vrapi_Initialize(NULL), VRAPI_INITIALIZE_SUCCESS);
    expect("  state is INITIALIZED", kl_vrapi_state(), KL_VR_INITIALIZED);
    expect("double initialize reported",
           vrapi_Initialize(NULL), VRAPI_INITIALIZE_ALREADY_INITIALIZED);

    ovrModeParms parms = { VRAPI_STRUCTURE_TYPE_MODE_PARMS, 0 };
    ovrMobile *ovr = vrapi_EnterVrMode(&parms);
    ok("entered", ovr != NULL);
    expect("  state is ENTERED", kl_vrapi_state(), KL_VR_ENTERED);
    ok("  session resolves", kl_vrapi_session(ovr) == (void *)0xABCD);
    ok("  handle is live", kl_vrapi_mobile_is_live(ovr));

    g_closed = 0;
    vrapi_LeaveVrMode(ovr);
    expect("  close hook ran once", g_closed, 1);
    expect("  back to INITIALIZED", kl_vrapi_state(), KL_VR_INITIALIZED);
    ok("  handle is dead", !kl_vrapi_mobile_is_live(ovr));
    vrapi_LeaveVrMode(ovr);
    expect("double leave is idempotent", g_closed, 1);

    /* The expensive bug: a stale handle is a valid pointer whose every read
     * succeeds and returns nonsense. */
    ok("use after leave aborts", aborts_using(ovr));

    ovrMobile *again = vrapi_EnterVrMode(&parms);
    ok("can re-enter after leaving", again != NULL);
    vrapi_LeaveVrMode(again);
    vrapi_Shutdown();
    expect("shutdown", kl_vrapi_state(), KL_VR_SHUTDOWN);

    printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "PASSED",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
