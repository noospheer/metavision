// Meta hand tracking (OVRPlugin's hand calls) fed from visionOS hand tracking.
#pragma once
#include <stdint.h>

#define MV_HAND_BONES 24     // OVRPlugin BoneId Hand_Start .. Hand_End

// One hand, once per frame, from the app's hand-tracking loop.
//   model   MV_HAND_BONES x {qx,qy,qz,qw, px,py,pz}: each OVR hand bone in the
//           wrist's frame (index order is OVRPlugin's BoneId). Only the
//           positions are used: they are retargeted onto Meta's skeleton,
//           whose bone frames are not ARKit's (see mv_hands.c)
//   root    {qx,qy,qz,qw, px,py,pz}: the wrist in tracking space
//   pointer {qx,qy,qz,qw, px,py,pz}: the pointing ray in tracking space, -Z forward
//   pinch   5 strengths 0..1, thumb..pinky
// tracked = 0 publishes "not tracked" (the other pointers may be NULL).
void mv_hands_publish(int hand, int tracked, const float *model, const float *root,
                      const float *pointer, const float *pinch, double time_s);

// Whether titles are told hand tracking is on (off in hands-free mode, where
// tracked hands are deliberately ignored).
void mv_hands_set_enabled(int on);
int  mv_hands_tracked(int hand);   // 0 left, 1 right

// The OVRPlugin entry point for `name` when this file answers it, else NULL.
void *mv_hands_ovrp(const char *name);

// OpenXR hand tracking (XR_EXT_hand_tracking, XR_FB_hand_tracking_aim), from
// the same frames. The runtime's OpenXR side reads these. They are not
// retargeted: OpenXR describes the measured hand joint by joint.
#define MV_XR_JOINTS 26      // XrHandJointEXT: palm, wrist, thumb x4, four fingers x5

// One hand, once per frame, beside mv_hands_publish.
//   pos   MV_XR_JOINTS x {px,py,pz}: each joint in the hand anchor's frame, in
//         XrHandJointEXT order. The palm slot (0) is ignored: it is derived
//   root  {qx,qy,qz,qw, px,py,pz}: the hand anchor in tracking space
// tracked = 0 publishes "not tracked" (pos and root may be NULL).
void mv_hands_publish_xr(int hand, int tracked, const float *pos, const float *root,
                         double time_s);

// Everything one xrLocateHandJointsEXT needs, in tracking space. Poses are
// {qx,qy,qz,qw, px,py,pz} in OpenXR's joint convention: -Z from each joint
// towards the fingertip (+Z back along the bone), +Y out of the back of the
// hand (-Y the palm normal), X their right-handed complement.
typedef struct {
    float pose[MV_XR_JOINTS][7];
    float radius[MV_XR_JOINTS];
    float lin[MV_XR_JOINTS][3], ang[MV_XR_JOINTS][3];
    int   motion_valid;      // lin/ang are a measurement (two tracked samples)
    float aim[7];            // the pointing ray, -Z forward (as HandState's)
    float pinch[5];          // thumb..little, 0..1
    double time;
} mv_hands_xr;

// 1 and *out filled while the hand is tracked and hand tracking is on; 0
// otherwise (never seen, lost, or hands-free mode, which ignores hands).
int mv_hands_xr_read(int hand, mv_hands_xr *out);
