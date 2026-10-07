// Meta hand tracking for every title, from visionOS hand tracking.
//
// Titles built on Meta's SDK read hands through four OVRPlugin calls. Klepton
// refuses them (it had no layout for the structs); these answer them from the
// hand skeleton the app already receives from ARKit:
//
//   ovrp_GetHandTrackingEnabled  yes, unless the input mode ignores hands
//   ovrp_GetSkeleton2 / 3        the bind skeleton: 24 hand bones, their
//                                parents, and each bone's rest pose in its
//                                parent's frame — measured from the user's own
//                                hand the first time it is seen
//   ovrp_GetHandState            per frame: wrist pose in tracking space, each
//                                bone's rotation in its parent's frame, pinch
//                                strengths, a pointing ray, confidences
//
// The struct layouts are OVRPlugin's C# bindings (OVRPlugin.HandStateInternal,
// Skeleton2Internal, Skeleton3Internal), identical across the titles checked;
// the static asserts below pin every offset. ARKit and OVRPlugin share a
// right-handed, Y-up, -Z-forward convention, so poses pass through unchanged
// and Unity applies its own Z flip as it does on a Quest.
//
// Bone frames are ARKit's joint frames, not Meta's. Anything built from bone
// positions — the hand skeleton, colliders, particles, pinch tests — sees the
// real hand. Meta's own hand MESH is skinned to Meta's frames, so ovrp_GetMesh
// stays refused and titles draw no mesh (OVRMesh checks the result).
#include "mv_hands.h"

#include <math.h>
#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <string.h>

#define OVRP_SUCCESS             0
#define OVRP_FAILURE         -1000
#define OVRP_FAIL_INVALID_PARAM -1001

typedef struct { float x, y, z, w; } mv_quat;
typedef struct { float x, y, z; } mv_vec3;
typedef struct { mv_quat o; mv_vec3 p; } mv_pose;

enum { ST_TRACKED = 1, ST_VALID = 2, ST_DOMINANT = 128 };
#define CONF_HIGH 0x3f800000   // TrackingConfidence.High (the bits of 1.0f)

typedef struct {
    int32_t status;
    mv_pose root;
    mv_quat rot[MV_HAND_BONES];
    uint32_t pinches;
    float pinch[5];
    mv_pose pointer;
    float scale;
    int32_t confidence;
    int32_t finger_confidence[5];
    double requested_time, sample_time;
} ovrp_hand_state;
_Static_assert(offsetof(ovrp_hand_state, root) == 0x4, "HandState.RootPose");
_Static_assert(offsetof(ovrp_hand_state, rot) == 0x20, "HandState.BoneRotations");
_Static_assert(offsetof(ovrp_hand_state, pinches) == 0x1a0, "HandState.Pinches");
_Static_assert(offsetof(ovrp_hand_state, pointer) == 0x1b8, "HandState.PointerPose");
_Static_assert(offsetof(ovrp_hand_state, scale) == 0x1d4, "HandState.HandScale");
_Static_assert(offsetof(ovrp_hand_state, finger_confidence) == 0x1dc, "HandState.FingerConfidences");
_Static_assert(offsetof(ovrp_hand_state, requested_time) == 0x1f0, "HandState.RequestedTimeStamp");
_Static_assert(sizeof(ovrp_hand_state) == 0x200, "HandStateInternal");

typedef struct { int32_t id; int16_t parent; mv_pose pose; } ovrp_bone;
typedef struct { int16_t bone; mv_vec3 start, end; float radius; } ovrp_capsule;
_Static_assert(offsetof(ovrp_bone, pose) == 0x8 && sizeof(ovrp_bone) == 0x24, "Bone");
_Static_assert(sizeof(ovrp_capsule) == 0x20, "BoneCapsule");

typedef struct { int32_t type; uint32_t num_bones, num_capsules;
                 ovrp_bone bones[70]; ovrp_capsule capsules[19]; } ovrp_skeleton2;
typedef struct { int32_t type; uint32_t num_bones, num_capsules;
                 ovrp_bone bones[84]; ovrp_capsule capsules[19]; } ovrp_skeleton3;
_Static_assert(offsetof(ovrp_skeleton2, capsules) == 0x9e4 && sizeof(ovrp_skeleton2) == 0xc44, "Skeleton2Internal");
_Static_assert(offsetof(ovrp_skeleton3, capsules) == 0xbdc && sizeof(ovrp_skeleton3) == 0xe3c, "Skeleton3Internal");

// OVRPlugin's hand hierarchy, by BoneId.
static const int16_t k_parent[MV_HAND_BONES] = {
    -1, 0,              // WristRoot, ForearmStub
    0, 2, 3, 4,         // Thumb0..3
    0, 6, 7,            // Index1..3
    0, 9, 10,           // Middle1..3
    0, 12, 13,          // Ring1..3
    0, 15, 16, 17,      // Pinky0..3
    5, 8, 11, 14, 18,   // tips
};

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_enabled = 1;
static struct {
    int tracked, have_bind;
    double time;
    mv_pose model[MV_HAND_BONES], root, pointer;
    mv_vec3 bind[MV_HAND_BONES];   // rest position of each bone in its parent's frame
    float pinch[5];
} g_hand[2];

static mv_quat q_conj(mv_quat q) { return (mv_quat){ -q.x, -q.y, -q.z, q.w }; }
static mv_quat q_mul(mv_quat a, mv_quat b) {
    return (mv_quat){ a.w*b.x + a.x*b.w + a.y*b.z - a.z*b.y,
                      a.w*b.y - a.x*b.z + a.y*b.w + a.z*b.x,
                      a.w*b.z + a.x*b.y - a.y*b.x + a.z*b.w,
                      a.w*b.w - a.x*b.x - a.y*b.y - a.z*b.z };
}
static mv_vec3 q_rot(mv_quat q, mv_vec3 v) {
    mv_quat r = q_mul(q_mul(q, (mv_quat){ v.x, v.y, v.z, 0 }), q_conj(q));
    return (mv_vec3){ r.x, r.y, r.z };
}
static mv_pose pose_from(const float *f) {
    return (mv_pose){ { f[0], f[1], f[2], f[3] }, { f[4], f[5], f[6] } };
}
static mv_quat local_rot(const mv_pose *m, int i) {
    int p = k_parent[i];
    return p < 0 ? (mv_quat){ 0, 0, 0, 1 } : q_mul(q_conj(m[p].o), m[i].o);
}
static mv_vec3 local_pos(const mv_pose *m, int i) {
    int p = k_parent[i];
    if (p < 0) return (mv_vec3){ 0, 0, 0 };
    mv_vec3 d = { m[i].p.x - m[p].p.x, m[i].p.y - m[p].p.y, m[i].p.z - m[p].p.z };
    return q_rot(q_conj(m[p].o), d);
}

void mv_hands_set_enabled(int on) {
    pthread_mutex_lock(&g_lock);
    g_enabled = on;
    pthread_mutex_unlock(&g_lock);
}

void mv_hands_publish(int hand, int tracked, const float *model, const float *root,
                      const float *pointer, const float *pinch, double time_s) {
    if (hand < 0 || hand > 1) return;
    pthread_mutex_lock(&g_lock);
    g_hand[hand].tracked = tracked && model && root;
    g_hand[hand].time = time_s;
    if (g_hand[hand].tracked) {
        for (int i = 0; i < MV_HAND_BONES; i++) g_hand[hand].model[i] = pose_from(model + 7 * i);
        g_hand[hand].root = pose_from(root);
        g_hand[hand].pointer = pointer ? pose_from(pointer) : g_hand[hand].root;
        for (int i = 0; i < 5; i++) g_hand[hand].pinch[i] = pinch ? pinch[i] : 0;
        if (!g_hand[hand].have_bind) {
            // The rest skeleton is the user's own hand, measured once: titles
            // read it at startup and size colliders and visuals from it.
            for (int i = 0; i < MV_HAND_BONES; i++) g_hand[hand].bind[i] = local_pos(g_hand[hand].model, i);
            g_hand[hand].have_bind = 1;
            fprintf(stderr, "  [mv-hands] %s hand seen: skeleton measured, hand tracking live\n",
                    hand ? "right" : "left");
        }
    }
    pthread_mutex_unlock(&g_lock);
}

static int32_t mv_GetHandTrackingEnabled(int32_t *out) {
    if (!out) return OVRP_FAIL_INVALID_PARAM;
    pthread_mutex_lock(&g_lock);
    *out = g_enabled;
    pthread_mutex_unlock(&g_lock);
    return OVRP_SUCCESS;
}

// Fails until the hand has been seen once; OVRSkeleton retries every frame
// until it gets a skeleton, so the bind pose is the user's real hand.
static int32_t fill_skeleton(int type, int32_t *head, ovrp_bone *bones, int max_bones) {
    if (type < 0 || type > 1 || !head) return OVRP_FAIL_INVALID_PARAM;
    pthread_mutex_lock(&g_lock);
    if (!g_enabled || !g_hand[type].have_bind) {
        pthread_mutex_unlock(&g_lock);
        return OVRP_FAILURE;
    }
    head[0] = type;
    head[1] = MV_HAND_BONES;
    head[2] = 0;                     // no capsules: physics hands are opt-in
    for (int i = 0; i < max_bones; i++) {
        bones[i] = (ovrp_bone){ .id = i < MV_HAND_BONES ? i : -1, .parent = -1,
                                .pose = { { 0, 0, 0, 1 }, { 0, 0, 0 } } };
        if (i < MV_HAND_BONES) {
            bones[i].parent = k_parent[i];
            bones[i].pose.p = g_hand[type].bind[i];
        }
    }
    pthread_mutex_unlock(&g_lock);
    return OVRP_SUCCESS;
}

static int32_t mv_GetSkeleton2(int32_t type, ovrp_skeleton2 *out) {
    if (!out) return OVRP_FAIL_INVALID_PARAM;
    int32_t r = fill_skeleton(type, &out->type, out->bones, 70);
    if (r == OVRP_SUCCESS) memset(out->capsules, 0, sizeof out->capsules);
    return r;
}

static int32_t mv_GetSkeleton3(int32_t type, ovrp_skeleton3 *out) {
    if (!out) return OVRP_FAIL_INVALID_PARAM;
    int32_t r = fill_skeleton(type, &out->type, out->bones, 84);
    if (r == OVRP_SUCCESS) memset(out->capsules, 0, sizeof out->capsules);
    return r;
}

static int32_t mv_GetHandState(int32_t step, int32_t hand, ovrp_hand_state *out) {
    (void)step;   // Render or Physics: one pose serves both
    if (hand < 0 || hand > 1 || !out) return OVRP_FAIL_INVALID_PARAM;
    memset(out, 0, sizeof *out);
    out->root.o.w = out->pointer.o.w = 1;
    for (int i = 0; i < MV_HAND_BONES; i++) out->rot[i].w = 1;
    out->scale = 1;
    pthread_mutex_lock(&g_lock);
    if (g_enabled && g_hand[hand].tracked) {
        const mv_pose *m = g_hand[hand].model;
        out->status = ST_TRACKED | ST_VALID | (hand == 1 ? ST_DOMINANT : 0);
        out->root = g_hand[hand].root;
        for (int i = 0; i < MV_HAND_BONES; i++) out->rot[i] = local_rot(m, i);
        for (int i = 0; i < 5; i++) {
            out->pinch[i] = g_hand[hand].pinch[i];
            if (out->pinch[i] >= 0.9f) out->pinches |= 1u << i;
            out->finger_confidence[i] = CONF_HIGH;
        }
        out->pointer = g_hand[hand].pointer;
        out->confidence = CONF_HIGH;
    }
    out->requested_time = out->sample_time = g_hand[hand].time;
    pthread_mutex_unlock(&g_lock);
    return OVRP_SUCCESS;
}

void *mv_hands_ovrp(const char *name) {
    static const struct { const char *name; void *fn; } k[] = {
        { "ovrp_GetHandTrackingEnabled", (void *)mv_GetHandTrackingEnabled },
        { "ovrp_GetSkeleton2",           (void *)mv_GetSkeleton2 },
        { "ovrp_GetSkeleton3",           (void *)mv_GetSkeleton3 },
        { "ovrp_GetHandState",           (void *)mv_GetHandState },
    };
    for (size_t i = 0; name && i < sizeof k / sizeof k[0]; i++)
        if (strcmp(name, k[i].name) == 0) return k[i].fn;
    return NULL;
}
