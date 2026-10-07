/* Swapchains and command ordering, with a stub allocator standing in for Metal.
 * The injection point exists precisely so this runs here. */
#define _POSIX_C_SOURCE 200809L
#include "../kl_vrapi.h"

#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

static int failures = 0;
static void expect(const char *what, long got, long want)
{
    if (got != want) { printf("  FAIL  %-46s got %ld, want %ld\n", what, got, want); failures++; }
    else             { printf("  ok    %-46s %ld\n", what, got); }
}

static int  g_allocated, g_released, g_fail_after = -1;
static void *stub_alloc(kl_pixel_format f, int w, int h, int levels, void *ctx)
{
    (void)f; (void)w; (void)h; (void)levels; (void)ctx;
    if (g_fail_after >= 0 && g_allocated >= g_fail_after) return NULL;
    g_allocated++;
    return malloc(16);
}
static void stub_release(void *tex, void *ctx) { (void)ctx; g_released++; free(tex); }

#define GL_RGBA8 0x8058

static int aborts_on_handle(ovrTextureSwapChain *chain, int index)
{
    fflush(NULL);
    pid_t pid = fork();
    if (pid == 0) {
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) dup2(devnull, 2);
        vrapi_GetTextureSwapChainHandle(chain, index);
        _exit(0);
    }
    int status = 0; waitpid(pid, &status, 0);
    return WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT;
}

int main(void)
{
    kl_vrapi_set_texture_allocator(stub_alloc, stub_release, NULL);

    puts("format mapping");
    expect("GL_RGBA8", kl_vrapi_format_from_gl(GL_RGBA8), KL_PIXFMT_RGBA8);
    expect("GL_SRGB8_ALPHA8", kl_vrapi_format_from_gl(0x8C43), KL_PIXFMT_RGBA8_SRGB);
    expect("GL_DEPTH24_STENCIL8", kl_vrapi_format_from_gl(0x88F0), KL_PIXFMT_DEPTH24_STENCIL8);
    expect("unknown format refused", kl_vrapi_format_from_gl(0xDEAD), KL_PIXFMT_UNSUPPORTED);
    expect("depth classified", kl_pixel_format_is_depth(KL_PIXFMT_DEPTH24), 1);
    expect("colour not depth", kl_pixel_format_is_depth(KL_PIXFMT_RGBA8), 0);

    puts("creation");
    g_allocated = g_released = 0;
    ovrTextureSwapChain *chain = vrapi_CreateTextureSwapChain3(0, GL_RGBA8, 1832, 1920, 1, 3);
    expect("created", chain != NULL, 1);
    expect("length honoured", vrapi_GetTextureSwapChainLength(chain), 3);
    expect("allocated one texture per slot", g_allocated, 3);

    int w = 0, h = 0; kl_pixel_format fmt = KL_PIXFMT_UNSUPPORTED;
    expect("geometry readable", kl_vrapi_swapchain_geometry(chain, &w, &h, &fmt), 1);
    expect("width", w, 1832);
    expect("format", fmt, KL_PIXFMT_RGBA8);

    puts("indexing");
    expect("index 0 resolves", vrapi_GetTextureSwapChainHandle(chain, 0) != NULL, 1);
    expect("index 2 resolves", vrapi_GetTextureSwapChainHandle(chain, 2) != NULL, 1);
    expect("distinct textures per slot",
           vrapi_GetTextureSwapChainHandle(chain, 0) != vrapi_GetTextureSwapChainHandle(chain, 1), 1);
    /* The index arrives inside ovrLayerProjection2, so out-of-range is another
     * face of a layout mismatch. */
    expect("index past the ring aborts", aborts_on_handle(chain, 3), 1);
    expect("negative index aborts", aborts_on_handle(chain, -1), 1);

    puts("defaults and clamping");
    ovrTextureSwapChain *deflt = vrapi_CreateTextureSwapChain3(0, GL_RGBA8, 64, 64, 1, 0);
    expect("bufferCount 0 defaults to 3", vrapi_GetTextureSwapChainLength(deflt), 3);
    vrapi_DestroyTextureSwapChain(deflt);

    ovrTextureSwapChain *big = vrapi_CreateTextureSwapChain3(0, GL_RGBA8, 64, 64, 1, 99);
    expect("oversized ring clamped",
           vrapi_GetTextureSwapChainLength(big), VRAPI_TEXTURE_SWAPCHAIN_MAX_LENGTH);
    vrapi_DestroyTextureSwapChain(big);

    expect("unsupported format returns NULL",
           vrapi_CreateTextureSwapChain3(0, 0xDEAD, 64, 64, 1, 3) == NULL, 1);

    puts("partial allocation unwinds");
    /* A half-built ring would render into real textures at some indices and
     * null at others, surfacing only at a particular frame parity. */
    g_allocated = g_released = 0; g_fail_after = 2;
    expect("returns NULL", vrapi_CreateTextureSwapChain3(0, GL_RGBA8, 64, 64, 1, 3) == NULL, 1);
    expect("released everything it allocated", g_released, g_allocated);
    g_fail_after = -1;

    puts("command ordering");
    /* Array order is compositing order; a UI layer emitted before the world
     * would render behind it. */
    kl_frame_plan plan; memset(&plan, 0, sizeof plan);
    plan.frame_index = 7;
    plan.layer_count = 3;
    plan.layers[0] = (kl_layer_plan){ .index = 0, .type = VRAPI_LAYER_TYPE_PROJECTION2,
        .support = KL_LAYER_NATIVE, .color = { chain, chain },
        .swapchain_index = { 0, 1 }, .eye_count = 2 };
    plan.layers[1] = (kl_layer_plan){ .index = 1, .type = VRAPI_LAYER_TYPE_LOADING_ICON2,
        .support = KL_LAYER_IGNORED };
    plan.layers[2] = (kl_layer_plan){ .index = 2, .type = VRAPI_LAYER_TYPE_CYLINDER2,
        .support = KL_LAYER_EMULATED };

    kl_command_list list;
    expect("builds", kl_vrapi_build_commands(&plan, &list), ovrSuccess);
    expect("two eyes plus one emulated", list.count, 3);
    expect("eye 0 first", list.commands[0].op, KL_OP_PRESENT_EYE);
    expect("  is eye 0", list.commands[0].eye, 0);
    expect("  texture resolved", list.commands[0].texture != NULL, 1);
    expect("eye 1 second", list.commands[1].eye, 1);
    expect("  uses index 1", list.commands[1].chain_index, 1);
    /* Submitted after the projection layer, so it must be emitted after it. */
    expect("emulated layer last", list.commands[2].op, KL_OP_DRAW_EMULATED);
    expect("  keeps its submitted index", list.commands[2].layer_index, 2);

    puts("monoscopic projection still fills both eyes");
    memset(&plan, 0, sizeof plan);
    plan.layer_count = 1;
    plan.layers[0] = (kl_layer_plan){ .index = 0, .type = VRAPI_LAYER_TYPE_PROJECTION2,
        .support = KL_LAYER_NATIVE, .color = { chain, NULL },
        .swapchain_index = { 2, 0 }, .eye_count = 1 };
    expect("builds", kl_vrapi_build_commands(&plan, &list), ovrSuccess);
    expect("still two presents", list.count, 2);
    expect("eye 1 falls back to eye 0's chain", list.commands[1].chain_index, 2);

    expect("null plan refused", kl_vrapi_build_commands(NULL, &list), ovrError_InvalidParameter);

    vrapi_DestroyTextureSwapChain(chain);
    printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "PASSED",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
