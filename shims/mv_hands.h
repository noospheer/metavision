// Meta hand tracking (OVRPlugin's hand calls) fed from visionOS hand tracking.
#pragma once
#include <stdint.h>

#define MV_HAND_BONES 24     // OVRPlugin BoneId Hand_Start .. Hand_End

// One hand, once per frame, from the app's hand-tracking loop.
//   model   MV_HAND_BONES x {qx,qy,qz,qw, px,py,pz}: each OVR hand bone in the
//           wrist's frame (index order is OVRPlugin's BoneId)
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
