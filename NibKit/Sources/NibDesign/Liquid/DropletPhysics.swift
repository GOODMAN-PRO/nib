import CoreGraphics
import Foundation

// MARK: - Springs

/// A damped spring on one value in SwiftUI's parameterisation, integrated with semi-implicit Euler in fixed
/// 1/240 s sub-steps (stable for every Nib spring, frame-rate independent at 60, 80 and 120 Hz).
struct SpringValue: Equatable, Sendable {
    var value: CGFloat
    var velocity: CGFloat = 0
    var target: CGFloat
    var epsilon: CGFloat

    init(_ value: CGFloat, epsilon: CGFloat = 0.02) {
        self.value = value
        self.target = value
        self.epsilon = epsilon
    }

    var isResting: Bool { abs(value - target) < epsilon && abs(velocity) < epsilon * 4 }

    mutating func snap(to newValue: CGFloat) {
        value = newValue
        target = newValue
        velocity = 0
    }

    mutating func step(_ dt: CGFloat, spring: NibSpring) {
        guard dt > 0 else { return }
        let k = CGFloat(spring.stiffness)
        let c = CGFloat(spring.damping)
        let n = max(1, Int((dt * 240).rounded(.up)))
        let h = dt / CGFloat(n)
        for _ in 0..<n {
            velocity += (-k * (value - target) - c * velocity) * h
            value += velocity * h
        }
        if isResting {
            value = target
            velocity = 0
        }
    }
}

struct SpringPoint: Equatable, Sendable {
    var x: SpringValue
    var y: SpringValue

    init(_ point: CGPoint, epsilon: CGFloat = 0.05) {
        x = SpringValue(point.x, epsilon: epsilon)
        y = SpringValue(point.y, epsilon: epsilon)
    }

    var value: CGPoint { CGPoint(x: x.value, y: y.value) }

    var velocity: CGVector {
        get { CGVector(dx: x.velocity, dy: y.velocity) }
        set {
            x.velocity = newValue.dx
            y.velocity = newValue.dy
        }
    }

    var target: CGPoint {
        get { CGPoint(x: x.target, y: y.target) }
        set {
            x.target = newValue.x
            y.target = newValue.y
        }
    }

    var isResting: Bool { x.isResting && y.isResting }

    mutating func snap(to point: CGPoint) {
        x.snap(to: point.x)
        y.snap(to: point.y)
    }

    mutating func step(_ dt: CGFloat, spring: NibSpring) {
        x.step(dt, spring: spring)
        y.step(dt, spring: spring)
    }
}

// MARK: - Necks

/// A neck: joins at `join` pt, starts `t0` thick, thins as t = t0·(1 − gap/off)^0.7 and breaks below the minimum neck.
struct NeckParams: Equatable, Sendable {
    var join: CGFloat
    var t0: CGFloat
    var off: CGFloat
}

enum BondEvent: Equatable, Sendable {
    case joined, split
}

/// Hysteresis between two droplets: water holds on longer than it takes to join.
struct Bond: Equatable, Sendable {
    private(set) var isJoined = false
    var thickness = SpringValue(0, epsilon: 0.05)

    /// Updates the bond for this frame's gap. With `hysteresis` off (system glass on iOS 26, which has no memory)
    /// joining and splitting both happen at `join`, so haptics stay in step with what the system draws.
    mutating func update(gap: CGFloat, params: NeckParams, minimumNeck: CGFloat, enabled: Bool,
                         hysteresis: Bool) -> BondEvent? {
        let t = DropletPhysics.neckThickness(gap: gap, params: params)
        var event: BondEvent?
        if !enabled {
            isJoined = false
        } else if !isJoined && gap < params.join {
            isJoined = true
            event = .joined
        } else if isJoined && (hysteresis ? t < minimumNeck : gap >= params.join) {
            isJoined = false
            event = .split
        }
        thickness.target = isJoined && hysteresis ? t : 0
        return event
    }
}

// MARK: - Droplet physics

enum DropletPhysics {
    static let pickupSlop: CGFloat = 6
    static let rubberDimension: CGFloat = 120
    static let projection: CGFloat = 0.12
    static let carefulReleaseStill: Double = 0.070
    static let maxReleaseSpeed: CGFloat = 5000
    static let maxSlotSpeed: CGFloat = 1200

    /// UIScrollView-style resistance past [lo, hi]: edge + D·(1 − 1/(0.55·e/D + 1)).
    static func rubberBand(_ v: CGFloat, lo: CGFloat, hi: CGFloat, dimension d: CGFloat = rubberDimension) -> CGFloat {
        guard hi >= lo else { return (lo + hi) / 2 }
        if v < lo { return lo - (1 - 1 / ((lo - v) * 0.55 / d + 1)) * d }
        if v > hi { return hi + (1 - 1 / ((v - hi) * 0.55 / d + 1)) * d }
        return v
    }

    /// A careful release never flings: if the finger rested ≥ 70 ms the velocity is zero. Capped at 5000 pt/s.
    static func releaseVelocity(_ v: CGVector, stillFor: Double) -> CGVector {
        if stillFor >= carefulReleaseStill { return .zero }
        let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        guard speed > maxReleaseSpeed else { return v }
        let k = maxReleaseSpeed / speed
        return CGVector(dx: v.dx * k, dy: v.dy * k)
    }

    /// The landing a fling projects to: p + v·0.12 s.
    static func projectedLanding(_ p: CGPoint, velocity v: CGVector) -> CGPoint {
        CGPoint(x: p.x + v.dx * projection, y: p.y + v.dy * projection)
    }

    /// Grid and slot snaps (DESIGN.md §10.3): only the part of the release velocity that points at the slot, capped
    /// at 1200 pt/s and at ω·distance. With the critically damped `slot` spring no axis can then cross its target, so
    /// the droplet lands without overshooting and never leaves the box between where it was and where it goes.
    /// `displacement` is the droplet's offset from the slot (the slot is at zero).
    static func slotVelocity(_ v: CGVector, displacement d: CGPoint, spring: NibSpring = NibMotion.slot) -> CGVector {
        let distance = (d.x * d.x + d.y * d.y).squareRoot()
        guard distance > 0.001 else { return .zero }
        let ux = -d.x / distance, uy = -d.y / distance
        let along = max(0, v.dx * ux + v.dy * uy)
        let omega = 2 * CGFloat.pi / CGFloat(spring.response)
        let speed = min(along, maxSlotSpeed, omega * distance)
        return CGVector(dx: ux * speed, dy: uy * speed)
    }

    /// s* = min(cap, |v| / vRef).
    static func stretchTarget(speed: CGFloat, cap: CGFloat, vRef: CGFloat) -> CGFloat {
        min(cap, speed / max(vRef, 1))
    }

    /// The rendered stretch: the spring aims at s*, but what is drawn never passes the cap (and dips at most
    /// 0.4·cap below zero), so a spring's overshoot never shows as a stretch past its cap (DESIGN.md §10.2).
    static func clampStretch(_ s: CGFloat, cap: CGFloat) -> CGFloat {
        min(max(s, -0.4 * cap), cap)
    }

    /// (−π/2, π/2]: a stretch looks the same forwards and backwards.
    static func wrapHalfTurn(_ a: CGFloat) -> CGFloat {
        a - .pi * (a / .pi).rounded()
    }

    /// θ follows its target exponentially, θ += Δ·(1 − e^(−18·dt)), so it never steps.
    static func followAxis(_ theta: CGFloat, toward target: CGFloat, dt: CGFloat) -> CGFloat {
        theta + wrapHalfTurn(target - theta) * (1 - exp(-18 * dt))
    }

    /// How much of the long-droplet regime applies: smoothstep(2.5, 3.5, aspect). Blended, never switched, so a
    /// palette re-forming through aspect 3 does not twist in one frame.
    static func longAxisWeight(aspect: CGFloat) -> CGFloat {
        let t = min(max((aspect - 2.5) / 1.0, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Fix 5: a long droplet deforms on its own axes only. The signed stretch is the tensor's component on the long
    /// axis: moving along it lengthens, moving across it shortens and thickens. No shear.
    static func axisLocked(stretch s: CGFloat, velocityAngle phi: CGFloat, longAxis: CGFloat) -> CGFloat {
        s * cos(2 * (phi - longAxis))
    }

    /// Volume-preserving in 3D (sx·sy·sz = 1 with the depth following the cross axis): along 1 + s, across 1/√(1 + s).
    /// Area preservation reads as rubber; this reads as a drop thinning as it stretches.
    static func deformation(stretch s: CGFloat, axis theta: CGFloat, lift: CGFloat = 1) -> CGAffineTransform {
        let along = (1 + s) * lift
        let across = lift / (1 + s).squareRoot()
        let c = cos(theta), n = sin(theta)
        let a = c * c * along + n * n * across
        let b = c * n * (along - across)
        let d = n * n * along + c * c * across
        return CGAffineTransform(a: a, b: b, c: b, d: d, tx: 0, ty: 0)
    }

    /// Fix 6: the droplet transform about the grab point `anchor` (both in coordinates centred on the rest centre),
    /// so the part under the finger stays under the finger: p' = offset + anchor + L·(q − anchor).
    static func transform(offset: CGPoint, anchor: CGPoint, linear: CGAffineTransform) -> CGAffineTransform {
        let la = CGPoint(x: linear.a * anchor.x + linear.c * anchor.y, y: linear.b * anchor.x + linear.d * anchor.y)
        return CGAffineTransform(a: linear.a, b: linear.b, c: linear.c, d: linear.d,
                                 tx: offset.x + anchor.x - la.x, ty: offset.y + anchor.y - la.y)
    }

    /// Converts a centred transform to SwiftUI's `transformEffect` space (origin at the view's top-left).
    static func aboutCentre(_ t: CGAffineTransform, size: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
            .concatenating(t)
            .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))
    }

    static func neckThickness(gap: CGFloat, params: NeckParams) -> CGFloat {
        params.t0 * pow(max(0, 1 - gap / params.off), 0.7)
    }

    /// Polynomial smooth-min: the union the Metal field and system glass approximate (k = merge distance).
    static func smoothMin(_ d1: CGFloat, _ d2: CGFloat, k: CGFloat) -> CGFloat {
        let h = min(max(0.5 + 0.5 * (d2 - d1) / k, 0), 1)
        return d2 + (d1 - d2) * h - k * h * (1 - h)
    }

    /// Nearest points and gap between two droplet boxes. Corner-to-corner gaps grow by 0.59·r (rounded corners).
    static func gap(_ a: CGRect, _ b: CGRect, minCorner: CGFloat) -> (gap: CGFloat, pointA: CGPoint, pointB: CGPoint) {
        let ax: CGFloat, bx: CGFloat, ay: CGFloat, by: CGFloat
        if a.maxX < b.minX {
            ax = a.maxX; bx = b.minX
        } else if b.maxX < a.minX {
            ax = a.minX; bx = b.maxX
        } else {
            ax = (max(a.minX, b.minX) + min(a.maxX, b.maxX)) / 2; bx = ax
        }
        if a.maxY < b.minY {
            ay = a.maxY; by = b.minY
        } else if b.maxY < a.minY {
            ay = a.minY; by = b.maxY
        } else {
            ay = (max(a.minY, b.minY) + min(a.maxY, b.maxY)) / 2; by = ay
        }
        var g = ((bx - ax) * (bx - ax) + (by - ay) * (by - ay)).squareRoot()
        if ax != bx && ay != by { g += minCorner * 0.59 }
        return (g, CGPoint(x: ax, y: ay), CGPoint(x: bx, y: by))
    }

    /// The axis a docked droplet may slide along when it fuses (its dock fixes the other one).
    enum ContactAxis: Sendable {
        case horizontal, vertical
    }

    /// B's fuse (with fix 7): after a release within the merge distance, slide `moving` along the contact axis until the
    /// edges overlap by 1 pt, and (when free to) align centres within 24 pt. With ≥ 4.5 pt content inset at each end the
    /// glyph boxes then stay ≥ 8 pt apart.
    static func fuse(_ moving: CGRect, onto fixed: CGRect, along axis: ContactAxis? = nil) -> CGRect {
        var r = moving
        let gapX = max(fixed.minX - moving.maxX, moving.minX - fixed.maxX)
        let gapY = max(fixed.minY - moving.maxY, moving.minY - fixed.maxY)
        let horizontal = axis.map { $0 == .horizontal } ?? (gapX >= gapY)
        if horizontal {
            r.origin.x = moving.midX < fixed.midX ? fixed.minX + 1 - moving.width : fixed.maxX - 1
            if axis == nil && abs(moving.midY - fixed.midY) <= 24 { r.origin.y = fixed.midY - moving.height / 2 }
        } else {
            r.origin.y = moving.midY < fixed.midY ? fixed.minY + 1 - moving.height : fixed.maxY - 1
            if axis == nil && abs(moving.midX - fixed.midX) <= 24 { r.origin.x = fixed.midX - moving.width / 2 }
        }
        return r
    }

    /// Where a docking droplet may come to rest next to a neighbour: fused if within `mergeDistance`, pushed out to
    /// 16 pt if in the banned 12–15 pt band, otherwise unchanged. A docked droplet (`axis` set) only slides along its
    /// dock, and only neighbours beside it on that axis count.
    static func restingRect(_ moving: CGRect, near fixed: CGRect, mergeDistance: CGFloat,
                            along axis: ContactAxis? = nil) -> CGRect {
        if let axis {
            let across = axis == .horizontal
                ? (moving.minY < fixed.maxY && fixed.minY < moving.maxY)
                : (moving.minX < fixed.maxX && fixed.minX < moving.maxX)
            guard across else { return moving }
        }
        let g = gap(moving, fixed, minCorner: 0).gap
        if g < mergeDistance { return fuse(moving, onto: fixed, along: axis) }
        guard g < 16 else { return moving }
        var r = moving
        let push = 16 - g
        let gapX = max(fixed.minX - moving.maxX, moving.minX - fixed.maxX)
        let gapY = max(fixed.minY - moving.maxY, moving.minY - fixed.maxY)
        let horizontal = axis.map { $0 == .horizontal } ?? (gapX >= gapY)
        if horizontal {
            r.origin.x += moving.midX < fixed.midX ? -push : push
        } else {
            r.origin.y += moving.midY < fixed.midY ? -push : push
        }
        return r
    }

    /// Fix 2: while the palette re-forms, content cross-fades over progress 0.42–0.58 and is invisible at the
    /// midpoint, where the layout switches axis. The toolbar is dark for under 100 ms.
    static func reshapeContentOpacity(progress p: CGFloat) -> CGFloat {
        if p <= 0.42 || p >= 0.58 { return 1 }
        return abs(p - 0.5) / 0.08
    }
}

// MARK: - Selection bead

struct BeadGeometry: Equatable, Sendable {
    var head: CGFloat
    var tail: CGFloat
    var headRadius: CGFloat
    var tailRadius: CGFloat
    var neckWidth: CGFloat
}

enum BeadPhysics {
    static let tailRatio: CGFloat = 0.78
    /// Fix 1 (from C), tightened: the tail never falls more than 1.0·r behind the head, so the bead never splits and
    /// the teardrop shows only on jumps longer than three tools.
    static let maxSeparation: CGFloat = 1.0
    /// Fix 1: the neck's half-width never drops below 0.72 of the smaller radius.
    static let minNeckHalfWidth: CGFloat = 0.72

    static func clampTail(head: CGFloat, tail: CGFloat, radius: CGFloat) -> CGFloat {
        let m = maxSeparation * radius
        return min(max(tail, head - m), head + m)
    }

    static func geometry(head: CGFloat, tail: CGFloat, radius r: CGFloat) -> BeadGeometry {
        let t = clampTail(head: head, tail: tail, radius: r)
        let rt = r * tailRatio
        let separation = abs(head - t)
        let neck = max(2 * minNeckHalfWidth * rt, 1.2 * r * (1 - separation / 150))
        return BeadGeometry(head: head, tail: t, headRadius: r, tailRadius: rt, neckWidth: neck)
    }

    /// Passing lens: icons within 30 pt of the head magnify up to 1.13×.
    static func passingLens(distance d: CGFloat) -> CGFloat {
        1 + 0.13 * max(0, 1 - d / 30)
    }
}

// MARK: - One droplet's dynamics

/// Position, size, corner, stretch (surface tension), lift and grab anchor of one droplet.
struct DropletDynamics: Equatable, Sendable {
    var offset = SpringPoint(.zero)
    var size = SpringPoint(.zero)
    var corner = SpringValue(0, epsilon: 0.05)
    var stretch = SpringValue(0, epsilon: 0.0004)
    var axis: CGFloat = 0
    var lift = SpringValue(1, epsilon: 0.0004)
    var anchor = SpringPoint(.zero)
    var positionSpring = NibMotion.snap
    var sizeSpring = NibMotion.budSize

    /// The rendered stretch for this droplet's (Calm-halved) cap.
    func renderStretch(cap: CGFloat) -> CGFloat { DropletPhysics.clampStretch(stretch.value, cap: cap) }

    /// Advances one frame and returns true while anything moves. Under `reduceMotion` the shape jumps to its targets
    /// (no stretch, no lift spring) and positions use the critically damped `reduced` spring.
    mutating func step(_ dt: CGFloat, style: DropletStyle, reduceMotion: Bool, calm: Bool) -> Bool {
        offset.step(dt, spring: reduceMotion ? NibMotion.reduced : positionSpring)
        size.step(dt, spring: reduceMotion ? NibMotion.reduced : sizeSpring)
        corner.step(dt, spring: reduceMotion ? NibMotion.reduced : sizeSpring)
        anchor.step(dt, spring: NibMotion.snap)
        if reduceMotion {
            lift.snap(to: lift.target)
        } else {
            lift.step(dt, spring: NibMotion.lift)
        }

        let v = offset.velocity
        let speed = (v.dx * v.dx + v.dy * v.dy).squareRoot()
        let cap = calm ? style.stretchCap / 2 : style.stretchCap
        var target = DropletPhysics.stretchTarget(speed: speed, cap: cap, vRef: style.vRef)
        let w = max(size.x.value, 1), h = max(size.y.value, 1)
        let long: CGFloat = w >= h ? 0 : .pi / 2
        let weight = DropletPhysics.longAxisWeight(aspect: max(w, h) / min(w, h))
        let phi = atan2(v.dy, v.dx)
        if speed > 40 {
            target *= 1 + (cos(2 * (phi - long)) - 1) * weight
        }
        let free = speed > 40 ? phi : axis
        axis = DropletPhysics.followAxis(axis, toward: free + DropletPhysics.wrapHalfTurn(long - free) * weight, dt: dt)

        if reduceMotion || cap == 0 {
            stretch.snap(to: 0)
        } else {
            stretch.target = target
            stretch.step(dt, spring: NibMotion.wobble(minor: min(w, h)))
        }
        return !(offset.isResting && size.isResting && corner.isResting && stretch.isResting
                 && lift.isResting && anchor.isResting)
    }
}
