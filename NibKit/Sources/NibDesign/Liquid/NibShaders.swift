import SwiftUI

/// The Metal functions in Shaders/NibLiquid.metal, loaded from this module's bundle.
enum NibShaders {
    static let library = ShaderLibrary.bundle(.module)
    static let specular: Float = 0.55

    /// Layer effect over one cluster's field Canvas (iOS 17–25).
    static func waterField(iso: Float) -> Shader {
        library.nibWaterField(
            .float(iso),
            .color(NibColor.clearBody), .color(NibColor.clearBodyOnPaper), .color(NibColor.deepBody), .color(NibColor.accent),
            .color(NibColor.waterBody), .color(NibColor.waterEdge), .color(NibColor.waterCaustic), .color(NibColor.waterRim),
            .color(NibColor.tintRim), .color(NibColor.waterLine), .float(specular))
    }

    /// Colour effect for one static shape (`nibGlass` fallback, folder films, frames): analytic rounded-rect distance,
    /// no sampling. `optics` 0 draws the rim and outline only; `tinted` uses the Tinted rim.
    static func waterRim(cornerRadius: CGFloat, optics: Float, tinted: Bool) -> Shader {
        library.nibWaterRim(
            .boundingRect, .float(cornerRadius), .float(optics),
            .color(NibColor.waterEdge), .color(NibColor.waterCaustic),
            .color(tinted ? NibColor.tintRim : NibColor.waterRim), .color(NibColor.waterLine),
            .float(tinted ? 0 : specular))
    }
}
