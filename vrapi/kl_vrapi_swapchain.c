/* Texture swapchains.
 *
 * VrApi's model is simple and worth preserving exactly: the guest asks for N
 * textures, then picks the index it renders into each frame and tells us which
 * one it used at submit time. We never hand out an index, so there is no
 * acquire/release protocol to get wrong — only a ring to allocate and an index
 * to validate.
 *
 * Validating that index matters more than it looks. It arrives inside
 * ovrLayerProjection2, so an index outside the ring is another symptom of the
 * struct layout disagreeing, and it is cheap to catch here. */
#include "kl_vrapi.h"

#include <stdlib.h>
#include <string.h>

struct ovrTextureSwapChain {
    int             length;
    int             width;
    int             height;
    int             levels;
    kl_pixel_format format;
    void           *textures[VRAPI_TEXTURE_SWAPCHAIN_MAX_LENGTH];
};

static struct {
    kl_texture_allocator alloc;
    void (*release)(void *texture, void *context);
    void *context;
} g_allocator;

void kl_vrapi_set_texture_allocator(kl_texture_allocator alloc,
                                    void (*release)(void *texture, void *context),
                                    void *context)
{
    g_allocator.alloc   = alloc;
    g_allocator.release = release;
    g_allocator.context = context;
}

/* GL internal formats, as VrApi spells them. */
#define GL_RGBA8              0x8058
#define GL_SRGB8_ALPHA8       0x8C43
#define GL_RGB565             0x8D62
#define GL_RGBA16F            0x881A
#define GL_DEPTH_COMPONENT16  0x81A5
#define GL_DEPTH_COMPONENT24  0x81A6
#define GL_DEPTH24_STENCIL8   0x88F0
#define GL_DEPTH_COMPONENT32F 0x8CAC

kl_pixel_format kl_vrapi_format_from_gl(int64_t gl_internal_format)
{
    switch (gl_internal_format) {
    case GL_RGBA8:              return KL_PIXFMT_RGBA8;
    case GL_SRGB8_ALPHA8:       return KL_PIXFMT_RGBA8_SRGB;
    case GL_RGB565:             return KL_PIXFMT_RGB565;
    case GL_RGBA16F:            return KL_PIXFMT_RGBA16F;
    case GL_DEPTH_COMPONENT16:  return KL_PIXFMT_DEPTH16;
    case GL_DEPTH_COMPONENT24:  return KL_PIXFMT_DEPTH24;
    case GL_DEPTH24_STENCIL8:   return KL_PIXFMT_DEPTH24_STENCIL8;
    case GL_DEPTH_COMPONENT32F: return KL_PIXFMT_DEPTH32F;
    default:                    return KL_PIXFMT_UNSUPPORTED;
    }
}

const char *kl_pixel_format_name(kl_pixel_format format)
{
    switch (format) {
    case KL_PIXFMT_RGBA8:             return "RGBA8";
    case KL_PIXFMT_RGBA8_SRGB:        return "RGBA8_SRGB";
    case KL_PIXFMT_RGB565:            return "RGB565";
    case KL_PIXFMT_RGBA16F:           return "RGBA16F";
    case KL_PIXFMT_DEPTH16:           return "DEPTH16";
    case KL_PIXFMT_DEPTH24:           return "DEPTH24";
    case KL_PIXFMT_DEPTH24_STENCIL8:  return "DEPTH24_STENCIL8";
    case KL_PIXFMT_DEPTH32F:          return "DEPTH32F";
    case KL_PIXFMT_UNSUPPORTED:       return "UNSUPPORTED";
    }
    return "UNSUPPORTED";
}

int kl_pixel_format_is_depth(kl_pixel_format format)
{
    return format == KL_PIXFMT_DEPTH16 || format == KL_PIXFMT_DEPTH24
        || format == KL_PIXFMT_DEPTH24_STENCIL8 || format == KL_PIXFMT_DEPTH32F;
}

ovrTextureSwapChain *vrapi_CreateTextureSwapChain3(int type, int64_t format,
                                                   int width, int height,
                                                   int levels, int bufferCount)
{
    (void)type;   /* 2D vs array: one texture per slot either way here */

    if (width <= 0 || height <= 0 || levels <= 0) {
        KL_VRAPI_FATAL("nonsensical swapchain geometry %dx%d levels=%d — "
                       "arguments read from the wrong offsets look like this",
                       width, height, levels);
    }

    kl_pixel_format pixel = kl_vrapi_format_from_gl(format);
    if (pixel == KL_PIXFMT_UNSUPPORTED) {
        /* Returning NULL is the documented failure and titles handle it, but
         * without the format spelled out the guest's own log says only that
         * swapchain creation failed. */
        fprintf(stderr, "[klepton/vrapi] unsupported swapchain format 0x%llx\n",
                (unsigned long long)format);
        return NULL;
    }

    /* VrApi treats <=0 as "pick for me". Three is what Quest used, and titles
     * that index by frame parity depend on the length being what they asked
     * for when they did ask. */
    int length = bufferCount > 0 ? bufferCount : 3;
    if (length > VRAPI_TEXTURE_SWAPCHAIN_MAX_LENGTH)
        length = VRAPI_TEXTURE_SWAPCHAIN_MAX_LENGTH;

    if (!g_allocator.alloc)
        KL_VRAPI_FATAL("no texture allocator installed — the Darwin runtime "
                       "must call kl_vrapi_set_texture_allocator before the "
                       "guest starts");

    ovrTextureSwapChain *chain = calloc(1, sizeof *chain);
    if (!chain) return NULL;

    chain->length = length;
    chain->width  = width;
    chain->height = height;
    chain->levels = levels;
    chain->format = pixel;

    for (int i = 0; i < length; i++) {
        chain->textures[i] = g_allocator.alloc(pixel, width, height, levels,
                                               g_allocator.context);
        if (!chain->textures[i]) {
            /* Partial rings are worse than none: the guest would render into
             * real textures for some indices and null for others, and only
             * discover it at some frame parity. */
            for (int j = 0; j < i; j++)
                if (g_allocator.release)
                    g_allocator.release(chain->textures[j], g_allocator.context);
            free(chain);
            return NULL;
        }
    }
    return chain;
}

int vrapi_GetTextureSwapChainLength(ovrTextureSwapChain *chain)
{
    return chain ? chain->length : 0;
}

void *vrapi_GetTextureSwapChainHandle(ovrTextureSwapChain *chain, int index)
{
    if (!chain) return NULL;
    if (index < 0 || index >= chain->length)
        KL_VRAPI_FATAL("swapchain index %d outside a ring of %d — the index "
                       "comes from ovrLayerProjection2, so this is the layout "
                       "disagreeing", index, chain->length);
    return chain->textures[index];
}

void vrapi_DestroyTextureSwapChain(ovrTextureSwapChain *chain)
{
    if (!chain) return;
    for (int i = 0; i < chain->length; i++)
        if (chain->textures[i] && g_allocator.release)
            g_allocator.release(chain->textures[i], g_allocator.context);
    free(chain);
}

int kl_vrapi_swapchain_geometry(const ovrTextureSwapChain *chain,
                                int *width, int *height, kl_pixel_format *format)
{
    if (!chain) return 0;
    if (width)  *width  = chain->width;
    if (height) *height = chain->height;
    if (format) *format = chain->format;
    return 1;
}
