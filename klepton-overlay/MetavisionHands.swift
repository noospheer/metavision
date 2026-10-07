// Meta hand tracking for every title: the visionOS hand skeleton, mapped onto
// OVRPlugin's 24 hand bones and handed to shims/mv_hands.c, which answers the
// titles' ovrp_GetSkeleton2/3 and ovrp_GetHandState from it.
//
// Called once per frame from KleptonControllers.update (wired in by
// tools/metavision-overlay), with the same hand anchors the controller
// emulation reads, so hands and controllers always agree.
import ARKit
import QuartzCore
import simd

@_silgen_name("mv_hands_publish")
private func mv_hands_publish(_ hand: Int32, _ tracked: Int32,
                              _ model: UnsafePointer<Float>?, _ root: UnsafePointer<Float>?,
                              _ pointer: UnsafePointer<Float>?, _ pinch: UnsafePointer<Float>?,
                              _ time: Double)
@_silgen_name("mv_hands_set_enabled")
private func mv_hands_set_enabled(_ on: Int32)

enum MetavisionHands {
    private typealias J = HandSkeleton.JointName

    /// OVRPlugin BoneId -> ARKit joint. nil entries are synthesised.
    private static let joints: [J?] = [
        .wrist, .forearmWrist,
        nil, .thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip,          // Thumb0..3
        .indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip,
        .middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip,
        .ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip,
        .littleFingerMetacarpal, .littleFingerKnuckle, .littleFingerIntermediateBase,
        .littleFingerIntermediateTip,
        .thumbTip, .indexFingerTip, .middleFingerTip, .ringFingerTip, .littleFingerTip,
    ]
    private static let tips: [J] = [.thumbTip, .indexFingerTip, .middleFingerTip,
                                    .ringFingerTip, .littleFingerTip]

    static func publish(left: HandAnchor?, right: HandAnchor?) {
        let on = !MetavisionHandsFree.shared.ignoresHands
        mv_hands_set_enabled(on ? 1 : 0)
        let t = CACurrentMediaTime()
        for (hand, anchor) in [(0, left), (1, right)] {
            guard on, let a = anchor, a.isTracked, let sk = a.handSkeleton else {
                mv_hands_publish(Int32(hand), 0, nil, nil, nil, nil, t)
                continue
            }
            var model = [Float](); model.reserveCapacity(24 * 7)
            for j in joints {
                let m: simd_float4x4
                if let j {
                    m = sk.joint(j).anchorFromJointTransform
                } else {
                    // Thumb0 (the base of the thumb) has no ARKit joint: on the
                    // line from the wrist to the thumb knuckle, turned like it.
                    var k = sk.joint(.thumbKnuckle).anchorFromJointTransform
                    let w = sk.joint(.wrist).anchorFromJointTransform.columns.3
                    k.columns.3 = simd_mix(w, k.columns.3, SIMD4<Float>(repeating: 0.4))
                    m = k
                }
                append(&model, m)
            }
            var root = [Float](); append(&root, a.originFromAnchorTransform)

            // Pinch strength per finger: thumb tip to finger tip, 1.5 cm = full.
            let thumb = position(sk.joint(.thumbTip).anchorFromJointTransform)
            var pinch = [Float](repeating: 0, count: 5)
            for f in 1..<5 {
                let d = simd_distance(thumb, position(sk.joint(tips[f]).anchorFromJointTransform))
                pinch[f] = min(1, max(0, (0.06 - d) / 0.045))
            }
            pinch[0] = pinch[1]

            var pointer = [Float](); append(&pointer, pointerPose(a, sk, hand: hand))
            model.withUnsafeBufferPointer { m in root.withUnsafeBufferPointer { r in
                pointer.withUnsafeBufferPointer { p in pinch.withUnsafeBufferPointer { s in
                    mv_hands_publish(Int32(hand), 1, m.baseAddress, r.baseAddress,
                                     p.baseAddress, s.baseAddress, t)
                }}
            }}
        }
    }

    /// Meta's pointer: a ray from the shoulder through the pinch point, -Z forward.
    private static func pointerPose(_ a: HandAnchor, _ sk: HandSkeleton, hand: Int) -> simd_float4x4 {
        let o = a.originFromAnchorTransform
        let k1 = o * sk.joint(.indexFingerKnuckle).anchorFromJointTransform.columns.3
        let k2 = o * sk.joint(.thumbKnuckle).anchorFromJointTransform.columns.3
        let origin = SIMD3<Float>((k1.x + k2.x) / 2, (k1.y + k2.y) / 2, (k1.z + k2.z) / 2)

        var px: Float = 0, py: Float = 1.6, pz: Float = 0
        var qx: Float = 0, qy: Float = 0, qz: Float = 0, qw: Float = 1
        kl_ovrp_get_head_pose(&px, &py, &pz, &qx, &qy, &qz, &qw)
        let hp = SIMD3<Float>(px, py, pz)
        var hq = simd_quatf(ix: qx, iy: qy, iz: qz, r: qw)
        if !hq.real.isFinite { hq = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        let right = hq.act(SIMD3<Float>(1, 0, 0))
        let shoulder = hp + SIMD3<Float>(0, -0.15, 0) + right * (hand == 1 ? 0.17 : -0.17)
        var f = origin - shoulder
        if simd_length(f) < 1e-3 { f = hq.act(SIMD3<Float>(0, 0, -1)) }
        f = simd_normalize(f)
        let z = -f
        var x = simd_cross(SIMD3<Float>(0, 1, 0), z)
        x = simd_length(x) < 1e-3 ? SIMD3<Float>(1, 0, 0) : simd_normalize(x)
        let y = simd_cross(z, x)
        return simd_float4x4(SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(origin, 1))
    }

    private static func position(_ m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// {qx,qy,qz,qw, px,py,pz}
    private static func append(_ out: inout [Float], _ m: simd_float4x4) {
        let q = simd_quatf(simd_float3x3(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                         SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                         SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
        out += [q.imag.x, q.imag.y, q.imag.z, q.real, m.columns.3.x, m.columns.3.y, m.columns.3.z]
    }
}
