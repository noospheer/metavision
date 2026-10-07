/* Default clock. The Darwin build overrides this with the CompositorServices
 * frame clock, which is phase-locked to the display; a monotonic clock is the
 * right shape but not the right phase. */
/* clock_gettime is POSIX, not C11. Without this the declaration is implicit
 * and the double return comes back as an int — every predicted time truncated. */
#define _POSIX_C_SOURCE 200809L

#include <time.h>

double kl_vrapi_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}
