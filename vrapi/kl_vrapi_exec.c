/* Turning a frame plan into ordered work.
 *
 * VrApi composites the layer array back to front, so array order is the
 * compositing order and getting it wrong puts a UI layer behind the world
 * instead of in front of it. That is a rendering bug that looks like a
 * z-fighting or transparency problem and sends you hunting in the wrong place,
 * so the ordering is decided here — in code that runs without a device — and
 * the Darwin executor consumes the result without reordering it. */
#include "kl_vrapi.h"

#include <stdio.h>
#include <string.h>

ovrResult kl_vrapi_build_commands(const kl_frame_plan *plan, kl_command_list *out)
{
    if (!plan || !out) return ovrError_InvalidParameter;

    memset(out, 0, sizeof *out);

    for (uint32_t i = 0; i < plan->layer_count; i++) {
        const kl_layer_plan *layer = &plan->layers[i];

        /* Ignored layers emit nothing, but the loop still walks them so that
         * the emitted order stays the submitted order. */
        if (layer->support == KL_LAYER_IGNORED) continue;

        if (layer->support == KL_LAYER_EMULATED) {
            if (out->count >= KL_MAX_COMMANDS) break;
            out->commands[out->count++] = (kl_command){
                .op          = KL_OP_DRAW_EMULATED,
                .layer_index = layer->index,
                .type        = layer->type,
            };
            continue;
        }

        /* Native: one present per eye that has a swapchain. A monoscopic
         * projection layer supplies eye 0 only, and both eyes must still be
         * presented from it or the guest renders to one eye. */
        for (uint32_t eye = 0; eye < VRAPI_FRAME_LAYER_EYE_MAX; eye++) {
            ovrTextureSwapChain *chain = layer->color[eye];
            int index = layer->swapchain_index[eye];

            if (!chain) {
                if (!layer->color[0]) continue;   /* nothing to fall back to */
                chain = layer->color[0];
                index = layer->swapchain_index[0];
            }

            if (out->count >= KL_MAX_COMMANDS) break;

            /* Resolving here rather than in the executor means an out-of-range
             * index aborts naming the swapchain, before any Metal call. */
            void *texture = vrapi_GetTextureSwapChainHandle(chain, index);

            out->commands[out->count++] = (kl_command){
                .op          = KL_OP_PRESENT_EYE,
                .layer_index = layer->index,
                .type        = layer->type,
                .eye         = eye,
                .chain       = chain,
                .chain_index = index,
                .texture     = texture,
            };
        }
    }

    if (out->count == 0 && plan->layer_count > 0)
        fprintf(stderr, "[klepton/vrapi] frame %llu produced no commands from "
                        "%u layer(s)\n",
                (unsigned long long)plan->frame_index, plan->layer_count);

    return ovrSuccess;
}
