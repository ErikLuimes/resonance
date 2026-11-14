import SwiftUI

public extension HaloShape {
    /// Where the Halo's SwiftUI shader lives (Shaders/Halo.metal): this
    /// package's bundle, not the app's.
    static var shaders: ShaderLibrary { .bundle(.module) }
}
