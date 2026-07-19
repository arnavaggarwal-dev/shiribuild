import SwiftUI
import Network
import Combine
import UIKit
import AVFoundation

// MARK: - Shake Effect

/// Classic Apple recipe: a GeometryEffect that offsets horizontally along a
/// decaying sine wave, driven by an animatable "shakes" value so SwiftUI can
/// interpolate it like any other animation.
struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var amplitude: CGFloat = 10

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = amplitude * sin(shakes * .pi * 2)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

extension View {
    func shake(_ trigger: Int) -> some View {
        modifier(ShakeModifier(trigger: trigger))
    }
}

private struct ShakeModifier: ViewModifier {
    let trigger: Int
    @State private var shakes: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .modifier(ShakeEffect(shakes: shakes))
            .onChange(of: trigger) { _, _ in
                shakes = 0
                withAnimation(.linear(duration: 0.45)) { shakes = 4 }
            }
    }
}

