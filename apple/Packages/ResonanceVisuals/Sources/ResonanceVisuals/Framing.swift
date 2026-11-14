import simd

/// How the 3D visualizers frame a view that's taller than it's wide, as a
/// phone in portrait is. They were made for the Mac's wide windows: a lens
/// sized to the view's height, and a camera that stands back when the view
/// narrows. In portrait that left the scene small in the middle of a tall
/// screen. Here the lens is sized to the width instead, with the camera at
/// its usual distance: the scene spans the width as it does in a square
/// view, and the extra height shows more above and below. Views at least
/// as wide as they're tall (every Mac window) are framed as before.
public enum Framing {
    /// The lens's focal length in pixels and how far back the camera
    /// stands, for a view of `size` pixels. `focal` is the lens as a share
    /// of the height; `standBack` is how far back a square view stands.
    public static func lens(size: SIMD2<Float>, focal: Float, standBack: Float) -> (focal: Float, back: Float) {
        let aspect = size.x / max(size.y, 1)
        guard aspect < 1 else {
            return (size.y * focal, max(1, standBack / max(aspect, 0.2)))
        }
        // Standing `standBack` away with the lens at focal × height shows
        // the same width as standing at 1 with focal × width / standBack.
        return (size.x * focal / standBack, 1)
    }
}
