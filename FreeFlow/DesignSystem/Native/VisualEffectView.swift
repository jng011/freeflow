import SwiftUI

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let visualEffectView = NSVisualEffectView()
        visualEffectView.material = material
        visualEffectView.blendingMode = blendingMode
        visualEffectView.state = .active
        return visualEffectView
    }

    func updateNSView(_ visualEffectView: NSVisualEffectView, context: Context) {
        if visualEffectView.material != material {
            visualEffectView.material = material
        }
        if visualEffectView.blendingMode != blendingMode {
            visualEffectView.blendingMode = blendingMode
        }
        if visualEffectView.state != .active {
            visualEffectView.state = .active
        }
    }
}

// MARK: - Liquid Glass

/// App-wide Liquid Glass helpers. Uses the real macOS 26 `glassEffect` where
/// available and falls back to a regular material on macOS 15, so the same code
/// builds and runs on both. Reserve glass for chrome/controls (buttons, panels,
/// menu bar, floating surfaces); keep large content cards on material for
/// legibility — matching Apple's own usage.
extension View {
    /// Liquid Glass fill behind this view, clipped to `shape`.
    /// - Parameters:
    ///   - shape: the clip/containment shape (continuous corners recommended).
    ///   - tint: optional accent tint blended into the glass.
    ///   - interactive: enables the pressed/scale glass reaction (for controls).
    @ViewBuilder
    func appGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            let glass: Glass = {
                var g: Glass = .regular
                if let tint { g = g.tint(tint) }
                if interactive { g = g.interactive() }
                return g
            }()
            self.glassEffect(glass, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
        }
    }
}

/// A glass surface view sized by its frame — drop-in replacement for a filled
/// `RoundedRectangle` background where a glassy chrome look is wanted.
struct GlassSurface<S: Shape>: View {
    var shape: S
    var tint: Color? = nil
    var interactive: Bool = false

    var body: some View {
        Color.clear.appGlass(in: shape, tint: tint, interactive: interactive)
    }
}

extension GlassSurface where S == RoundedRectangle {
    init(cornerRadius: CGFloat, tint: Color? = nil, interactive: Bool = false) {
        self.shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        self.tint = tint
        self.interactive = interactive
    }
}
