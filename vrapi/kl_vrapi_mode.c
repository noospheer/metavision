/* Mode lifecycle.
 *
 * VrApi on Quest is lenient about ordering; CompositorServices is not. A title
 * that submits before entering, enters twice, or keeps using an ovrMobile after
 * leaving gets away with it on the original hardware and takes a null
 * dereference here — with one guest frame above it, naming nothing.
 *
 * So the ordering is enforced explicitly and the violation is named. Session
 * creation is injected, as texture allocation is: the rules are the part worth
 * testing and they need no CompositorServices to check. */
#include "kl_vrapi.h"

#include <stdlib.h>
#include <string.h>

struct ovrMobile {
    void *session;
    int   live;      /* cleared by LeaveVrMode; the handle may outlive it */
};

static struct {
    kl_vr_state     state;
    ovrMobile      *current;
    kl_session_open open;
    void          (*close)(void *session, void *context);
    void           *context;
} g;

void kl_vrapi_set_session_hooks(kl_session_open open,
                                void (*close)(void *session, void *context),
                                void *context)
{
    g.open = open;
    g.close = close;
    g.context = context;
}

kl_vr_state kl_vrapi_state(void) { return g.state; }

int kl_vrapi_mobile_is_live(const ovrMobile *ovr) { return ovr && ovr->live; }

void *kl_vrapi_session(const ovrMobile *ovr)
{
    if (!ovr) return NULL;
    /* A stale handle is the one that costs hours: it is a valid pointer to
     * freed-in-spirit state, so every read succeeds and returns nonsense. */
    if (!ovr->live)
        KL_VRAPI_FATAL("ovrMobile used after vrapi_LeaveVrMode — the handle is "
                       "not valid across a leave");
    return ovr->session;
}

ovrInitializeStatus vrapi_Initialize(const void *initParms)
{
    (void)initParms;
    kl_vrapi_abi_banner();

    if (g.state == KL_VR_INITIALIZED || g.state == KL_VR_ENTERED)
        return VRAPI_INITIALIZE_ALREADY_INITIALIZED;

    memset(&g.current, 0, sizeof g.current);
    g.state = KL_VR_INITIALIZED;
    return VRAPI_INITIALIZE_SUCCESS;
}

void vrapi_Shutdown(void)
{
    if (g.state == KL_VR_ENTERED)
        vrapi_LeaveVrMode(g.current);
    g.state = KL_VR_SHUTDOWN;
}

ovrMobile *vrapi_EnterVrMode(const ovrModeParms *parms)
{
    if (g.state != KL_VR_INITIALIZED) {
        if (g.state == KL_VR_ENTERED)
            KL_VRAPI_FATAL("already in VR mode — a second ovrMobile would own a "
                           "second session and neither would present");
        KL_VRAPI_FATAL("called before vrapi_Initialize (state %d)", (int)g.state);
    }

    if (parms) {
        /* The tag is the first word, so a mismatch localises a layout error
         * here rather than at the first frame that reads garbage flags. */
        KL_VRAPI_EXPECT_TYPE(parms->Type, VRAPI_STRUCTURE_TYPE_MODE_PARMS);
    }

    if (!g.open)
        KL_VRAPI_FATAL("no session hook installed — the Darwin runtime must "
                       "call kl_vrapi_set_session_hooks before the guest starts");

    void *session = g.open(g.context);
    if (!session) return NULL;   /* documented failure; titles handle NULL */

    ovrMobile *ovr = calloc(1, sizeof *ovr);
    if (!ovr) {
        if (g.close) g.close(session, g.context);
        return NULL;
    }
    ovr->session = session;
    ovr->live = 1;

    g.current = ovr;
    g.state = KL_VR_ENTERED;
    return ovr;
}

void vrapi_LeaveVrMode(ovrMobile *ovr)
{
    if (!ovr) return;
    if (!ovr->live) return;   /* idempotent: a double leave is not fatal */

    if (g.close) g.close(ovr->session, g.context);

    /* Marked dead rather than freed. Titles routinely null their pointer after
     * this and some do not; keeping the allocation means a late use is caught
     * by the live flag instead of landing in reused heap. */
    ovr->live = 0;
    ovr->session = NULL;

    if (g.current == ovr) g.current = NULL;
    if (g.state == KL_VR_ENTERED) g.state = KL_VR_INITIALIZED;
}

double vrapi_GetPredictedDisplayTime(ovrMobile *ovr, int64_t frameIndex)
{
    kl_vrapi_session(ovr);   /* validates liveness, and names it if not */

    static int64_t s_current_frame;
    if (frameIndex > s_current_frame) s_current_frame = frameIndex;

    float refresh = 90.0f;
    kl_vrapi_system_property_float(VRAPI_SYS_PROP_DISPLAY_REFRESH_RATE, &refresh);

    /* The Darwin build substitutes the CompositorServices frame clock; this
     * keeps the shape correct without one. */
    extern double kl_vrapi_now(void);
    return kl_vrapi_predicted_display_time(kl_vrapi_now(), frameIndex,
                                           s_current_frame, refresh);
}
