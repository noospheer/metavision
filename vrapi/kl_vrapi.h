/* VrApi, declared from the public API documentation.
 *
 * Meta's VrApi_Types.h is not redistributable, so these are our own
 * declarations of the same ABI. Every layout claim is checked — see
 * kl_vrapi_abi.h for how, and for what happens when it cannot be. */
#ifndef KL_VRAPI_H
#define KL_VRAPI_H

#include <stdint.h>
#include "kl_vrapi_abi.h"

/* --- results ------------------------------------------------------------ */
typedef enum {
    VRAPI_INITIALIZE_SUCCESS          = 0,
    VRAPI_INITIALIZE_UNKNOWN_ERROR    = -1,
    VRAPI_INITIALIZE_PERMISSIONS_ERROR = -2,
    VRAPI_INITIALIZE_ALREADY_INITIALIZED = -3,
} ovrInitializeStatus;

typedef enum {
    ovrSuccess              = 0,
    ovrError_MemoryAllocationFailure = -1000,
    ovrError_NotInitialized = -1004,
    ovrError_InvalidParameter = -1005,
    ovrError_DeviceUnavailable = -1010,
    ovrError_InvalidOperation = -1015,
} ovrResult;

/* --- structure tags ------------------------------------------------------
 * First member of every parms struct. Validated on entry, because it is the
 * cheapest signal that our layout and the guest's disagree. */
typedef enum {
    VRAPI_STRUCTURE_TYPE_INIT_PARMS       = 1,
    VRAPI_STRUCTURE_TYPE_MODE_PARMS       = 2,
    VRAPI_STRUCTURE_TYPE_FRAME_PARMS      = 3,
    VRAPI_STRUCTURE_TYPE_MODE_PARMS_VULKAN = 5,
} ovrStructureType;

/* --- layers --------------------------------------------------------------
 * vrapi_SubmitFrame2 takes a heterogeneous array of these, discriminated by
 * the Type in each header. Mapping them onto CompositorServices is the whole
 * job of this shim. */
typedef enum {
    VRAPI_LAYER_TYPE_PROJECTION2   = 1,
    VRAPI_LAYER_TYPE_CYLINDER2     = 3,
    VRAPI_LAYER_TYPE_CUBE2         = 4,
    VRAPI_LAYER_TYPE_EQUIRECT2     = 5,
    VRAPI_LAYER_TYPE_LOADING_ICON2 = 6,
    VRAPI_LAYER_TYPE_FISHEYE2      = 7,
} ovrLayerType2;

/* How each layer type is served. Kept as data so the policy is inspectable and
 * testable rather than buried in a switch. */
typedef enum {
    KL_LAYER_NATIVE,     /* maps onto a CompositorServices layer directly */
    KL_LAYER_EMULATED,   /* rendered into the projection layer by us */
    KL_LAYER_IGNORED,    /* safely dropped; the frame is still correct */
} kl_layer_support;

kl_layer_support kl_vrapi_layer_support(ovrLayerType2 type);
const char      *kl_vrapi_layer_name(ovrLayerType2 type);

/* --- tracking ------------------------------------------------------------ */
typedef enum {
    VRAPI_TRACKING_SPACE_LOCAL          = 0,
    VRAPI_TRACKING_SPACE_LOCAL_FLOOR    = 1,
    VRAPI_TRACKING_SPACE_STAGE          = 5,
} ovrTrackingSpace;

/* ARKit has no stage concept, so STAGE resolves to the floor space. Exposed
 * rather than inlined so the substitution is visible and tested. */
ovrTrackingSpace kl_vrapi_resolve_tracking_space(ovrTrackingSpace requested);

/* --- system properties ---------------------------------------------------
 * Titles branch hard on these. The values decide render target size and, on
 * some titles, whether they start at all. */
typedef enum {
    VRAPI_SYS_PROP_DISPLAY_PIXELS_WIDE          = 0,
    VRAPI_SYS_PROP_DISPLAY_PIXELS_HIGH          = 1,
    VRAPI_SYS_PROP_DISPLAY_REFRESH_RATE         = 4,
    VRAPI_SYS_PROP_SUGGESTED_EYE_TEXTURE_WIDTH  = 6,
    VRAPI_SYS_PROP_SUGGESTED_EYE_TEXTURE_HEIGHT = 7,
    VRAPI_SYS_PROP_DEVICE_TYPE                  = 10,
    VRAPI_SYS_PROP_MAX_FULLSPEED_FRAMEBUFFER_SAMPLES = 13,
    VRAPI_SYS_PROP_NUM_SUPPORTED_DISPLAY_REFRESH_RATES = 64,
} ovrSystemProperty;

int   kl_vrapi_system_property_int(ovrSystemProperty prop, int *out);
int   kl_vrapi_system_property_float(ovrSystemProperty prop, float *out);

/* Device identity. Reporting Quest 2 rather than an unknown value matters:
 * titles gate features and render scale on it, and an unrecognised device
 * sends some down a conservative path or straight to an abort. */
#define VRAPI_DEVICE_TYPE_OCULUSQUEST2 3000


/* --- geometry ----------------------------------------------------------- */
/* Every layout below is read from the DWARF in a real libvrapi.so rather than
 * inferred; tools/metavision-vrapi-abi --dwarf regenerates it. Two of these
 * were wrong when written by hand, in ways nothing would have reported. */
typedef struct { float x, y, z; }    ovrVector3f;
typedef struct { float x, y, z, w; } ovrVector4f;
typedef struct { float M[4][4]; }    ovrMatrix4f;

typedef struct {
    ovrVector4f Orientation;
    ovrVector3f Translation;
} ovrPosef;                                        /* 28 */

typedef struct {
    ovrPosef    Pose;                              /*  0 */
    ovrVector3f AngularVelocity;                   /* 28 */
    ovrVector3f LinearVelocity;                    /* 40 */
    ovrVector3f AngularAcceleration;               /* 52 */
    ovrVector3f LinearAcceleration;                /* 64 */
    float       dead0;                             /* 76 */
    double      TimeInSeconds;                     /* 80 */
    double      PredictionInSeconds;               /* 88 */
} ovrRigidBodyPosef;                               /* 96 */

typedef struct ovrTextureSwapChain ovrTextureSwapChain;

#define VRAPI_FRAME_LAYER_EYE_MAX 2
#define VRAPI_MAX_LAYERS         16

/* --- frame submission ---------------------------------------------------
 * The struct vrapi_SubmitFrame2 reads every frame. If our layout of this is
 * wrong, every frame is wrong, so it is the first thing the extractor checks. */
typedef struct {
    ovrLayerType2 Type;
    uint32_t      Flags;
    ovrVector4f   ColorScale;
    int32_t       SrcBlend;
    int32_t       DstBlend;
    uint8_t       Reserved[4];
} ovrLayerHeader2;

typedef struct {
    ovrLayerHeader2   Header;
    ovrRigidBodyPosef HeadPose;
    struct {
        ovrTextureSwapChain *ColorSwapChain;
        int                  SwapChainIndex;
        ovrMatrix4f          TexCoordsFromTanAngles;
        float                TextureRect[4];
    } Textures[VRAPI_FRAME_LAYER_EYE_MAX];
} ovrLayerProjection2;

typedef struct {
    uint32_t Flags;
    uint32_t SwapInterval;
    uint64_t FrameIndex;
    double   DisplayTime;
    uint8_t  Pad[8];
    uint32_t LayerCount;
    const ovrLayerHeader2 *const *Layers;
} ovrSubmitFrameDescription2;

KL_ABI_CHECK_OFFSET(ovrSubmitFrameDescription2, Flags);
KL_ABI_CHECK_OFFSET(ovrSubmitFrameDescription2, SwapInterval);
KL_ABI_CHECK_OFFSET(ovrSubmitFrameDescription2, FrameIndex);
KL_ABI_CHECK_OFFSET(ovrSubmitFrameDescription2, DisplayTime);
KL_ABI_CHECK_OFFSET(ovrSubmitFrameDescription2, LayerCount);
KL_ABI_CHECK_OFFSET(ovrSubmitFrameDescription2, Layers);
KL_ABI_CHECK_OFFSET(ovrLayerHeader2, Type);
KL_ABI_CHECK_OFFSET(ovrLayerHeader2, Flags);
KL_ABI_CHECK_OFFSET(ovrLayerHeader2, ColorScale);

/* --- frame plan ---------------------------------------------------------
 * Walking the layer array is pure, so it is separated from executing the plan
 * against CompositorServices and tested without a device. */
typedef struct {
    uint32_t             index;
    ovrLayerType2        type;
    kl_layer_support     support;
    ovrTextureSwapChain *color[VRAPI_FRAME_LAYER_EYE_MAX];
    int                  swapchain_index[VRAPI_FRAME_LAYER_EYE_MAX];
    uint32_t             eye_count;
} kl_layer_plan;

typedef struct {
    uint64_t      frame_index;
    double        display_time;
    uint32_t      swap_interval;
    uint32_t      layer_count;
    kl_layer_plan layers[VRAPI_MAX_LAYERS];
    uint32_t      native_count;
    uint32_t      emulated_count;
    uint32_t      ignored_count;
} kl_frame_plan;

ovrResult kl_vrapi_plan_frame(const ovrSubmitFrameDescription2 *desc,
                              kl_frame_plan *out);


/* --- pixel formats -------------------------------------------------------
 * VrApi names formats with GL internal-format constants. We translate to our
 * own enum rather than straight to MTLPixelFormat so the mapping is testable
 * without Metal, and so the one place that names Metal constants is a Darwin
 * file where the compiler checks them against the real headers. Guessing Metal
 * enum values in portable code is exactly the silent-wrongness this project
 * keeps designing against. */
typedef enum {
    KL_PIXFMT_UNSUPPORTED = 0,
    KL_PIXFMT_RGBA8,
    KL_PIXFMT_RGBA8_SRGB,
    KL_PIXFMT_RGB565,
    KL_PIXFMT_RGBA16F,
    KL_PIXFMT_DEPTH16,
    KL_PIXFMT_DEPTH24,
    KL_PIXFMT_DEPTH24_STENCIL8,
    KL_PIXFMT_DEPTH32F,
} kl_pixel_format;

kl_pixel_format kl_vrapi_format_from_gl(int64_t gl_internal_format);
const char     *kl_pixel_format_name(kl_pixel_format format);
int             kl_pixel_format_is_depth(kl_pixel_format format);

/* --- swapchains ----------------------------------------------------------
 * Texture allocation is injected so the ring logic tests without Metal. The
 * Darwin build installs a real allocator at startup; tests install a stub. */
typedef void *(*kl_texture_allocator)(kl_pixel_format format, int width,
                                      int height, int levels, void *context);

void kl_vrapi_set_texture_allocator(kl_texture_allocator alloc,
                                    void (*release)(void *texture, void *context),
                                    void *context);

#define VRAPI_TEXTURE_SWAPCHAIN_MAX_LENGTH 8

ovrTextureSwapChain *vrapi_CreateTextureSwapChain3(int type, int64_t format,
                                                   int width, int height,
                                                   int levels, int bufferCount);
int   vrapi_GetTextureSwapChainLength(ovrTextureSwapChain *chain);
void *vrapi_GetTextureSwapChainHandle(ovrTextureSwapChain *chain, int index);
void  vrapi_DestroyTextureSwapChain(ovrTextureSwapChain *chain);

/* Geometry, for the executor and for validating a submitted index. */
int kl_vrapi_swapchain_geometry(const ovrTextureSwapChain *chain,
                                int *width, int *height, kl_pixel_format *format);

/* --- execution -----------------------------------------------------------
 * The plan says what each layer is; this says what to do about it, in order.
 * VrApi composites the layer array back to front, so order is load-bearing and
 * worth pinning down away from the device. */
typedef enum {
    KL_OP_PRESENT_EYE,     /* blit a projection swapchain into the drawable */
    KL_OP_DRAW_EMULATED,   /* render a non-native layer into the drawable */
} kl_command_op;

typedef struct {
    kl_command_op        op;
    uint32_t             layer_index;
    ovrLayerType2        type;
    uint32_t             eye;
    ovrTextureSwapChain *chain;
    int                  chain_index;
    void                *texture;      /* resolved from chain + index */
} kl_command;

#define KL_MAX_COMMANDS (VRAPI_MAX_LAYERS * VRAPI_FRAME_LAYER_EYE_MAX)

typedef struct {
    kl_command commands[KL_MAX_COMMANDS];
    uint32_t   count;
} kl_command_list;

ovrResult kl_vrapi_build_commands(const kl_frame_plan *plan, kl_command_list *out);


/* --- mode lifecycle ------------------------------------------------------
 * Initialize -> EnterVrMode -> frames -> LeaveVrMode -> Shutdown.
 *
 * Titles get this wrong in ways that are silent on Quest because VrApi is
 * lenient, and fatal here because CompositorServices is not: submitting before
 * a session exists, entering twice, or holding an ovrMobile across a leave.
 * The state machine is pure, so it is checked without a device. */
typedef struct ovrMobile ovrMobile;

typedef enum {
    KL_VR_UNINITIALIZED = 0,
    KL_VR_INITIALIZED,
    KL_VR_ENTERED,
    KL_VR_SHUTDOWN,
} kl_vr_state;

typedef struct { ovrStructureType Type; uint32_t Flags; } ovrModeParms;

/* Session creation is injected, as texture allocation is: the lifecycle rules
 * are the part worth testing, and they do not need CompositorServices. */
typedef void *(*kl_session_open)(void *context);
void kl_vrapi_set_session_hooks(kl_session_open open,
                                void (*close)(void *session, void *context),
                                void *context);

ovrInitializeStatus vrapi_Initialize(const void *initParms);
void       vrapi_Shutdown(void);
ovrMobile *vrapi_EnterVrMode(const ovrModeParms *parms);
void       vrapi_LeaveVrMode(ovrMobile *ovr);

kl_vr_state kl_vrapi_state(void);
int         kl_vrapi_mobile_is_live(const ovrMobile *ovr);
void       *kl_vrapi_session(const ovrMobile *ovr);

/* --- poses ---------------------------------------------------------------
 * ovrMatrix4f is ROW-major; simd_float4x4 is COLUMN-major. Getting that wrong
 * transposes every rotation, which presents as the world turning the wrong way
 * — recognisable, but only once you have seen it. The conversion is pure, so
 * the convention is pinned by tests rather than by comment. */
void kl_quat_from_matrix(const ovrMatrix4f *row_major, ovrVector4f *out);
void kl_matrix_from_quat(const ovrVector4f *quat, ovrMatrix4f *out_row_major);

/* Transpose in place between the two conventions. */
void kl_matrix_transpose(const ovrMatrix4f *in, ovrMatrix4f *out);

/* Absolute display time for a frame, in seconds. Titles pace animation off the
 * delta between successive calls, so a wrong slope shows up as slow motion
 * rather than as an error. */
double kl_vrapi_predicted_display_time(double now, int64_t frame_index,
                                       int64_t current_frame, float refresh_hz);

/* Two corrections the extractor forced, neither of which would have announced
 * itself: HeadPose sits at 8, behind a Status word, so reading it at 0 yields a
 * status code marshalled as an orientation; and each Eye entry is 128 bytes, a
 * view and a projection matrix, not the single matrix declared here first. */
typedef struct {
    uint32_t          Status;                      /*   0 */
    uint32_t          dead1;                       /*   4 */
    ovrRigidBodyPosef HeadPose;                    /*   8 */
    struct {
        ovrMatrix4f ViewMatrix;
        ovrMatrix4f ProjectionMatrix;
    } Eye[VRAPI_FRAME_LAYER_EYE_MAX];              /* 104 */
} ovrTracking2;                                    /* 360 */

KL_ABI_CHECK_OFFSET(ovrPosef, Orientation);
KL_ABI_CHECK_SIZE(ovrPosef);
KL_ABI_CHECK_OFFSET(ovrRigidBodyPosef, Pose);
KL_ABI_CHECK_OFFSET(ovrRigidBodyPosef, TimeInSeconds);
KL_ABI_CHECK_SIZE(ovrRigidBodyPosef);
KL_ABI_CHECK_OFFSET(ovrTracking2, Status);
KL_ABI_CHECK_OFFSET(ovrTracking2, HeadPose);
KL_ABI_CHECK_OFFSET(ovrTracking2, Eye);
KL_ABI_CHECK_SIZE(ovrTracking2);

double     vrapi_GetPredictedDisplayTime(ovrMobile *ovr, int64_t frameIndex);
ovrTracking2 vrapi_GetPredictedTracking2(ovrMobile *ovr, double absTime);

#endif
