// Meta hand tracking for every title, from visionOS hand tracking.
//
// Titles built on Meta's SDK read hands through four OVRPlugin calls. Klepton
// refuses them (it had no layout for the structs); these answer them from the
// hand skeleton the app already receives from ARKit:
//
//   ovrp_GetHandTrackingEnabled  yes, unless the input mode ignores hands
//   ovrp_GetSkeleton2 / 3        the bind skeleton: 24 hand bones, their
//                                parents, and each bone's rest pose in its
//                                parent's frame — Meta's own (k_bind below)
//   ovrp_GetHandState            per frame: wrist pose in tracking space, each
//                                bone's rotation in its parent's frame, pinch
//                                strengths, a pointing ray, confidences
//
// The struct layouts are OVRPlugin's C# bindings (OVRPlugin.HandStateInternal,
// Skeleton2Internal, Skeleton3Internal), identical across the titles checked;
// the static asserts below pin every offset. ARKit and OVRPlugin share a
// right-handed, Y-up, -Z-forward tracking space, so world poses pass through
// unchanged and Unity applies its own Z flip as it does on a Quest.
//
// Bone frames are Meta's, not ARKit's. Meta's Interaction SDK does not ask
// for the skeleton at all: it carries Meta's bind skeleton compiled in
// (HandSkeletonOVR) and applies only the bone ROTATIONS it is given. So the
// rotations have to be Meta's — rotations in ARKit's joint frames, applied to
// Meta's bone offsets, bend every finger the wrong way, and a pinch the
// user makes never brings the thumb tip to the index tip. Each frame is
// therefore retargeted from joint POSITIONS (mv_hands_solve): the measured hand
// is turned into Meta's wrist frame and scaled to Meta's hand size, every bone
// is swung from its bind direction onto the measured direction to its child,
// and the last two bones of each finger are solved so the tip lands on the
// measured tip. ARKit's joint orientations are not used. GetSkeleton2/3 answer
// the same bind skeleton, so OVRSkeleton, OVRMesh and the Interaction SDK all
// place a joint in the same spot.
//
// Meta's own hand MESH is skinned to Meta's frames and is not ours to ship, so
// ovrp_GetMesh answers a mesh of our own instead: a tube along every bone of
// the bind skeleton, each vertex bound wholly to the bone it rides.
// OVRMeshRenderer derives the bind poses from that same skeleton, so it skins
// to the live hand. Titles that emit or place effects on the hand mesh
// (SkinnedMeshRenderer.BakeMesh, particle shapes) need one to draw anything.
#include "mv_hands.h"

#include <math.h>
#include <pthread.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
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

// Meta's bind skeleton for the LEFT hand, by BoneId: each bone's rest rotation
// and offset in its parent's frame (OVRPlugin.Skeleton2 layout: orientation,
// then position). The right hand is the same rotations with every offset
// negated. These are the numbers Meta's runtime answers GetSkeleton2 with and
// that its SDK bakes in (OVRSkeletonData.LeftSkeleton/RightSkeleton, read by
// HandSkeletonOVR); copied bit-for-bit from that static constructor in three
// titles' il2cpp code, built with different SDK releases, all identical.
static const mv_pose k_bind[MV_HAND_BONES] = {
    {{ 0, 0, 0, 1 }, { 0, 0, 0 }},   // WristRoot
    {{ 0, 0, 0, 1 }, { 0, 0, 0 }},   // ForearmStub
    {{ 0.375386894f, 0.424584091f, -0.00777885597f, 0.8238644f }, { 0.0200692993f, 0.0115540996f, -0.0104965204f }},   // Thumb0
    {{ 0.260230303f, 0.0243308805f, 0.125678003f, 0.957023084f }, { 0.0248525608f, -9.30999999e-10f, -1.86299998e-09f }},   // Thumb1
    {{ -0.0827037692f, -0.0769617036f, -0.0840622336f, 0.990035713f }, { 0.0325129107f, 5.82000004e-10f, 1.86299998e-09f }},   // Thumb2
    {{ 0.0835059285f, 0.0650157332f, -0.0582740605f, 0.992675185f }, { 0.0337930992f, 3.26000005e-09f, 1.86299998e-09f }},   // Thumb3
    {{ 0.0306830909f, -0.0188555904f, 0.0432814397f, 0.998413622f }, { 0.0959962383f, 0.00731645478f, -0.0235506799f }},   // Index1
    {{ -0.0258524101f, -0.00711606117f, 0.00329294405f, 0.999634981f }, { 0.0379272997f, -5.82000004e-10f, -5.97000005e-10f }},   // Index2
    {{ -0.0160559993f, -0.0271487199f, -0.0720340014f, 0.996903419f }, { 0.0243036505f, -6.72999989e-10f, -6.75e-10f }},   // Index3
    {{ -0.00906632561f, -0.0514655896f, 0.0518357493f, 0.997287393f }, { 0.0956466123f, 0.0025431551f, -0.00172590604f }},   // Middle1
    {{ -0.0112282299f, -0.00437887385f, -0.00197826698f, 0.999925375f }, { 0.0429270007f, -8.50999993e-10f, -1.19300003e-09f }},   // Middle2
    {{ -0.0343195498f, -0.00461183907f, -0.0930070132f, 0.995063126f }, { 0.0275495797f, 3.08999992e-10f, 1.12800003e-09f }},   // Middle3
    {{ -0.0531593598f, -0.123103403f, 0.0498134904f, 0.989716172f }, { 0.0886937976f, 0.00652930792f, 0.0174652394f }},   // Ring1
    {{ -0.0336325206f, -0.0027898401f, 0.00567601994f, 0.999414325f }, { 0.0389961004f, 0, 5.2400001e-10f }},   // Ring2
    {{ -0.0034774621f, 0.0291794501f, -0.0250285398f, 0.999254823f }, { 0.0265733898f, 1.28099997e-09f, 1.63000002e-09f }},   // Ring3
    {{ -0.207036003f, -0.140342802f, 0.0183118004f, 0.968041718f }, { 0.0340735614f, 0.0094198361f, 0.0229985807f }},   // Pinky0
    {{ 0.0911130384f, 0.00407136977f, 0.0281292293f, 0.99543488f }, { 0.0456505492f, 9.97678967e-07f, -2.19396293e-06f }},   // Pinky1
    {{ -0.0376166515f, -0.0429377183f, -0.0132860504f, 0.998280883f }, { 0.0307204202f, 1.04800002e-09f, -1.75000001e-10f }},   // Pinky2
    {{ 0.000644743384f, 0.0491706692f, -0.0240188297f, 0.99850142f }, { 0.0203113798f, -2.91000002e-10f, 9.30999999e-10f }},   // Pinky3
    {{ 0, 0, 0, 1 }, { 0.0245907698f, -0.00102697394f, 0.000670370122f }},   // ThumbTip
    {{ 0, 0, 0, 1 }, { 0.0223633796f, -0.00102506997f, 0.000295607606f }},   // IndexTip
    {{ 0, 0, 0, 1 }, { 0.0249649193f, -0.001137299f, 0.000308652787f }},   // MiddleTip
    {{ 0, 0, 0, 1 }, { 0.0243261307f, -0.00160817197f, 0.000257904991f }},   // RingTip
    {{ 0, 0, 0, 1 }, { 0.0219223797f, -0.00121608598f, -0.000246479613f }},   // PinkyTip
};

// The child each bone is aimed at (its finger's next joint), or -1: the wrist
// is placed by the root pose, the forearm stub and the tips have none.
static const int8_t k_child[MV_HAND_BONES] = {
    -1, -1,
    3, 4, 5, 19,
    7, 8, 20,
    10, 11, 21,
    13, 14, 22,
    16, 17, 18, 23,
    -1, -1, -1, -1, -1,
};
enum { B_WRIST = 0, B_INDEX1 = 6, B_MIDDLE1 = 9, B_RING1 = 12, B_TIP0 = 19 };

static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_enabled = 1;
static struct {
    int tracked, seen;
    double time;
    mv_pose root, pointer;          // root: Meta's wrist frame in tracking space
    mv_quat rot[MV_HAND_BONES];     // each bone's rotation in its parent's frame
    float scale;                    // measured hand size over Meta's
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
static mv_quat q_norm(mv_quat q) {
    float n = sqrtf(q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w);
    return n > 1e-12f ? (mv_quat){ q.x / n, q.y / n, q.z / n, q.w / n } : (mv_quat){ 0, 0, 0, 1 };
}
static mv_pose pose_from(const float *f) {
    return (mv_pose){ { f[0], f[1], f[2], f[3] }, { f[4], f[5], f[6] } };
}

static mv_vec3 v_add(mv_vec3 a, mv_vec3 b) { return (mv_vec3){ a.x + b.x, a.y + b.y, a.z + b.z }; }
static mv_vec3 v_sub(mv_vec3 a, mv_vec3 b) { return (mv_vec3){ a.x - b.x, a.y - b.y, a.z - b.z }; }
static mv_vec3 v_scale(mv_vec3 a, float k) { return (mv_vec3){ a.x * k, a.y * k, a.z * k }; }
static float v_dot(mv_vec3 a, mv_vec3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
static mv_vec3 v_cross(mv_vec3 a, mv_vec3 b) {
    return (mv_vec3){ a.y*b.z - a.z*b.y, a.z*b.x - a.x*b.z, a.x*b.y - a.y*b.x };
}
static float v_len(mv_vec3 a) { return sqrtf(v_dot(a, a)); }
static mv_vec3 v_unit(mv_vec3 a) { float n = v_len(a); return n > 1e-9f ? v_scale(a, 1.0f / n) : a; }

// The shortest rotation taking direction a onto direction b.
static mv_quat q_from_to(mv_vec3 a, mv_vec3 b) {
    a = v_unit(a); b = v_unit(b);
    float d = v_dot(a, b);
    if (d < -0.99999f) {                 // opposite: half a turn about any perpendicular
        mv_vec3 ax = v_cross(a, (mv_vec3){ 1, 0, 0 });
        if (v_len(ax) < 1e-3f) ax = v_cross(a, (mv_vec3){ 0, 1, 0 });
        ax = v_unit(ax);
        return (mv_quat){ ax.x, ax.y, ax.z, 0 };
    }
    mv_vec3 c = v_cross(a, b);
    return q_norm((mv_quat){ c.x, c.y, c.z, 1 + d });
}

// The rotation whose matrix has these orthonormal columns.
static mv_quat q_from_basis(mv_vec3 x, mv_vec3 y, mv_vec3 z) {
    float t = x.x + y.y + z.z;
    mv_quat q;
    if (t > 0) {
        float s = sqrtf(t + 1) * 2;
        q = (mv_quat){ (y.z - z.y) / s, (z.x - x.z) / s, (x.y - y.x) / s, s / 4 };
    } else if (x.x > y.y && x.x > z.z) {
        float s = sqrtf(1 + x.x - y.y - z.z) * 2;
        q = (mv_quat){ s / 4, (y.x + x.y) / s, (z.x + x.z) / s, (y.z - z.y) / s };
    } else if (y.y > z.z) {
        float s = sqrtf(1 + y.y - x.x - z.z) * 2;
        q = (mv_quat){ (y.x + x.y) / s, s / 4, (z.y + y.z) / s, (z.x - x.z) / s };
    } else {
        float s = sqrtf(1 + z.z - x.x - y.y) * 2;
        q = (mv_quat){ (z.x + x.z) / s, (z.y + y.z) / s, s / 4, (x.y - y.x) / s };
    }
    return q_norm(q);
}

// A hand's frame from its knuckles: x from the wrist towards the index, middle
// and ring knuckles, z from the index knuckle across to the ring knuckle, y
// their cross. Built the same way for Meta's bind hand and the measured one,
// the two frames name the same physical directions whatever each source's axes.
static mv_quat hand_frame(const mv_vec3 *p) {
    mv_vec3 k = v_scale(v_add(v_add(p[B_INDEX1], p[B_MIDDLE1]), p[B_RING1]), 1.0f / 3);
    mv_vec3 x = v_unit(v_sub(k, p[B_WRIST]));
    mv_vec3 l = v_sub(p[B_RING1], p[B_INDEX1]);
    mv_vec3 z = v_unit(v_sub(l, v_scale(x, v_dot(l, x))));
    return q_from_basis(x, v_cross(z, x), z);
}
static float hand_size(const mv_vec3 *p) {
    return v_len(v_sub(p[B_INDEX1], p[B_WRIST])) + v_len(v_sub(p[B_MIDDLE1], p[B_WRIST]))
         + v_len(v_sub(p[B_RING1], p[B_WRIST]));
}

// Meta's bind offsets for one hand.
static mv_vec3 bind_p(int hand, int i) { return hand ? v_scale(k_bind[i].p, -1) : k_bind[i].p; }

// The bind skeleton laid out in the wrist's frame: each bone's rotation (g)
// and position (at).
static void bind_world(int hand, mv_quat *g, mv_vec3 *at) {
    g[0] = k_bind[0].o; at[0] = (mv_vec3){ 0, 0, 0 };
    for (int i = 1; i < MV_HAND_BONES; i++) {
        int p = k_parent[i];
        at[i] = v_add(at[p], q_rot(g[p], bind_p(hand, i)));
        g[i] = q_norm(q_mul(g[p], k_bind[i].o));
    }
}

// Bones b -> a -> t (the last two of a finger): bend b and aim a so the tip t
// lands on target, keeping the bend in the plane the finger is already in.
static void reach(int hand, int t, mv_vec3 target, mv_quat *g, mv_vec3 *at) {
    int a = k_parent[t], b = k_parent[a];
    float l1 = v_len(bind_p(hand, a)), l2 = v_len(bind_p(hand, t));
    mv_vec3 d = v_sub(target, at[b]);
    float dl = v_len(d);
    if (dl < 1e-6f || l1 < 1e-6f || l2 < 1e-6f) return;
    float lo = fabsf(l1 - l2) + 1e-5f, hi = l1 + l2 - 1e-5f;
    float dc = dl < lo ? lo : dl > hi ? hi : dl;
    float ca = (l1*l1 + dc*dc - l2*l2) / (2 * l1 * dc);
    ca = ca > 1 ? 1 : ca < -1 ? -1 : ca;
    mv_vec3 dh = v_scale(d, 1.0f / dl), cur = v_sub(at[a], at[b]);
    mv_vec3 u = v_sub(cur, v_scale(dh, v_dot(cur, dh)));        // the side the knuckle bends to
    if (v_len(u) < 1e-6f) u = v_cross(dh, q_rot(g[b], (mv_vec3){ 0, 0, 1 }));
    u = v_unit(u);
    mv_vec3 want = v_add(v_scale(dh, ca), v_scale(u, sqrtf(1 - ca*ca)));
    mv_quat gb = q_norm(q_mul(q_from_to(q_rot(g[b], bind_p(hand, a)), want), g[b]));
    mv_quat ga = q_norm(q_mul(gb, q_mul(q_conj(g[b]), g[a])));  // a keeps its turn on b
    g[b] = gb;
    at[a] = v_add(at[b], q_rot(gb, bind_p(hand, a)));
    g[a] = q_norm(q_mul(q_from_to(q_rot(ga, bind_p(hand, t)), v_sub(target, at[a])), ga));
    at[t] = v_add(at[a], q_rot(g[a], bind_p(hand, t)));
    g[t] = q_norm(q_mul(g[a], k_bind[t].o));
}

// Retarget one measured hand onto Meta's skeleton (see the top of the file).
// m: bone positions in the hand anchor's frame; anchor: that frame in tracking
// space. Writes Meta's root pose, per-bone local rotations and the hand scale.
static void mv_hands_solve(int hand, const mv_vec3 *m, mv_pose anchor,
                           mv_pose *root, mv_quat *rot, float *scale) {
    mv_quat bg[MV_HAND_BONES];
    mv_vec3 bat[MV_HAND_BONES];
    bind_world(hand, bg, bat);

    // Measured frame -> Meta's wrist frame, and Meta's size over the user's.
    mv_quat fm = hand_frame(m), fb = hand_frame(bat);
    mv_quat turn = q_norm(q_mul(fb, q_conj(fm)));   // a measured direction, in Meta's frame
    float sm = hand_size(m), sb = hand_size(bat);
    float s = sb > 1e-6f && sm > 1e-6f ? sm / sb : 1;
    if (s < 0.5f || s > 2.0f) s = 1;                // a nonsense measurement: keep Meta's size
    mv_vec3 target[MV_HAND_BONES];
    for (int i = 0; i < MV_HAND_BONES; i++)
        target[i] = v_scale(q_rot(turn, v_sub(m[i], m[B_WRIST])), 1.0f / s);

    // Root to tip: carry the parent's turn, then swing onto the measured child.
    mv_quat g[MV_HAND_BONES];
    mv_vec3 at[MV_HAND_BONES];
    g[0] = k_bind[0].o; at[0] = (mv_vec3){ 0, 0, 0 };
    for (int i = 1; i < MV_HAND_BONES; i++) {
        int p = k_parent[i], c = k_child[i];
        at[i] = v_add(at[p], q_rot(g[p], bind_p(hand, i)));
        g[i] = q_norm(q_mul(g[p], k_bind[i].o));
        if (c >= 0) {
            mv_vec3 want = v_sub(target[c], at[i]);
            if (v_len(want) > 1e-6f)
                g[i] = q_norm(q_mul(q_from_to(q_rot(g[i], bind_p(hand, c)), want), g[i]));
        }
    }
    // Bone lengths differ from the user's, so the swings alone leave each tip
    // short of or past its mark: close the last two joints onto it.
    for (int t = B_TIP0; t < MV_HAND_BONES; t++) reach(hand, t, target[t], g, at);

    rot[0] = k_bind[0].o;
    for (int i = 1; i < MV_HAND_BONES; i++) rot[i] = q_norm(q_mul(q_conj(g[k_parent[i]]), g[i]));
    root->o = q_norm(q_mul(anchor.o, q_conj(turn)));
    root->p = v_add(anchor.p, q_rot(anchor.o, m[B_WRIST]));
    *scale = s;
}

void mv_hands_set_enabled(int on) {
    pthread_mutex_lock(&g_lock);
    g_enabled = on;
    pthread_mutex_unlock(&g_lock);
}

// Whether the headset sees this hand now (and hand tracking is on): what the
// OVRPlugin controller state reports as a connected hand for a hands-only title.
int mv_hands_tracked(int hand) {
    if (hand < 0 || hand > 1) return 0;
    pthread_mutex_lock(&g_lock);
    int t = g_enabled && g_hand[hand].tracked;
    pthread_mutex_unlock(&g_lock);
    return t;
}

void mv_hands_publish(int hand, int tracked, const float *model, const float *root,
                      const float *pointer, const float *pinch, double time_s) {
    if (hand < 0 || hand > 1) return;
    mv_pose r = { { 0, 0, 0, 1 }, { 0, 0, 0 } };
    mv_quat rot[MV_HAND_BONES];
    float scale = 1;
    tracked = tracked && model && root;
    if (tracked) {           // solved outside the lock: the readers are other threads
        mv_vec3 m[MV_HAND_BONES];
        for (int i = 0; i < MV_HAND_BONES; i++)
            m[i] = (mv_vec3){ model[7*i + 4], model[7*i + 5], model[7*i + 6] };
        // MV_HAND_SOLVE=0: no retargeting, the bones at rest on the visionOS
        // wrist — to tell a solver problem from a title's own.
        static int solve = -1;
        if (solve < 0) { const char *e = getenv("MV_HAND_SOLVE"); solve = !(e && *e == '0'); }
        if (solve) mv_hands_solve(hand, m, pose_from(root), &r, rot, &scale);
        else {
            r = pose_from(root);
            for (int i = 0; i < MV_HAND_BONES; i++) rot[i] = (mv_quat){ 0, 0, 0, 1 };
        }
    }
    pthread_mutex_lock(&g_lock);
    g_hand[hand].tracked = tracked;
    g_hand[hand].time = time_s;
    if (tracked) {
        g_hand[hand].root = r;
        memcpy(g_hand[hand].rot, rot, sizeof rot);
        g_hand[hand].scale = scale;
        g_hand[hand].pointer = pointer ? pose_from(pointer) : pose_from(root);
        for (int i = 0; i < 5; i++) g_hand[hand].pinch[i] = pinch ? pinch[i] : 0;
        if (!g_hand[hand].seen) {
            g_hand[hand].seen = 1;
            fprintf(stderr, "  [mv-hands] %s hand seen: retargeted onto Meta's skeleton "
                            "(scale %.2f), hand tracking live\n", hand ? "right" : "left", scale);
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

// Meta's bind skeleton, whenever hand tracking is on: it is a constant, so
// unlike the measured skeleton this used to answer there is nothing to wait for.
static int32_t fill_skeleton(int type, int32_t *head, ovrp_bone *bones, int max_bones) {
    if (type < 0 || type > 1 || !head) return OVRP_FAIL_INVALID_PARAM;
    pthread_mutex_lock(&g_lock);
    int on = g_enabled;
    pthread_mutex_unlock(&g_lock);
    if (!on) return OVRP_FAILURE;
    head[0] = type;
    head[1] = MV_HAND_BONES;
    head[2] = 0;                     // no capsules: physics hands are opt-in
    for (int i = 0; i < max_bones; i++) {
        bones[i] = (ovrp_bone){ .id = i < MV_HAND_BONES ? i : -1, .parent = -1,
                                .pose = { { 0, 0, 0, 1 }, { 0, 0, 0 } } };
        if (i < MV_HAND_BONES) {
            bones[i].parent = k_parent[i];
            bones[i].pose = (mv_pose){ k_bind[i].o, bind_p(type, i) };
        }
    }
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
    static int said;
    if (!said++) fprintf(stderr, "  [mv-hands] the title reads hand state: it uses hand tracking\n");
    memset(out, 0, sizeof *out);
    out->root.o.w = out->pointer.o.w = 1;
    for (int i = 0; i < MV_HAND_BONES; i++) out->rot[i] = k_bind[i].o;
    out->scale = 1;
    pthread_mutex_lock(&g_lock);
    if (g_enabled && g_hand[hand].tracked) {
        out->status = ST_TRACKED | ST_VALID | (hand == 1 ? ST_DOMINANT : 0);
        out->root = g_hand[hand].root;
        memcpy(out->rot, g_hand[hand].rot, sizeof out->rot);
        out->scale = g_hand[hand].scale;
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

// ovrp_GetMesh(MeshType, ovrpMesh *): OVRPlugin's MeshInternal, fixed arrays of
// 3000 vertices and 18000 indices. The offsets are the real plugin's own: its
// GetMesh memsets 0x31cec bytes and writes positions at +0xc, indices at
// +0x8cac, normals at +0x1194c, UV0 at +0x1a5ec, blend indices at +0x203ac and
// blend weights at +0x2616c.
#define MESH_MAX_V 3000
#define MESH_MAX_I 18000
typedef struct { float x, y; } mv_vec2;
typedef struct { int16_t x, y, z, w; } mv_vec4s;
typedef struct { float x, y, z, w; } mv_vec4f;
typedef struct {
    int32_t type;
    uint32_t num_vertices, num_indices;
    mv_vec3 pos[MESH_MAX_V];
    int16_t idx[MESH_MAX_I];
    mv_vec3 nrm[MESH_MAX_V];
    mv_vec2 uv[MESH_MAX_V];
    mv_vec4s bone[MESH_MAX_V];
    mv_vec4f weight[MESH_MAX_V];
} ovrp_mesh;
_Static_assert(offsetof(ovrp_mesh, pos) == 0xc, "Mesh.VertexPositions");
_Static_assert(offsetof(ovrp_mesh, idx) == 0x8cac, "Mesh.Indices");
_Static_assert(offsetof(ovrp_mesh, nrm) == 0x1194c, "Mesh.VertexNormals");
_Static_assert(offsetof(ovrp_mesh, uv) == 0x1a5ec, "Mesh.VertexUV0");
_Static_assert(offsetof(ovrp_mesh, bone) == 0x203ac, "Mesh.BlendIndices");
_Static_assert(offsetof(ovrp_mesh, weight) == 0x2616c, "Mesh.BlendWeights");
_Static_assert(sizeof(ovrp_mesh) == 0x31cec, "MeshInternal");

#define TUBE_SIDES 8

// Built on the bind skeleton GetSkeleton2/3 answer, bone for bone, in its
// wrist frame (Meta's mesh space). Refused, like the skeleton, while hand
// tracking is off.
static int32_t mv_GetMesh(int32_t type, ovrp_mesh *out) {
    if (!out) return OVRP_FAIL_INVALID_PARAM;
    if (type != 0 && type != 1) return OVRP_FAILURE;   // HandLeft / HandRight only, as the skeleton
    pthread_mutex_lock(&g_lock);
    int on = g_enabled;
    pthread_mutex_unlock(&g_lock);
    if (!on) return OVRP_FAILURE;
    mv_quat g[MV_HAND_BONES];
    mv_vec3 at[MV_HAND_BONES];                         // each bone's bind origin, wrist frame
    bind_world(type, g, at);

    memset(out, 0, sizeof *out);
    out->type = type;
    uint32_t nv = 0, ni = 0;
    for (int i = 2; i < MV_HAND_BONES; i++) {          // every bone but the wrist and forearm stub
        int p = k_parent[i];
        mv_vec3 a = at[p], b = at[i], axis = v_sub(b, a);
        float len = v_len(axis);
        if (len < 1e-4f) continue;
        axis = v_scale(axis, 1.0f / len);
        mv_vec3 ref = fabsf(axis.y) < 0.9f ? (mv_vec3){ 0, 1, 0 } : (mv_vec3){ 1, 0, 0 };
        mv_vec3 u = v_cross(axis, ref);
        u = v_scale(u, 1.0f / v_len(u));
        mv_vec3 v = v_cross(axis, u);
        float r = p == 0 ? 0.011f : 0.008f;            // metres: palm rays a little wider
        uint32_t base = nv;
        for (int ring = 0; ring < 2; ring++)
            for (int k = 0; k < TUBE_SIDES; k++) {
                float t = 6.2831853f * (float)k / TUBE_SIDES;
                mv_vec3 n = v_add(v_scale(u, cosf(t)), v_scale(v, sinf(t)));
                out->pos[nv] = v_add(ring ? b : a, v_scale(n, r));
                out->nrm[nv] = n;
                out->uv[nv] = (mv_vec2){ (float)k / TUBE_SIDES, (float)ring };
                out->bone[nv] = (mv_vec4s){ (int16_t)p, 0, 0, 0 };   // rides its parent bone
                out->weight[nv] = (mv_vec4f){ 1, 0, 0, 0 };
                nv++;
            }
        for (int k = 0; k < TUBE_SIDES; k++) {         // outward, counter-clockwise (right-handed)
            int16_t a0 = (int16_t)(base + k), a1 = (int16_t)(base + (k + 1) % TUBE_SIDES);
            int16_t b0 = (int16_t)(a0 + TUBE_SIDES), b1 = (int16_t)(a1 + TUBE_SIDES);
            int16_t q[6] = { a0, a1, b1, a0, b1, b0 };
            for (int j = 0; j < 6; j++) out->idx[ni++] = q[j];
        }
    }
    out->num_vertices = nv;
    out->num_indices = ni;
    static int said[2];
    if (!said[type]++)
        fprintf(stderr, "  [mv-hands] %s hand mesh: %u vertices, %u indices, skinned to Meta's "
                        "bind skeleton\n", type ? "right" : "left", nv, ni);
    return OVRP_SUCCESS;
}

void *mv_hands_ovrp(const char *name) {
    static const struct { const char *name; void *fn; } k[] = {
        { "ovrp_GetHandTrackingEnabled", (void *)mv_GetHandTrackingEnabled },
        { "ovrp_GetSkeleton2",           (void *)mv_GetSkeleton2 },
        { "ovrp_GetSkeleton3",           (void *)mv_GetSkeleton3 },
        { "ovrp_GetHandState",           (void *)mv_GetHandState },
        { "ovrp_GetMesh",                (void *)mv_GetMesh },
    };
    for (size_t i = 0; name && i < sizeof k / sizeof k[0]; i++)
        if (strcmp(name, k[i].name) == 0) return k[i].fn;
    return NULL;
}
