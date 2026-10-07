/* Pose and matrix conversion.
 *
 * The convention is the whole content of this file. ovrMatrix4f is row-major,
 * as VrApi documents it; simd_float4x4 is column-major, as Metal and ARKit use
 * it. Passing one for the other transposes every rotation, and a transposed
 * rotation does not fail — the world turns the wrong way, which reads as a
 * tracking bug rather than a marshalling one.
 *
 * Pure maths, so the convention is pinned by round-trip tests instead of by a
 * comment that a later edit can quietly falsify. */
#include "kl_vrapi.h"

#include <math.h>

void kl_matrix_transpose(const ovrMatrix4f *in, ovrMatrix4f *out)
{
    for (int r = 0; r < 4; r++)
        for (int c = 0; c < 4; c++)
            out->M[r][c] = in->M[c][r];
}

/* Shepperd's method: pick the branch whose denominator is largest, because the
 * naive trace-only form loses precision and then divides by nearly zero at
 * rotations near 180 degrees — exactly where a user turning around puts it. */
void kl_quat_from_matrix(const ovrMatrix4f *m, ovrVector4f *out)
{
    const float m00 = m->M[0][0], m01 = m->M[0][1], m02 = m->M[0][2];
    const float m10 = m->M[1][0], m11 = m->M[1][1], m12 = m->M[1][2];
    const float m20 = m->M[2][0], m21 = m->M[2][1], m22 = m->M[2][2];
    const float trace = m00 + m11 + m22;

    if (trace > 0.0f) {
        float s = sqrtf(trace + 1.0f) * 2.0f;
        out->w = 0.25f * s;
        out->x = (m21 - m12) / s;
        out->y = (m02 - m20) / s;
        out->z = (m10 - m01) / s;
    } else if (m00 > m11 && m00 > m22) {
        float s = sqrtf(1.0f + m00 - m11 - m22) * 2.0f;
        out->w = (m21 - m12) / s;
        out->x = 0.25f * s;
        out->y = (m01 + m10) / s;
        out->z = (m02 + m20) / s;
    } else if (m11 > m22) {
        float s = sqrtf(1.0f + m11 - m00 - m22) * 2.0f;
        out->w = (m02 - m20) / s;
        out->x = (m01 + m10) / s;
        out->y = 0.25f * s;
        out->z = (m12 + m21) / s;
    } else {
        float s = sqrtf(1.0f + m22 - m00 - m11) * 2.0f;
        out->w = (m10 - m01) / s;
        out->x = (m02 + m20) / s;
        out->y = (m12 + m21) / s;
        out->z = 0.25f * s;
    }
}

void kl_matrix_from_quat(const ovrVector4f *q, ovrMatrix4f *out)
{
    const float x = q->x, y = q->y, z = q->z, w = q->w;
    const float xx = x*x, yy = y*y, zz = z*z;
    const float xy = x*y, xz = x*z, yz = y*z;
    const float wx = w*x, wy = w*y, wz = w*z;

    out->M[0][0] = 1.0f - 2.0f*(yy + zz);
    out->M[0][1] =        2.0f*(xy - wz);
    out->M[0][2] =        2.0f*(xz + wy);
    out->M[0][3] = 0.0f;

    out->M[1][0] =        2.0f*(xy + wz);
    out->M[1][1] = 1.0f - 2.0f*(xx + zz);
    out->M[1][2] =        2.0f*(yz - wx);
    out->M[1][3] = 0.0f;

    out->M[2][0] =        2.0f*(xz - wy);
    out->M[2][1] =        2.0f*(yz + wx);
    out->M[2][2] = 1.0f - 2.0f*(xx + yy);
    out->M[2][3] = 0.0f;

    out->M[3][0] = out->M[3][1] = out->M[3][2] = 0.0f;
    out->M[3][3] = 1.0f;
}

double kl_vrapi_predicted_display_time(double now, int64_t frame_index,
                                       int64_t current_frame, float refresh_hz)
{
    if (refresh_hz <= 0.0f) refresh_hz = 90.0f;

    /* One frame of pipeline latency, matching what VrApi predicts on Quest.
     * Titles differentiate successive calls to pace animation, so the slope
     * matters more than the offset: a wrong rate is slow motion, not an error. */
    const int64_t ahead = frame_index - current_frame + 1;
    return now + (double)ahead / (double)refresh_hz;
}
