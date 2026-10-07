/* Frame planning for vrapi_SubmitFrame2.
 *
 * Every Quest 1-era title calls SubmitFrame2 once a frame with a
 * heterogeneous layer array, and turning that into CompositorServices work is
 * the substance of this shim. The walk is separated from the execution because
 * the walk is where the decisions and the validation live, and it needs no
 * device to exercise.
 *
 * This is also where a struct-layout error shows up first. The layer Type is
 * the first word of every header, so if our layout is wrong we read garbage
 * there before we read anything else — which makes it the best available
 * canary. */
#include "kl_vrapi.h"

#include <stdio.h>
#include <string.h>

/* A type inside the enum's range but unknown to us is a VrApi version we do
 * not model: skip it and keep rendering. A type far outside the range is not a
 * new layer type, it is garbage, and garbage in the first word means our
 * declaration and the guest's disagree. Those two deserve opposite responses,
 * and conflating them either hides a fatal bug or kills a working title. */
#define KL_LAYER_TYPE_PLAUSIBLE_MAX 32

static int layer_type_is_plausible(int32_t type)
{
    return type > 0 && type <= KL_LAYER_TYPE_PLAUSIBLE_MAX;
}

ovrResult kl_vrapi_plan_frame(const ovrSubmitFrameDescription2 *desc,
                              kl_frame_plan *out)
{
    if (!desc || !out) return ovrError_InvalidParameter;

    memset(out, 0, sizeof *out);
    out->frame_index  = desc->FrameIndex;
    out->display_time = desc->DisplayTime;

    /* VrApi treats 0 as "same as 1"; passing it through would stall the
     * compositor waiting for a frame interval that never elapses. */
    out->swap_interval = desc->SwapInterval ? desc->SwapInterval : 1;

    if (desc->LayerCount == 0) return ovrSuccess;   /* legal: a blank frame */

    if (!desc->Layers)
        KL_VRAPI_FATAL("LayerCount %u with a null Layers array — "
                       "layout mismatch, not a guest bug", desc->LayerCount);

    if (desc->LayerCount > VRAPI_MAX_LAYERS)
        KL_VRAPI_FATAL("LayerCount %u exceeds the VrApi maximum of %d — "
                       "reading a count from the wrong offset looks exactly "
                       "like this", desc->LayerCount, VRAPI_MAX_LAYERS);

    for (uint32_t i = 0; i < desc->LayerCount; i++) {
        const ovrLayerHeader2 *header = desc->Layers[i];
        if (!header)
            KL_VRAPI_FATAL("layer %u of %u is null", i, desc->LayerCount);

        int32_t type = (int32_t)header->Type;
        if (!layer_type_is_plausible(type))
            KL_VRAPI_FATAL("layer %u has type %d, which is not a layer type at "
                           "all — ovrLayerHeader2.Type is the first word, so "
                           "this is the layout disagreeing", i, type);

        kl_layer_plan *plan = &out->layers[out->layer_count++];
        plan->index   = i;
        plan->type    = (ovrLayerType2)type;
        plan->support = kl_vrapi_layer_support(plan->type);

        switch (plan->support) {
        case KL_LAYER_NATIVE:   out->native_count++;   break;
        case KL_LAYER_EMULATED: out->emulated_count++; break;
        case KL_LAYER_IGNORED:  out->ignored_count++;  break;
        }

        /* Only the projection layer carries per-eye swapchains, and it is the
         * one every title submits. The rest are planned by type alone and
         * resolved when the emulated path draws them. */
        if (plan->type == VRAPI_LAYER_TYPE_PROJECTION2) {
            const ovrLayerProjection2 *projection = (const ovrLayerProjection2 *)header;
            for (uint32_t eye = 0; eye < VRAPI_FRAME_LAYER_EYE_MAX; eye++) {
                plan->color[eye] = projection->Textures[eye].ColorSwapChain;
                plan->swapchain_index[eye] = projection->Textures[eye].SwapChainIndex;
                if (plan->color[eye]) plan->eye_count++;
            }
            /* A monoscopic projection layer is legal — some titles submit one
             * swapchain for both eyes — but zero is not renderable. */
            if (plan->eye_count == 0)
                KL_VRAPI_FATAL("projection layer %u has no colour swapchain "
                               "for either eye", i);
        }
    }

    /* Nothing to present is a title bug, not ours, and it is worth naming
     * rather than showing a black frame and letting them hunt for it. */
    if (out->native_count == 0 && out->emulated_count == 0)
        fprintf(stderr, "[klepton/vrapi] frame %llu submitted %u layer(s), all "
                        "ignored — nothing will be presented\n",
                (unsigned long long)out->frame_index, out->layer_count);

    return ovrSuccess;
}
