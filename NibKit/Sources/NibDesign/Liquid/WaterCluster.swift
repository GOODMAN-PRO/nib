import SwiftUI

/// One group of droplets whose water can touch, drawn by one canvas framed to `frame` (container coordinates).
struct WaterCluster: Identifiable, Equatable {
    /// The first droplet's id: stable while the group exists, so SwiftUI keeps the canvas.
    let id: String
    var renders: [DropletField.Render]
    var necks: [DropletField.Neck]
    var satellites: [DropletField.Satellite]
    var frame: CGRect
    /// 0.22 while any member recedes (the union cannot fade one member without changing its shape).
    var opacity: Double

    /// Union-find over the linked pairs; groups keep the order of `ids`.
    static func groups(_ ids: [String], linked: Set<DropletField.PairKey>) -> [[String]] {
        var parent = Dictionary(uniqueKeysWithValues: ids.map { ($0, $0) })
        func root(_ x: String) -> String {
            var r = x
            while let p = parent[r], p != r { r = p }
            var y = x
            while let p = parent[y], p != r { parent[y] = r; y = p }     // path compression
            return r
        }
        for pair in linked where parent[pair.a] != nil && parent[pair.b] != nil {
            let ra = root(pair.a), rb = root(pair.b)
            if ra != rb { parent[rb] = ra }
        }
        var order: [String] = []
        var members: [String: [String]] = [:]
        for id in ids {
            let r = root(id)
            if members[r] == nil { order.append(r) }
            members[r, default: []].append(id)
        }
        return order.compactMap { members[$0] }
    }
}
