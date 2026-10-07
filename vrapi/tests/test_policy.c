/* The policy layer encodes decisions, needs no CompositorServices, and is
 * therefore the part worth pinning down without a device. */
#include "../kl_vrapi.h"
#include <stdio.h>
#include <string.h>

static int failures = 0;
static void expect(const char *what, long got, long want)
{
    if (got != want) { printf("  FAIL  %-46s got %ld, want %ld\n", what, got, want); failures++; }
    else             { printf("  ok    %-46s %ld\n", what, got); }
}

int main(void)
{
    kl_vrapi_abi_banner();

    puts("layer policy");
    expect("PROJECTION2 is native",
           kl_vrapi_layer_support(VRAPI_LAYER_TYPE_PROJECTION2), KL_LAYER_NATIVE);
    expect("CYLINDER2 emulated",
           kl_vrapi_layer_support(VRAPI_LAYER_TYPE_CYLINDER2), KL_LAYER_EMULATED);
    expect("EQUIRECT2 emulated",
           kl_vrapi_layer_support(VRAPI_LAYER_TYPE_EQUIRECT2), KL_LAYER_EMULATED);
    /* Dropping it is deliberate: visionOS shows its own transition, and a
     * second one drawn over it reads as a fault. */
    expect("LOADING_ICON2 ignored",
           kl_vrapi_layer_support(VRAPI_LAYER_TYPE_LOADING_ICON2), KL_LAYER_IGNORED);
    expect("unknown type is ignored, not native",
           kl_vrapi_layer_support((ovrLayerType2)999), KL_LAYER_IGNORED);

    puts("layer names are usable in a fault line");
    expect("PROJECTION2 named",
           strcmp(kl_vrapi_layer_name(VRAPI_LAYER_TYPE_PROJECTION2), "PROJECTION2"), 0);
    expect("unknown named, not null",
           strcmp(kl_vrapi_layer_name((ovrLayerType2)999), "UNKNOWN"), 0);

    puts("tracking space");
    expect("LOCAL passes through",
           kl_vrapi_resolve_tracking_space(VRAPI_TRACKING_SPACE_LOCAL),
           VRAPI_TRACKING_SPACE_LOCAL);
    /* Claiming STAGE would promise play-area bounds ARKit cannot supply, and
     * titles that ask for them would place content outside the room. */
    expect("STAGE degrades to LOCAL_FLOOR",
           kl_vrapi_resolve_tracking_space(VRAPI_TRACKING_SPACE_STAGE),
           VRAPI_TRACKING_SPACE_LOCAL_FLOOR);
    expect("LOCAL_FLOOR passes through",
           kl_vrapi_resolve_tracking_space(VRAPI_TRACKING_SPACE_LOCAL_FLOOR),
           VRAPI_TRACKING_SPACE_LOCAL_FLOOR);

    puts("system properties");
    int i = 0; float f = 0;
    expect("eye width answered",
           kl_vrapi_system_property_int(VRAPI_SYS_PROP_SUGGESTED_EYE_TEXTURE_WIDTH, &i), 1);
    expect("eye width plausible", i > 512 && i < 8192, 1);
    expect("eye height answered",
           kl_vrapi_system_property_int(VRAPI_SYS_PROP_SUGGESTED_EYE_TEXTURE_HEIGHT, &i), 1);
    /* An unrecognised device sends some titles down a conservative path and
     * others straight to an abort. */
    expect("device type answered",
           kl_vrapi_system_property_int(VRAPI_SYS_PROP_DEVICE_TYPE, &i), 1);
    expect("reports a known device", i, VRAPI_DEVICE_TYPE_OCULUSQUEST2);
    expect("refresh rate answered",
           kl_vrapi_system_property_float(VRAPI_SYS_PROP_DISPLAY_REFRESH_RATE, &f), 1);
    expect("refresh rate is 90", (long)f, 90);

    /* Answering a property we do not know with a plausible-looking zero is
     * worse than refusing: the guest cannot tell it was guessed. */
    expect("unknown int property refused",
           kl_vrapi_system_property_int((ovrSystemProperty)9999, &i), 0);
    expect("unknown float property refused",
           kl_vrapi_system_property_float((ovrSystemProperty)9999, &f), 0);
    expect("null out refused", kl_vrapi_system_property_int(
           VRAPI_SYS_PROP_DEVICE_TYPE, NULL), 0);

    printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "PASSED",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
