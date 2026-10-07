/* Layer, tracking-space and system-property policy.
 *
 * Split out from the entry points deliberately: this is the part that encodes
 * decisions rather than plumbing, it needs no CompositorServices, and so it is
 * the part that can be tested on the authoring host. */
#include "kl_vrapi.h"

kl_layer_support kl_vrapi_layer_support(ovrLayerType2 type)
{
    switch (type) {
    /* The one that matters. Every title submits it every frame. */
    case VRAPI_LAYER_TYPE_PROJECTION2:
        return KL_LAYER_NATIVE;

    /* CompositorServices has no cylinder or equirect layer. Both are a textured
     * surface at a known pose, so we can draw them into the projection layer
     * ourselves — worse latency than a native layer, correct output. */
    case VRAPI_LAYER_TYPE_CYLINDER2:
    case VRAPI_LAYER_TYPE_EQUIRECT2:
    case VRAPI_LAYER_TYPE_CUBE2:
    case VRAPI_LAYER_TYPE_FISHEYE2:
        return KL_LAYER_EMULATED;

    /* Shown while the guest blocks. visionOS is already showing its own
     * transition, and drawing a second one over it looks like a fault. */
    case VRAPI_LAYER_TYPE_LOADING_ICON2:
        return KL_LAYER_IGNORED;
    }
    return KL_LAYER_IGNORED;
}

const char *kl_vrapi_layer_name(ovrLayerType2 type)
{
    switch (type) {
    case VRAPI_LAYER_TYPE_PROJECTION2:   return "PROJECTION2";
    case VRAPI_LAYER_TYPE_CYLINDER2:     return "CYLINDER2";
    case VRAPI_LAYER_TYPE_CUBE2:         return "CUBE2";
    case VRAPI_LAYER_TYPE_EQUIRECT2:     return "EQUIRECT2";
    case VRAPI_LAYER_TYPE_LOADING_ICON2: return "LOADING_ICON2";
    case VRAPI_LAYER_TYPE_FISHEYE2:      return "FISHEYE2";
    }
    return "UNKNOWN";
}

ovrTrackingSpace kl_vrapi_resolve_tracking_space(ovrTrackingSpace requested)
{
    switch (requested) {
    case VRAPI_TRACKING_SPACE_LOCAL:
        return VRAPI_TRACKING_SPACE_LOCAL;

    /* ARKit has no Guardian-derived stage. Floor-relative is the closest true
     * answer; claiming STAGE would promise play-area bounds we cannot supply,
     * and titles that ask for them would place content outside the room. */
    case VRAPI_TRACKING_SPACE_STAGE:
    case VRAPI_TRACKING_SPACE_LOCAL_FLOOR:
        return VRAPI_TRACKING_SPACE_LOCAL_FLOOR;
    }
    return VRAPI_TRACKING_SPACE_LOCAL;
}

int kl_vrapi_system_property_int(ovrSystemProperty prop, int *out)
{
    if (!out) return 0;
    switch (prop) {
    /* Per-eye, matching what CompositorServices hands us. Quest 2 reported
     * 1832x1920; a title sizing its targets from these must get real numbers
     * or it renders at the wrong scale all session. */
    case VRAPI_SYS_PROP_SUGGESTED_EYE_TEXTURE_WIDTH:  *out = 1832; return 1;
    case VRAPI_SYS_PROP_SUGGESTED_EYE_TEXTURE_HEIGHT: *out = 1920; return 1;
    case VRAPI_SYS_PROP_DISPLAY_PIXELS_WIDE:          *out = 3664; return 1;
    case VRAPI_SYS_PROP_DISPLAY_PIXELS_HIGH:          *out = 1920; return 1;

    /* Titles gate features and render scale on device type. Reporting an
     * unknown device sends some down a conservative path and others to an
     * abort, so claim the most capable device VrApi ever shipped for. */
    case VRAPI_SYS_PROP_DEVICE_TYPE: *out = VRAPI_DEVICE_TYPE_OCULUSQUEST2; return 1;

    case VRAPI_SYS_PROP_MAX_FULLSPEED_FRAMEBUFFER_SAMPLES: *out = 4; return 1;
    case VRAPI_SYS_PROP_NUM_SUPPORTED_DISPLAY_REFRESH_RATES: *out = 1; return 1;
    default: return 0;
    }
}

int kl_vrapi_system_property_float(ovrSystemProperty prop, float *out)
{
    if (!out) return 0;
    switch (prop) {
    /* 90 Hz. Titles use this to compute their frame budget and, in a few cases,
     * to pace animation directly — a wrong value shows up as slow motion. */
    case VRAPI_SYS_PROP_DISPLAY_REFRESH_RATE: *out = 90.0f; return 1;
    default: return 0;
    }
}
