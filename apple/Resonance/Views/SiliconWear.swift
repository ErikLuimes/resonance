import AppKit
import Metal
import SceneKit

/// Forty years on the Silicon visualizer's package: the textures and
/// material code that take its ceramic and gold from clean, even colors
/// to things that have been handled, soldered and left in a drawer.
///
/// One texture, made ahead of time and shipped, holds four kinds of
/// unevenness, each repeating without a seam: fine grain, scratches,
/// large blotches and specks. The materials
/// read it by where a surface is in the world, not by the surface's own
/// coordinates (the package is many boxes of many sizes), from the three
/// directions at once, so the wear runs across every face and edge at
/// one scale with nothing to line up.
nonisolated enum SiliconWear {
    /// The file the wear texture ships in (Scenes/SiliconWear.lzfse), made
    /// by design/visualizers/silicon/make-wear.swift: red is grain, green
    /// scratches, blue blotches, alpha specks. `SiliconAssets` loads it.
    static let file = "SiliconWear"

    /// What every aged material starts with: where the surface is in the
    /// world, the wear there at two scales, and how sharply the surface
    /// turns (its edges). Ends by tilting the surface with its `bump`.
    private static let reading = """
    #pragma arguments
    texture2d<float> wear;

    #pragma body
    constexpr sampler wear_sampler(filter::linear, mip_filter::linear, address::repeat);
    float3 place = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float3 facing = normalize((scn_frame.inverseViewTransform * float4(_surface.normal, 0.0)).xyz);
    float3 share = pow(abs(facing), float3(4.0));
    share /= share.x + share.y + share.z;
    float4 fine = wear.sample(wear_sampler, place.yz * 2.6) * share.x + wear.sample(wear_sampler, place.xz * 2.6) * share.y
        + wear.sample(wear_sampler, place.xy * 2.6) * share.z;
    float4 broad = wear.sample(wear_sampler, place.yz * 0.37 + 0.31) * share.x + wear.sample(wear_sampler, place.xz * 0.37 + 0.31) * share.y
        + wear.sample(wear_sampler, place.xy * 0.37 + 0.31) * share.z;
    // Finer than the grain: the grit that makes a fired surface glint.
    float4 grit = wear.sample(wear_sampler, place.yz * 9.5 + 0.17) * share.x + wear.sample(wear_sampler, place.xz * 9.5 + 0.17) * share.y
        + wear.sample(wear_sampler, place.xy * 9.5 + 0.17) * share.z;
    float edge = saturate(length(fwidth(_surface.normal)) * 2.5);
    float bump = 0.0;
    """

    /// Tilts the surface by the slope of `bump`, worked out from how it
    /// changes between neighboring pixels.
    private static let tilting = """
    float3 across = dfdx(_surface.position), down = dfdy(_surface.position);
    float3 r1 = cross(down, _surface.normal), r2 = cross(_surface.normal, across);
    float det = dot(across, r1);
    float3 slope = sign(det) * (dfdx(bump) * r1 + dfdy(bump) * r2);
    _surface.normal = normalize(abs(det) * _surface.normal - slope);
    """

    /// Fired alumina, the dark purple early 6581s came in: a sparkling
    /// fine grain, scratches that show lighter and rougher, darker
    /// patches where it's been handled, dust settled on what faces up,
    /// and edges chipped down to paler ceramic.
    static let ceramic = reading + """
    // Gray with purple in it, as fired alumina with its glaze is.
    float3 base = float3(0.125, 0.105, 0.135);
    base *= 0.85 + 0.3 * fine.r;
    // Alumina glitters: grains that flash as the light crosses them.
    // Alumina is full of grains that flash as the light crosses them:
    // each a tiny mirror, so they're smooth and metallic where the rest
    // is dull.
    float glitter = saturate(grit.a * 2.2 - 0.7) + saturate((grit.r - 0.7) * 5.0) + saturate(fine.a * 2.0 - 1.1);
    glitter = saturate(glitter);
    base += float3(0.55, 0.53, 0.58) * glitter * 0.35;
    base = mix(base, base * float3(0.6, 0.62, 0.66), saturate(broad.b) * 0.55);
    // Few and fine: only the deeper ones show.
    float scratch = saturate(max(fine.g, broad.g * 0.7) * 1.6 - 0.75);
    base = mix(base, float3(0.36, 0.31, 0.38), scratch * 0.6);
    float chipped = saturate(edge * (0.35 + 1.3 * broad.r) - 0.25);
    base = mix(base, float3(0.55, 0.5, 0.56), chipped * 0.8);
    float dust = saturate(facing.y) * saturate(fine.a * 0.9 + broad.a * 0.3) * 0.5;
    base = mix(base, float3(0.62, 0.6, 0.56), dust);
    _surface.diffuse = float4(base, 1.0);
    _surface.metalness = glitter * 0.85;
    // Handled patches are smoother (skin's oil); scratches and dust rougher.
    _surface.roughness = saturate(0.6 + 0.2 * fine.r - 0.22 * saturate(broad.b) + 0.3 * scratch + 0.3 * dust - 0.5 * glitter);
    // Gritty all over, with shallow dents and pits from the pressing.
    bump = grit.r * 0.0045 + fine.r * 0.003 - smoothstep(0.62, 0.9, broad.r) * 0.0045 - scratch * 0.008 - chipped * 0.012;
    """ + tilting

    /// Gold plate after four decades: still gold, but dulled in patches,
    /// finely scratched, and thinner at the edges. `solder` says how far
    /// up a leg the tin goes (0 for parts that were never soldered): tin
    /// is gray, and by now dull and oxidized. `matte` is 1 for the sandy
    /// plating of a package's lead frame and sealing band, 0 for bright plate.
    static let gold = reading.replacingOccurrences(of: "texture2d<float> wear;", with: "texture2d<float> wear;\nfloat solder;\nfloat matte;") + """
    float3 base = float3(1.0, 0.77, 0.34);
    float tarnish = saturate(broad.b * 0.9 + fine.b * 0.35 - 0.2);
    base = mix(base, float3(0.52, 0.34, 0.13), tarnish * 0.6);
    float scratch = saturate(max(fine.g, broad.g * 0.6) * 1.5 - 0.6);
    base = mix(base, float3(1.0, 0.9, 0.62), scratch * 0.35);
    base = mix(base, float3(0.75, 0.72, 0.66), saturate(edge * 0.8) * 0.5);
    float rough = 0.24 + 0.3 * tarnish + 0.25 * scratch + 0.1 * fine.r;
    // Tinned from the tip up to where the solder wicked, unevenly.
    float tinned = solder > 0.0 ? saturate((solder - place.y) * 9.0 + (broad.r - 0.5) * 2.5) : 0.0;
    float3 tin = float3(0.60, 0.61, 0.60) * (0.7 + 0.5 * fine.r);
    tin = mix(tin, float3(0.33, 0.32, 0.30), saturate(broad.b));
    base = mix(base, tin, tinned);
    rough = mix(rough, 0.5 + 0.3 * saturate(broad.b), tinned);
    // Matte plating, as on a package's lead frame: paler, sandy, with
    // grains that catch the light.
    float glint = saturate(grit.a * 1.6 + (grit.r - 0.6) * 2.4);
    base = mix(base, float3(0.95, 0.68, 0.30) * (0.85 + 0.3 * fine.r) * (1.0 - 0.3 * tarnish), matte * (1.0 - tinned));
    rough = mix(rough, 0.46 + 0.2 * fine.r - 0.34 * glint, matte * (1.0 - tinned));
    _surface.diffuse = float4(base, 1.0);
    // Sandy plate scatters light as much as it mirrors it: that's why it
    // stays gold whatever it's reflecting.
    _surface.metalness = (1.0 - 0.3 * tarnish) * (1.0 - 0.45 * matte * (1.0 - tinned));
    _surface.roughness = saturate(rough);
    // Fired gold paste is orange-peel rough, each grain catching the lamp.
    bump = fine.r * (0.0012 + 0.003 * matte) + grit.r * 0.006 * matte - scratch * 0.004;
    """ + tilting

    /// Black molding compound: matte, with a fine molded texture, rubbed
    /// shiny where it's been handled, scuffed gray, and dusty on top.
    /// `etched` is 1 for what acid has eaten into: gray-brown and
    /// crumbly, with the filler's grains standing out.
    static let plastic = reading.replacingOccurrences(of: "texture2d<float> wear;", with: "texture2d<float> wear;\nfloat etched;") + """
    float3 base = float3(0.016, 0.016, 0.018) * (0.85 + 0.3 * fine.r);
    float rubbed = saturate(broad.b);
    float scratch = saturate(max(fine.g, broad.g * 0.7) * 1.6 - 0.7);
    base = mix(base, float3(0.17, 0.17, 0.18), scratch * 0.6);
    float chipped = saturate(edge * (0.3 + 1.2 * broad.r) - 0.3);
    base = mix(base, float3(0.13, 0.13, 0.13), chipped * 0.6);
    float dust = saturate(facing.y) * saturate(fine.a * 0.9 + broad.a * 0.3 - 0.25) * 0.4;
    base = mix(base, float3(0.3, 0.3, 0.29), dust * (1.0 - etched));
    float3 eaten = float3(0.12, 0.105, 0.09) * (0.55 + 0.9 * grit.r) + float3(0.3, 0.29, 0.27) * saturate(grit.a * 2.0 - 1.0);
    base = mix(base, eaten, etched);
    _surface.diffuse = float4(base, 1.0);
    _surface.metalness = 0.0;
    _surface.roughness = mix(saturate(0.62 + 0.15 * fine.r - 0.2 * rubbed + 0.3 * scratch + 0.3 * dust), 0.93, etched);
    bump = grit.r * 0.002 + fine.r * 0.0015 - scratch * 0.006 - chipped * 0.01 + etched * (grit.r * 0.02 + fine.r * 0.012);
    """ + tilting

    /// Old glue: mostly clear, so the gold shows through it, but gone
    /// cloudy in patches, as it does with age and heat. The clear parts
    /// thin to almost nothing; the smoky ones turn milky and hide what's
    /// under them.
    static let glue = """
    #pragma arguments
    texture2d<float> wear;

    #pragma body
    constexpr sampler wear_sampler(filter::linear, mip_filter::linear, address::repeat);
    float3 place = (scn_frame.inverseViewTransform * float4(_surface.position, 1.0)).xyz;
    float cloud = wear.sample(wear_sampler, place.xz * 0.8 + 0.4).b;
    float wisp = wear.sample(wear_sampler, place.xz * 3.1).r;
    float smoky = smoothstep(0.25, 0.9, cloud + (wisp - 0.5) * 0.15);
    // The color is already multiplied by how much it covers. Cloudy
    // glue scatters whatever light is on it, so it takes that light's
    // brightness but not its color: a warm gray.
    float covers = _output.color.a;
    float bright = dot(_output.color.rgb, float3(0.333));
    float3 smoke = bright * float3(1.1, 1.02, 0.9) * 1.2 + float3(0.1, 0.095, 0.085) * covers;
    _output.color.rgb = mix(_output.color.rgb * 0.45, smoke, smoky);
    // Never more than opaque: past that, blending takes the gold under it
    // away and leaves blue.
    _output.color.a = min(covers * mix(0.45, 1.5, smoky), 0.9);
    """

    /// A material aged with `modifier`, given its settings by name.
    static func aged(_ modifier: String, wear: MTLTexture?, _ values: [String: Float]) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor.gray
        material.metalness.contents = 0.0
        material.roughness.contents = 0.5
        guard let wear else { return material }
        material.shaderModifiers = [.surface: modifier]
        material.setValue(SCNMaterialProperty(contents: wear), forKey: "wear")
        for (name, value) in values { material.setValue(value, forKey: name) }
        return material
    }

    /// A material aged with `modifier` (`ceramic` or `gold`).
    static func material(_ modifier: String, wear: MTLTexture?, solder: Float = 0, matte: Float = 0) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor.gray
        material.metalness.contents = 0.0
        material.roughness.contents = 0.5
        guard let wear else { return material }
        material.shaderModifiers = [.surface: modifier]
        material.setValue(SCNMaterialProperty(contents: wear), forKey: "wear")
        if modifier == gold {
            material.setValue(solder, forKey: "solder")
            material.setValue(matte, forKey: "matte")
        }
        return material
    }

    /// The marking as it is now: up to three lines printed in `ink`,
    /// rubbed thin where fingers and tubes have been at it, with bits
    /// flaked off.
    static func marking(_ lines: [String], ink: NSColor) -> CGImage? {
        let width = 1024, height = 512
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func line(_ text: String, size: CGFloat, y: CGFloat) {
            let font = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
            let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: ink,
                                                                         .kern: size * 0.12])
            context.textPosition = CGPoint(x: 250, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }
        let sizes: [CGFloat] = [130, 150, 120], rows: [CGFloat] = [340, 170, 30]
        for (i, text) in lines.prefix(3).enumerated() { line(text, size: sizes[i], y: rows[i]) }
        // Wear takes ink away: rubbed streaks, then flakes.
        var random = ChipDie.Scatter(seed: 483)
        context.setBlendMode(.destinationOut)
        for _ in 0..<70 {
            let y = random.next() * Double(height), x = random.next() * Double(width)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.15 + random.next() * 0.5))
            context.setLineWidth(1 + random.next() * 5)
            context.move(to: CGPoint(x: x, y: y))
            context.addLine(to: CGPoint(x: x + 40 + random.next() * 300, y: y + (random.next() - 0.5) * 30))
            context.strokePath()
        }
        for _ in 0..<1400 {
            let radius = 0.8 + random.next() * random.next() * 7
            context.setFillColor(CGColor(gray: 0, alpha: 0.5 + random.next() * 0.5))
            context.fillEllipse(in: CGRect(x: random.next() * Double(width), y: random.next() * Double(height), width: radius * 2, height: radius * 2))
        }
        return context.makeImage()
    }

    /// The room the metal reflects: a dim workshop, a long lamp overhead,
    /// a window to one side and a warm bulb to the other.
    static func room() -> CGImage? {
        let width = 1024, height = 512
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(gray: 0.30, alpha: 1), CGColor(gray: 0.12, alpha: 1), CGColor(gray: 0.035, alpha: 1)] as CFArray
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 0.5, 1])!
        // Image rows run top down in an equirectangular map; CG's y runs up.
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
        func lamp(_ rect: CGRect, _ color: CGColor) {
            // A soft edge: a few rectangles, each smaller and brighter.
            for step in 0..<6 {
                let inset = CGFloat(5 - step) * 7
                context.setFillColor(color.copy(alpha: 0.18 + 0.16 * CGFloat(step)) ?? color)
                context.fill(rect.insetBy(dx: -inset, dy: -inset * 0.6))
            }
        }
        lamp(CGRect(x: 250, y: 420, width: 330, height: 46), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        lamp(CGRect(x: 30, y: 300, width: 90, height: 120), CGColor(srgbRed: 0.72, green: 0.84, blue: 1, alpha: 1))
        lamp(CGRect(x: 760, y: 330, width: 70, height: 60), CGColor(srgbRed: 1, green: 0.82, blue: 0.6, alpha: 1))
        return context.makeImage()
    }
}
