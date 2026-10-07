/* The layer walk, exercised without a device.
 *
 * Fatal paths are checked by forking, because they abort by design — that is
 * the behaviour under test, not an obstacle to it. */
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

/* Run a planner call in a child and report whether it aborted. */
static int aborts(const ovrSubmitFrameDescription2 *desc)
{
    fflush(NULL);
    pid_t pid = fork();
    if (pid == 0) {
        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) { dup2(devnull, 2); }
        kl_frame_plan plan;
        kl_vrapi_plan_frame(desc, &plan);
        _exit(0);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFSIGNALED(status) && WTERMSIG(status) == SIGABRT;
}

static ovrLayerProjection2 make_projection(void)
{
    ovrLayerProjection2 layer;
    memset(&layer, 0, sizeof layer);
    layer.Header.Type = VRAPI_LAYER_TYPE_PROJECTION2;
    layer.Textures[0].ColorSwapChain = (ovrTextureSwapChain *)0x1000;
    layer.Textures[1].ColorSwapChain = (ovrTextureSwapChain *)0x2000;
    layer.Textures[0].SwapChainIndex = 1;
    layer.Textures[1].SwapChainIndex = 2;
    return layer;
}

int main(void)
{
    kl_frame_plan plan;

    puts("argument validation");
    expect("null desc refused", kl_vrapi_plan_frame(NULL, &plan), ovrError_InvalidParameter);
    ovrSubmitFrameDescription2 blank; memset(&blank, 0, sizeof blank);
    expect("null out refused", kl_vrapi_plan_frame(&blank, NULL), ovrError_InvalidParameter);

    puts("empty frame is legal");
    expect("zero layers succeeds", kl_vrapi_plan_frame(&blank, &plan), ovrSuccess);
    expect("no layers planned", plan.layer_count, 0);
    /* 0 would stall the compositor waiting on an interval that never elapses. */
    expect("swap interval 0 becomes 1", plan.swap_interval, 1);

    puts("projection layer");
    ovrLayerProjection2 projection = make_projection();
    const ovrLayerHeader2 *layers[] = { &projection.Header };
    ovrSubmitFrameDescription2 desc;
    memset(&desc, 0, sizeof desc);
    desc.LayerCount = 1; desc.Layers = layers;
    desc.FrameIndex = 42; desc.DisplayTime = 1.5; desc.SwapInterval = 2;

    expect("plans successfully", kl_vrapi_plan_frame(&desc, &plan), ovrSuccess);
    expect("one layer", plan.layer_count, 1);
    expect("counted as native", plan.native_count, 1);
    expect("frame index carried", (long)plan.frame_index, 42);
    expect("swap interval respected", plan.swap_interval, 2);
    expect("both eyes found", plan.layers[0].eye_count, 2);
    expect("eye 0 swapchain", (long)(size_t)plan.layers[0].color[0], 0x1000);
    expect("eye 1 index", plan.layers[0].swapchain_index[1], 2);

    puts("mixed layers are bucketed by policy");
    ovrLayerHeader2 cylinder; memset(&cylinder, 0, sizeof cylinder);
    cylinder.Type = VRAPI_LAYER_TYPE_CYLINDER2;
    ovrLayerHeader2 loading; memset(&loading, 0, sizeof loading);
    loading.Type = VRAPI_LAYER_TYPE_LOADING_ICON2;
    const ovrLayerHeader2 *mixed[] = { &projection.Header, &cylinder, &loading };
    desc.LayerCount = 3; desc.Layers = mixed;

    expect("plans successfully", kl_vrapi_plan_frame(&desc, &plan), ovrSuccess);
    expect("three layers", plan.layer_count, 3);
    expect("one native", plan.native_count, 1);
    expect("one emulated", plan.emulated_count, 1);
    expect("one ignored", plan.ignored_count, 1);

    puts("unknown-but-plausible type survives");
    /* A VrApi version we do not model must not kill a working title. */
    ovrLayerHeader2 future; memset(&future, 0, sizeof future);
    future.Type = (ovrLayerType2)9;
    const ovrLayerHeader2 *withFuture[] = { &projection.Header, &future };
    desc.LayerCount = 2; desc.Layers = withFuture;
    expect("still succeeds", kl_vrapi_plan_frame(&desc, &plan), ovrSuccess);
    expect("unknown layer ignored, not fatal", plan.ignored_count, 1);

    puts("layout-drift canaries abort");
    /* Each of these is what a wrong struct offset actually looks like. */
    desc.LayerCount = 1; desc.Layers = NULL;
    expect("null Layers with a count", aborts(&desc), 1);

    desc.LayerCount = 999; desc.Layers = layers;
    expect("implausible LayerCount", aborts(&desc), 1);

    const ovrLayerHeader2 *hasNull[] = { NULL };
    desc.LayerCount = 1; desc.Layers = hasNull;
    expect("null layer pointer", aborts(&desc), 1);

    ovrLayerHeader2 garbage; memset(&garbage, 0, sizeof garbage);
    garbage.Type = (ovrLayerType2)0x41414141;
    const ovrLayerHeader2 *withGarbage[] = { &garbage };
    desc.LayerCount = 1; desc.Layers = withGarbage;
    expect("garbage in the Type word", aborts(&desc), 1);

    ovrLayerProjection2 eyeless = make_projection();
    eyeless.Textures[0].ColorSwapChain = NULL;
    eyeless.Textures[1].ColorSwapChain = NULL;
    const ovrLayerHeader2 *noEyes[] = { &eyeless.Header };
    desc.LayerCount = 1; desc.Layers = noEyes;
    expect("projection with no swapchain", aborts(&desc), 1);

    printf("\n%s (%d failure%s)\n", failures ? "FAILED" : "PASSED",
           failures, failures == 1 ? "" : "s");
    return failures ? 1 : 0;
}
