import AppKit
import SwiftUI
import PhosphorCore

/// The credits, a demoscene intro in a window of its own. Big flat letters in the same
/// 3D space as the Starfield theme's stars: "Thanks for listening to", calm; the camera
/// starts to move; "Resonance" arrives and the letters start to turn; the rest passes in
/// that motion; the stars settle; then the names; and last the stars fall into a heart
/// that beats and fades. The reasoning is in
/// design/credits/README.md, with the mockups this follows.
struct CreditsView: View {
    static let windowID = "credits"

    @Environment(PlayerStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistsStore.self) private var playlists
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var renderer = CreditsRenderer()
    @State private var started = Date.now
    @State private var escape = CreditsEscapeKey()

    private var tune: CreditsScene.Tune? {
        store.nowPlaying.map { CreditsScene.Tune(title: $0.displayTitle, author: $0.author) }
    }

    /// With Reduce Motion, only the names, with nothing flying.
    private func seconds(at date: Date) -> Double {
        date.timeIntervalSince(started) + (reduceMotion ? CreditsScene.timing.namesFrom : 0)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / ScreenRefreshClock.creditsFramesPerSecond)) { context in
            if let image = renderer.image(seconds: seconds(at: context.date), tune: tune, still: reduceMotion) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(CreditsScene.width / CreditsScene.height, contentMode: .fit)
            }
        }
        .frame(minWidth: 480, maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        .background(.black)
        .ignoresSafeArea()
        .contentShape(.rect)
        .onTapGesture { close() }
        .accessibilityElement()
        .accessibilityLabel("Credits. Press Escape to close.")
        .onAppear {
            started = .now
            Task.detached(priority: .utility) { CreditsScene.prepareHeart() }
            escape.start { [dismissWindow] in dismissWindow(id: Self.windowID) }
        }
        .onDisappear { escape.stop() }
        .task { await startMusic() }
        .task { await closeAtTheEnd() }
    }

    private func close() {
        dismissWindow(id: Self.windowID)
    }

    /// Credits need a soundtrack: Favorites if nothing's on, or else Surprise Me.
    /// Something paused is left alone, as that was someone's choice.
    private func startMusic() async {
        guard store.nowPlaying == nil || store.state == .stopped else { return }
        await playlists.loadRows(PlaylistsStore.favoritesID)
        let favorites = playlists.rows[PlaylistsStore.favoritesID] ?? []
        if favorites.isEmpty {
            if library.hasRoot { await library.surpriseMe() }
        } else {
            library.play(favorites, from: .favorites)
        }
    }

    private func closeAtTheEnd() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled, seconds(at: .now) >= CreditsScene.length(tune: tune) {
                close()
                return
            }
        }
    }
}

/// Esc closes the credits. A local monitor, as nothing in the window takes the focus.
final class CreditsEscapeKey {
    private var monitor: Any?

    func start(_ close: @escaping @MainActor () -> Void) {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53, event.window?.identifier?.rawValue.hasPrefix(CreditsView.windowID) == true else { return event }
            MainActor.assumeIsolated { close() }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// The picture, one 320×200 bitmap a frame with nothing smoothed; only the heart at the
/// end is drawn finer and smooth. No state of its own but the bitmaps: a moment always
/// draws the same.
nonisolated final class CreditsRenderer {
    private let bitmap: CGContext?
    private let fine: CGContext?
    // The standalone window needs 4× dots; the CRT only needs its raster's
    // resolution, rather than drawing a megapixel heart and shrinking it.
    init(fineScale: Double = 4) {
        let scale = fineScale
        fine = CGContext(data: nil, width: Int(CreditsScene.width * scale), height: Int(CreditsScene.height * scale), bitsPerComponent: 8,
                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        fine?.translateBy(x: 0, y: CreditsScene.height * scale)
        fine?.scaleBy(x: scale, y: -scale)
        bitmap = CGContext(data: nil, width: Int(CreditsScene.width), height: Int(CreditsScene.height), bitsPerComponent: 8,
                           bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        bitmap?.setAllowsAntialiasing(false)
        bitmap?.setShouldAntialias(false)
        bitmap?.translateBy(x: 0, y: CreditsScene.height)
        bitmap?.scaleBy(x: 1, y: -1)
    }

    private static func color(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> CGColor {
        CGColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    private let vignette = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [color(0, 0, 0, 0), color(0, 0, 0, 0.35), color(0, 0, 0, 0.97)] as CFArray,
        locations: [0, 0.55, 1]
    )

    /// Round dots at four times the size, on the same background.
    private func heartImage(elapsed: Double, endingFrom: Double, still: Bool) -> CGImage? {
        guard let gc = fine else { return nil }
        let (width, height) = (CreditsScene.width, CreditsScene.height)
        gc.setFillColor(Self.color(5, 6, 8))
        gc.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if let vignette {
            let middle = CGPoint(x: width / 2, y: height / 2)
            gc.drawRadialGradient(vignette, startCenter: middle, startRadius: 50, endCenter: middle, endRadius: 190,
                                  options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        for star in CreditsScene.heartStars(elapsed: elapsed, endingFrom: endingFrom, still: still) where star.alpha > 0 {
            gc.setFillColor(Self.color(star.ink, star.ink, star.ink, star.alpha))
            gc.fillEllipse(in: CGRect(x: star.x - star.size / 2, y: star.y - star.size / 2, width: star.size, height: star.size))
        }
        return gc.makeImage()
    }

    func image(seconds: Double, tune: CreditsScene.Tune?, still: Bool) -> CGImage? {
        let endingFrom = CreditsScene.endingFrom(tune: tune)
        if seconds >= endingFrom {
            return heartImage(elapsed: seconds - endingFrom, endingFrom: endingFrom, still: still)
        }
        guard let gc = bitmap else { return nil }
        let (width, height) = (CreditsScene.width, CreditsScene.height)
        let timing = CreditsScene.timing
        gc.setFillColor(Self.color(5, 6, 8))
        gc.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Held at one moment of the flight with Reduce Motion.
        let flightSeconds = still ? timing.namesFrom : seconds
        for star in CreditsScene.stars(seconds: flightSeconds) {
            gc.setFillColor(Self.color(star.ink, star.ink, star.ink, star.alpha))
            gc.fill(CGRect(x: star.x.rounded(.down), y: star.y.rounded(.down), width: star.size, height: star.size))
        }
        if let vignette {
            let middle = CGPoint(x: width / 2, y: height / 2)
            gc.drawRadialGradient(vignette, startCenter: middle, startRadius: 50, endCenter: middle, endRadius: 190,
                                  options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }

        if seconds < timing.namesFrom {
            for letter in CreditsScene.letters(seconds: seconds) {
                gc.setFillColor(Self.color(letter.light - 5, letter.light, letter.light - 3))
                let path = CGMutablePath()
                for shape in letter.shapes {
                    path.addLines(between: shape.map { CGPoint(x: $0.0, y: $0.1) })
                    path.closeSubpath()
                }
                gc.addPath(path)
                gc.fillPath(using: .evenOdd)
            }
        } else {
            drawPage(gc, elapsed: seconds - timing.namesFrom, tune: tune, still: still)
        }
        return gc.makeImage()
    }

    private func drawPage(_ gc: CGContext, elapsed: Double, tune: CreditsScene.Tune?, still: Bool) {
        let pages = CreditsScene.pages(tune: tune)
        let index = Int(elapsed / CreditsScene.hold)
        guard pages.indices.contains(index) else { return }
        let pageElapsed = elapsed - Double(index) * CreditsScene.hold
        let page = pages[index]
        let rows: [(String, Double, Int, CGColor)] = [
            (page[0], 78, 1, Self.color(233, 161, 59)),
            (page[1], 94, page[1].count > 26 ? 1 : 2, Self.color(255, 255, 255)),
            (page[2], 118, 1, Self.color(168, 168, 168)),
        ]
        for (row, line) in rows.enumerated() {
            let letters = Array(line.0)
            let size = Double(line.2)
            let left = (CreditsScene.width / 2 - Double(letters.count) * 6 * size / 2).rounded()
            gc.setFillColor(line.3)
            for (i, letter) in letters.enumerated() {
                let place = still
                    ? CreditsScene.Placed(isOn: true, x: 0, y: 0)
                    : CreditsScene.placed(letter: i, of: letters.count, row: row, pageElapsed: pageElapsed, elapsed: elapsed)
                guard place.isOn else { continue }
                let columns = CreditsScene.bitmapColumns(letter)
                for column in columns.indices {
                    for bit in 0..<8 where columns[column] >> bit & 1 == 1 {
                        gc.fill(CGRect(x: left + Double(i) * 6 * size + Double(column) * size + place.x,
                                       y: line.1 + Double(bit) * size + place.y, width: size, height: size))
                    }
                }
            }
        }
    }
}

/// What's on screen when: all arithmetic, no drawing.
nonisolated enum CreditsScene {
    struct Tune: Equatable {
        let title: String
        let author: String
    }

    struct Star {
        let x: Double
        let y: Double
        let ink: Double
        let alpha: Double
        let size: Double
    }

    struct Letter {
        let shapes: [[(Double, Double)]]
        let far: Double
        let light: Double
    }

    struct Placed {
        let isOn: Bool
        let x: Double
        let y: Double
    }

    struct Timing {
        let line: [Character]
        let places: [Double]
        let cameraStarts: Double
        let lettersStart: Double
        let settleFrom: Double
        let namesFrom: Double
    }

    static let width = 320.0
    static let height = 200.0
    static let hold = 6.0

    private static let thanks = "THANKS FOR LISTENING TO"
    private static let name = "RESONANCE"
    private static let people = "WE WOULD LIKE TO THANK THE FOLLOWING PEOPLE"
    private static let focal = width / 2
    /// Where in the stars' flight this starts: the camera's turning is nearly steady for
    /// the next few seconds, so the letters stay in view.
    private static let flightFrom = 8.0
    private static let refYaw = 1.8
    private static let letterHeight = 0.19
    private static let letterWidth = 0.255
    private static let nearest = 0.14
    private static let side: V = [0, -0.45, 3.7]
    private static let step = 1.76
    private static let space = 0.95
    private static let readSpeed = 6.0
    private static let tilt = 0.22
    private static let arrives = 3.8
    private static let start = 5.2
    private static let settle = 3.0
    private static let drift = 0.22
    private static let driftEase = 1.5
    private static let rollRate = 0.55
    static let spinRate = 1.05
    private static let circleRate = 0.55
    /// Super bold: each outline grows, and each counter shrinks, by this much.
    private static let bold = 0.3
    private static let mitre = 2.1
    private static let starCount = 500

    /// As in the terminal app's credits (cli/src/credits.rs).
    private static let people13: [[String]] = [
        ["A PRODUCTION BY", "ERIK LUIMES", ""],
        ["DIRECTOR OF SAYING NO", "ERIK LUIMES", "IT WAS PERFECT, PUT IT BACK"],
        ["TYPED VERY FAST", "CLAUDE", "BY ANTHROPIC"],
        ["BROKE THE BUILD", "CLAUDE", "TWICE BEFORE COFFEE"],
        ["BUILT THE HOUSE WE MOVED INTO", "MARCIN SPOCZYNSKI", "PHOSPHOR"],
        ["CHIP WHISPERER", "DAG LEM", "RESID"],
        ["CHIEF OF DISTORTION", "ANTTI LANKILA", "RESID-FP"],
        ["WENT DOWN TO THE TRANSISTORS", "LEANDRO NINI", "LIBSIDPLAYFP AND RESIDFP"],
        ["ALL YOUR BASE BELONG TO", "HERMIT", "CRSID, THE BASE OF SIDLITE"],
        ["AND EVERYONE ELSE WHO OPENED THE CHIP", "THE SID COMMUNITY", "DIE SHOTS, PATCHES AND PATIENCE"],
        ["THREE VOICES SHOULD BE ENOUGH", "BOB YANNES", "MOS 6581, 1982"],
        ["HEAD OF 60,000 THINGS", "THE HVSC CREW", "AND EVERY COMPOSER IN IT"],
        ["PROFESSIONAL LISTENER", "YIZHI LI ET AL", "MERT"],
        ["SKULL SURGEON", "INIGO QUILEZ", "DISTANCE FUNCTIONS"],
        ["ALL RESPECT TO THE DEMOSCENE", "TRITON", "WE FORGIVE THE PC"],
        ["I'LL CHECK IT LATER... MAYBE", "RICHARD SIMPSON", "INTERNATIONAL KARATEKA ANY DAY NOW"],
    ]

    typealias V = [Double]

    private static let outlines: [Character: [[(Double, Double)]]] = [
        "A": [[(1.8, 0.0), (3.2, 0.0), (5.0, 7.0), (3.6, 7.0), (3.2, 5.3), (1.8, 5.3), (1.4, 7.0), (0.0, 7.0)], [(1.85, 4.15), (3.15, 4.15), (2.5, 1.2)]],
        "B": [[(0.0, 0.0), (4.0, 0.0), (5.0, 1.0), (5.0, 2.7), (4.3, 3.5), (5.0, 4.3), (5.0, 6.0), (4.0, 7.0), (0.0, 7.0)], [(1.4, 1.2), (3.3, 1.2), (3.6, 1.5), (3.6, 2.5), (3.3, 2.8), (1.4, 2.8)], [(1.4, 4.2), (3.3, 4.2), (3.6, 4.5), (3.6, 5.5), (3.3, 5.8), (1.4, 5.8)]],
        "C": [[(1.0, 0.0), (5.0, 0.0), (5.0, 1.3), (1.7, 1.3), (1.4, 1.6), (1.4, 5.4), (1.7, 5.7), (5.0, 5.7), (5.0, 7.0), (1.0, 7.0), (0.0, 6.0), (0.0, 1.0)]],
        "D": [[(0.0, 0.0), (3.6, 0.0), (5.0, 1.4), (5.0, 5.6), (3.6, 7.0), (0.0, 7.0)], [(1.4, 1.3), (3.0, 1.3), (3.6, 1.9), (3.6, 5.1), (3.0, 5.7), (1.4, 5.7)]],
        "E": [[(0.0, 0.0), (5.0, 0.0), (5.0, 1.3), (1.4, 1.3), (1.4, 2.8), (4.2, 2.8), (4.2, 4.1), (1.4, 4.1), (1.4, 5.7), (5.0, 5.7), (5.0, 7.0), (0.0, 7.0)]],
        "F": [[(0.0, 0.0), (5.0, 0.0), (5.0, 1.3), (1.4, 1.3), (1.4, 2.8), (4.2, 2.8), (4.2, 4.1), (1.4, 4.1), (1.4, 7.0), (0.0, 7.0)]],
        "G": [[(1.0, 0.0), (5.0, 0.0), (5.0, 1.3), (1.7, 1.3), (1.4, 1.6), (1.4, 5.4), (1.7, 5.7), (3.6, 5.7), (3.6, 4.3), (2.6, 4.3), (2.6, 3.1), (5.0, 3.1), (5.0, 7.0), (1.0, 7.0), (0.0, 6.0), (0.0, 1.0)]],
        "H": [[(0.0, 0.0), (1.4, 0.0), (1.4, 2.8), (3.6, 2.8), (3.6, 0.0), (5.0, 0.0), (5.0, 7.0), (3.6, 7.0), (3.6, 4.1), (1.4, 4.1), (1.4, 7.0), (0.0, 7.0)]],
        "I": [[(1.8, 0.0), (3.2, 0.0), (3.2, 7.0), (1.8, 7.0)]],
        "J": [[(3.6, 0.0), (5.0, 0.0), (5.0, 6.0), (4.0, 7.0), (1.0, 7.0), (0.0, 6.0), (0.0, 4.6), (1.4, 4.6), (1.4, 5.4), (1.7, 5.7), (3.3, 5.7), (3.6, 5.4)]],
        "K": [[(0.0, 0.0), (1.4, 0.0), (1.4, 2.7), (3.4, 0.0), (5.0, 0.0), (2.7, 3.2), (5.0, 7.0), (3.4, 7.0), (1.4, 3.9), (1.4, 7.0), (0.0, 7.0)]],
        "L": [[(0.0, 0.0), (1.4, 0.0), (1.4, 5.7), (5.0, 5.7), (5.0, 7.0), (0.0, 7.0)]],
        "M": [[(0.0, 0.0), (1.3, 0.0), (2.5, 2.6), (3.7, 0.0), (5.0, 0.0), (5.0, 7.0), (3.7, 7.0), (3.7, 2.8), (2.5, 5.2), (1.3, 2.8), (1.3, 7.0), (0.0, 7.0)]],
        "N": [[(0.0, 0.0), (1.3, 0.0), (3.7, 4.6), (3.7, 0.0), (5.0, 0.0), (5.0, 7.0), (3.7, 7.0), (1.3, 2.4), (1.3, 7.0), (0.0, 7.0)]],
        "O": [[(1.0, 0.0), (4.0, 0.0), (5.0, 1.0), (5.0, 6.0), (4.0, 7.0), (1.0, 7.0), (0.0, 6.0), (0.0, 1.0)], [(1.7, 1.3), (3.3, 1.3), (3.6, 1.6), (3.6, 5.4), (3.3, 5.7), (1.7, 5.7), (1.4, 5.4), (1.4, 1.6)]],
        "P": [[(0.0, 0.0), (4.0, 0.0), (5.0, 1.0), (5.0, 3.3), (4.0, 4.3), (1.4, 4.3), (1.4, 7.0), (0.0, 7.0)], [(1.4, 1.2), (3.3, 1.2), (3.6, 1.5), (3.6, 2.8), (3.3, 3.1), (1.4, 3.1)]],
        "Q": [[(1.0, 0.0), (4.0, 0.0), (5.0, 1.0), (5.0, 5.6), (4.1, 6.4), (5.0, 7.0), (1.0, 7.0), (0.0, 6.0), (0.0, 1.0)], [(1.7, 1.3), (3.3, 1.3), (3.6, 1.6), (3.6, 5.0), (3.3, 5.7), (1.7, 5.7), (1.4, 5.4), (1.4, 1.6)]],
        "R": [[(0.0, 0.0), (4.0, 0.0), (5.0, 1.0), (5.0, 3.0), (4.0, 4.0), (5.0, 7.0), (3.6, 7.0), (2.7, 4.2), (1.4, 4.2), (1.4, 7.0), (0.0, 7.0)], [(1.4, 1.2), (3.4, 1.2), (3.7, 1.5), (3.7, 2.7), (3.4, 3.0), (1.4, 3.0)]],
        "S": [[(1.0, 0.0), (5.0, 0.0), (5.0, 1.3), (1.6, 1.3), (1.4, 1.5), (1.4, 2.6), (1.6, 2.8), (4.0, 2.8), (5.0, 3.8), (5.0, 6.0), (4.0, 7.0), (0.0, 7.0), (0.0, 5.7), (3.4, 5.7), (3.6, 5.5), (3.6, 4.3), (3.4, 4.1), (1.0, 4.1), (0.0, 3.1), (0.0, 1.0)]],
        "T": [[(0.0, 0.0), (5.0, 0.0), (5.0, 1.3), (3.2, 1.3), (3.2, 7.0), (1.8, 7.0), (1.8, 1.3), (0.0, 1.3)]],
        "U": [[(0.0, 0.0), (1.4, 0.0), (1.4, 5.4), (1.7, 5.7), (3.3, 5.7), (3.6, 5.4), (3.6, 0.0), (5.0, 0.0), (5.0, 6.0), (4.0, 7.0), (1.0, 7.0), (0.0, 6.0)]],
        "V": [[(0.0, 0.0), (1.5, 0.0), (2.5, 5.0), (3.5, 0.0), (5.0, 0.0), (3.3, 7.0), (1.7, 7.0)]],
        "W": [[(0.0, 0.0), (1.3, 0.0), (1.6, 4.6), (2.5, 2.4), (3.4, 4.6), (3.7, 0.0), (5.0, 0.0), (4.4, 7.0), (3.1, 7.0), (2.5, 5.4), (1.9, 7.0), (0.6, 7.0)]],
        "X": [[(0.0, 0.0), (1.6, 0.0), (2.5, 2.3), (3.4, 0.0), (5.0, 0.0), (3.3, 3.5), (5.0, 7.0), (3.4, 7.0), (2.5, 4.7), (1.6, 7.0), (0.0, 7.0), (1.7, 3.5)]],
        "Y": [[(0.0, 0.0), (1.5, 0.0), (2.5, 2.6), (3.5, 0.0), (5.0, 0.0), (3.2, 4.0), (3.2, 7.0), (1.8, 7.0), (1.8, 4.0)]],
        "Z": [[(0.0, 0.0), (5.0, 0.0), (5.0, 1.3), (1.8, 5.7), (5.0, 5.7), (5.0, 7.0), (0.0, 7.0), (0.0, 5.7), (3.2, 1.3), (0.0, 1.3)]],
    ]

    private static let bitmapFont: [Character: String] = [
        "A": "7E1111117E",
        "B": "7F49494936",
        "C": "3E41414122",
        "D": "7F4141221C",
        "E": "7F49494941",
        "F": "7F09090901",
        "G": "3E4149497A",
        "H": "7F0808087F",
        "I": "00417F4100",
        "J": "2040413F01",
        "K": "7F08142241",
        "L": "7F40404040",
        "M": "7F020C027F",
        "N": "7F0408107F",
        "O": "3E4141413E",
        "P": "7F09090906",
        "Q": "3E4151215E",
        "R": "7F09192946",
        "S": "4649494931",
        "T": "01017F0101",
        "U": "3F4040403F",
        "V": "1F2040201F",
        "W": "3F4038403F",
        "X": "6314081463",
        "Y": "0708700807",
        "Z": "6151494543",
        "0": "3E5149453E",
        "1": "00427F4000",
        "2": "4261514946",
        "3": "2141454B31",
        "4": "1814127F10",
        "5": "2745454539",
        "6": "3C4A494930",
        "7": "0171090503",
        "8": "3649494936",
        "9": "064949291E",
        ",": "0050300000",
        ".": "0060600000",
        "'": "0004030100",
        "-": "0808080808"
    ]

    private static let font: [Character: [[(Double, Double)]]] = outlines.mapValues { shapes in
        shapes.enumerated().map { index, shape in grown(shape, by: index == 0 ? bold : -bold) }
    }

    static let timing: Timing = {
        let line = Array("\(thanks)   \(name)   \(people)")
        var places: [Double] = []
        var x = start
        for letter in line {
            places.append(x)
            x += letter == " " ? space : step
        }
        let cameraStarts = (places[thanks.count - 1] - arrives) / readSpeed
        let lettersStart = (places[thanks.count + 3] - arrives) / readSpeed
        let settleFrom = (places[line.count - 1] + 7) / readSpeed
        return Timing(line: line, places: places, cameraStarts: cameraStarts, lettersStart: lettersStart,
                      settleFrom: settleFrom, namesFrom: settleFrom + settle + 0.3)
    }()

    /// The people, then whoever's playing, as the one actually doing the work.
    static func pages(tune: Tune?) -> [[String]] {
        guard let tune else { return people13 + [you] }
        let title = shown(tune.title)
        let author = tune.author.trimmingCharacters(in: .whitespaces)
        // HVSC's way of saying no one knows.
        let page = author.isEmpty || author == "<?>"
            ? ["ACTUALLY DOING THE WORK", title, "NOW PLAYING"]
            : ["ACTUALLY DOING THE WORK", shown(author), String("\(title), NOW PLAYING".prefix(52))]
        return people13 + [page, you]
    }

    private static let you = ["AND MOST OF ALL", "YOU", "THANKS FOR LISTENING"]

    /// How long the stars take to fall into the heart; it beats, and the camera starts
    /// moving after the first beat; on the third the stars start drifting apart; and it all
    /// fades, in seconds, with a moment of black before the window closes.
    static let collapse = 2.8
    static let burst = 4.0
    static let fadeOut = 1.4
    static let blackAtTheEnd = 0.4

    /// When the names are over and the heart begins.
    static func endingFrom(tune: Tune?) -> Double {
        timing.namesFrom + Double(pages(tune: tune).count) * hold
    }

    /// In the bitmap font's letters: capitals, without accents, on one line.
    private static func shown(_ text: String) -> String {
        String(text.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .init(identifier: "en")).uppercased().prefix(52))
    }

    static func length(tune: Tune?) -> Double {
        endingFrom(tune: tune) + collapse + beating + burst + fadeOut + blackAtTheEnd
    }

    static func bitmapColumns(_ letter: Character) -> [UInt8] {
        guard let hex = bitmapFont[letter] else { return [] }
        let digits = Array(hex)
        return stride(from: 0, to: digits.count, by: 2).compactMap { UInt8(String(digits[$0...($0 + 1)]), radix: 16) }
    }

    /// A letter of a name: it drops into place, holds, then scatters.
    static func placed(letter i: Int, of count: Int, row: Int, pageElapsed: Double, elapsed t: Double) -> Placed {
        let index = Double(i)
        let begins = index * min(0.048, 1.2 / Double(max(count, 1))) + Double(row) * 0.16
        let coming = min(1, max(0, (pageElapsed - begins) / 0.4))
        let going = max(0, (pageElapsed - (hold - 0.56) - index * 0.016) / 0.32)
        let left = 1 - coming
        return Placed(isOn: coming > 0 && going < 1,
                      x: (sin(index + t) * left * 30 + going * (index - Double(count) / 2) * 18).rounded(),
                      y: (-left * left * 50 + sin(index * 0.9 + t * 4) * left * 6 + going * going * 70).rounded())
    }

    /// How far something has turned: its rate grows in from nothing when it starts,
    /// holds, then eases out as the stars settle, keeping the place it reached.
    static func turned(_ seconds: Double, rate: Double, from: Double) -> Double {
        let a = max(0, min(seconds, timing.settleFrom) - from)
        let b = min(settle, max(0, seconds - timing.settleFrom))
        return rate * (a * a / (a + 1.6) + b - b * b / (2 * settle))
    }

    private static func smooth(_ x: Double) -> Double {
        let v = min(1, max(0, x))
        return v * v * (3 - 2 * v)
    }

    private static func hash(_ n: Double) -> Double {
        abs((sin(n) * 43_758.5453).truncatingRemainder(dividingBy: 1))
    }

    private static let starPlaces: [V] = (0..<starCount).map { k in
        let n = Double(k)
        return [hash(n * 12.989) * 2, hash(n * 78.233) * 2, hash(n * 37.719) * 2]
    }

    /// The Starfield theme's flight, turned against the text until the camera starts, so
    /// the stars drift the other way, and rolling after.
    static func stars(seconds: Double) -> [Star] {
        placed(seconds: seconds).compactMap { x, y, z in
            guard z > 0.03, x >= 0, x < width, y >= 0, y < height else { return nil }
            let near = max(0, 1 - z)
            return Star(x: x, y: y, ink: ink(near: near), alpha: min(1, 0.35 + near), size: near > 0.75 ? 2 : 1)
        }
    }

    private static func ink(near: Double) -> Double {
        near > 0.6 ? 255 : near > 0.3 ? 168 : 94
    }

    /// Every star on the picture at this moment, in view or not, with its depth.
    private static func placed(seconds: Double) -> [(x: Double, y: Double, z: Double)] {
        let flight = flightFrom + seconds
        let drifted = min(seconds, timing.cameraStarts)
        let easing = min(driftEase, max(0, seconds - timing.cameraStarts))
        let turn = -drift * (drifted + easing - easing * easing / (2 * driftEase))
        let yaw = flight * 0.12 + sin(flight * 0.21) * 0.9 + turn
        let pitch = sin(flight * 0.15) * 0.35
        let roll = sin(flight * 0.09) * 0.5 + turned(seconds, rate: rollRate, from: timing.cameraStarts)
        let (cy, sy, cp, sp, cr, sr) = (cos(yaw), sin(yaw), cos(pitch), sin(pitch), cos(roll), sin(roll))
        let camera = [sin(flight * 0.05) * 3, sin(flight * 0.07) * 2, flight * 0.3]
        return starPlaces.map { place in
            let r = (0..<3).map { axis -> Double in
                let d = place[axis] - camera[axis]
                return d - (d / 2).rounded(.down) * 2 - 1
            }
            let x1 = r[0] * cy - r[2] * sy, z1 = r[0] * sy + r[2] * cy
            let y2 = r[1] * cp - z1 * sp, z2 = r[1] * sp + z1 * cp
            let x3 = x1 * cr - y2 * sr, y3 = x1 * sr + y2 * cr
            let z = max(z2, 0.03)
            return (width / 2 + x3 / z * focal, height / 2 + y3 / z * focal, z2)
        }
    }

    /// Where each star ends up: on or inside a heart, x across, y up and z toward you. The
    /// same surface as the particle heart on backtostatic.com.
    static let heartPlaces: [V] = {
        func surface(_ x: Double, _ y: Double, _ z: Double) -> Double {
            let a = x * x + 2.25 * y * y + z * z - 1
            return a * a * a - x * x * z * z * z - 0.1125 * y * y * z * z * z
        }
        var places: [V] = []
        places.reserveCapacity(heartPoints)
        let e = 0.002
        // Seeded, so it's the same heart each time. A weaker sequence showed as streaks
        // across it, and an even one as a grid.
        var state: UInt64 = 0x5245_534F_4E41_4E43
        func random() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((z ^ (z >> 31)) >> 11) / 9_007_199_254_740_992
        }
        var tries = 0
        while places.count < heartPoints, tries < 6_000_000 {
            tries += 1
            let x = (random() - 0.5) * 2.5, y = (random() - 0.5) * 1.5, z = -1.05 + random() * 2.4
            let value = surface(x, y, z)
            // Every third star goes inside: it gives the heart body with so few, and
            // depth for the camera to fly through. The rest draw its outline.
            if places.count % 3 == 2 {
                if value < 0 { places.append([x * 1.45, (z - 0.12) * 1.45, y * 1.45]) }
                continue
            }
            guard abs(value) <= 0.2 else { continue }
            let gx = (surface(x + e, y, z) - surface(x - e, y, z)) / (2 * e)
            let gy = (surface(x, y + e, z) - surface(x, y - e, z)) / (2 * e)
            let gz = (surface(x, y, z + e) - surface(x, y, z - e)) / (2 * e)
            let slope = max((gx * gx + gy * gy + gz * gz).squareRoot(), 1e-6)
            guard abs(value / slope) < 0.02 else { continue }
            places.append([x * 1.45, (z - 0.12) * 1.45, y * 1.45])
        }
        return places
    }()

    /// The heart is made of the stars themselves, and nothing else.
    private static let heartPoints = starCount

    /// Works the heart out ahead of the moment it's needed.
    static func prepareHeart() {
        _ = heartPlaces.count
    }

    /// How many beats have begun `seconds` after the first: 52 a minute, drifting with a
    /// five-second breath, as a resting heart's do. It's the sum of the rate up to now, so
    /// a moment always draws the same.
    private static func beatsBegun(_ seconds: Double) -> Double {
        let rate = 52.0 / 60, breath = 5.0, drift = 0.06
        return rate * (seconds + drift * breath / (2 * .pi) * (1 - cos(2 * .pi * seconds / breath)))
    }

    /// A heart at deep rest, as a share of its size: one soft beat and a flat pause after
    /// it, with nothing of the lub-dub.
    static func beat(_ seconds: Double) -> Double {
        let beats = beatsBegun(seconds)
        let phase = beats - beats.rounded(.down)
        guard phase < 0.4 else { return 0 }
        let n = phase / 0.4
        return pow(sin(n * .pi), 4) * exp(-n * 3) * 0.15
    }

    private static func whenBeatBegins(_ count: Double) -> Double {
        var (low, high) = (0.0, 10.0)
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if beatsBegun(middle) < count { low = middle } else { high = middle }
        }
        return high
    }

    /// When the second beat begins, which is when the camera starts moving.
    static let firstBeat = whenBeatBegins(1)
    /// When the third beat begins, which is when the stars start drifting apart.
    static let beating = whenBeatBegins(2)

    private static func vignetted(_ x: Double, _ y: Double) -> Double {
        let reach = min(1, max(0, (hypot(x - width / 2, y - height / 2) - 50) / 140))
        return reach < 0.55 ? reach / 0.55 * 0.35 : 0.35 + (reach - 0.55) / 0.45 * 0.62
    }

    /// The nearest two-thirds of the stars fall into the heart. The rest stay out there.
    private static func fallingIn(_ origin: [(x: Double, y: Double, z: Double)]) -> Set<Int> {
        let distance = { (i: Int) -> Double in
            origin[i].z > 0.03 ? hypot(origin[i].x - width / 2, origin[i].y - height / 2) : .infinity
        }
        return Set(origin.indices.sorted { (distance($0), $0) < (distance($1), $1) }.prefix(origin.count * 2 / 3))
    }

    /// The flight slows to a stop as the heart forms and picks up again after the first beat.
    private static func endingFlight(elapsed: Double, endingFrom: Double, still: Bool) -> Double {
        let falling = still ? 0 : min(elapsed, collapse)
        let stopped = endingFrom + falling - falling * falling / (2 * collapse)
        let flying = still ? 0 : max(0, elapsed - collapse - firstBeat)
        let pickingUp = min(flying, 1.2)
        return stopped + pickingUp * pickingUp / 2.4 + max(0, flying - 1.2)
    }

    /// How fast the sphere spreads through the heart, in the heart's own units a second.
    /// It only says when a star starts to move, and nothing about how fast.
    private static let sphereSpeed = 2.6

    /// A point of the heart, `seconds` after the third beat. Once the sphere has reached
    /// it, it drifts outward from the middle at a speed of its own, starting gently.
    static func drifted(_ place: V, star: Int, seconds: Double) -> V {
        let reach = (place[0] * place[0] + place[1] * place[1] + place[2] * place[2]).squareRoot()
        let since = seconds - reach / sphereSpeed
        guard seconds > 0, since > 0 else { return place }
        let n = Double(star)
        let speed = 0.25 + 1.0 * hash(n * 29.3 + 1)
        let moved = speed * since * since / (since + 0.8)
        // Dead center has no way out of its own, so it's given one.
        let (a, b) = (hash(n * 53.1) * 2 * .pi, hash(n * 11.7 + 2) * .pi)
        let direction = reach > 0.05
            ? [place[0] / reach, place[1] / reach, place[2] / reach]
            : [sin(b) * cos(a), sin(b) * sin(a), cos(b)]
        return [place[0] + direction[0] * moved, place[1] + direction[1] * moved, place[2] + direction[2] * moved]
    }

    /// The ending. The nearest stars leave the flight, which slows to a stop, and fall into
    /// the heart, not all at once. It beats, longer and thinner as it contracts, and sways.
    /// After the first beat the camera starts moving again, turning and creeping forward.
    /// On the third beat a sphere spreads from the middle of the heart, and each star it
    /// reaches starts to drift outward at its own speed, as the camera goes on through
    /// them. They're the same stars throughout: nothing fades in. Then it all fades.
    static func heartStars(elapsed: Double, endingFrom: Double, still: Bool) -> [Star] {
        let falling = fallingIn(placed(seconds: endingFrom))
        let from = placed(seconds: endingFlight(elapsed: elapsed, endingFrom: endingFrom, still: still))
        let formed = max(0, elapsed - collapse)
        let moving = still ? 0 : max(0, formed - firstBeat)
        let drifting = still ? 0 : max(0, formed - beating)
        let fade = 1 - min(1, max(0, elapsed - collapse - beating - burst) / fadeOut)
        let now = still || drifting > 0 ? 0 : beat(formed)
        let (across, up) = (40 * (1 + now * 0.4), 40 * (1 + now * 1.6))
        // The camera turns as the flight does, its speed growing in from nothing.
        let turning = moving * moving / (moving + 1.5)
        let yaw = (still ? 0 : sin(min(elapsed, collapse + firstBeat) * 0.6) * 0.28) + turning * 0.12
        let roll = turning * 0.09
        let (cy, sy, cr, sr) = (cos(yaw), sin(yaw), cos(roll), sin(roll))
        let camera = 4 - 0.12 * moving * moving
        let inDepth = smooth(moving / 1.5)

        var seen: [Star] = []
        seen.reserveCapacity(heartPoints)
        for i in 0..<starCount {
            let angle = hash(Double(i) * 53.1) * 2 * .pi
            guard falling.contains(i), i < heartPlaces.count else {
                let place = from[i]
                guard place.z > 0.03, place.x >= 0, place.x < width, place.y >= 0, place.y < height else { continue }
                let near = max(0, 1 - place.z)
                seen.append(Star(x: place.x, y: place.y, ink: ink(near: near), alpha: min(1, 0.35 + near) * (1 - vignetted(place.x, place.y)) * fade,
                                 size: near > 0.75 ? 2 : 1.2))
                continue
            }
            let place = drifted(heartPlaces[i], star: i, seconds: drifting)
            let x1 = place[0] * cy + place[2] * sy, z1 = -place[0] * sy + place[2] * cy
            let distance = camera - z1 * inDepth
            // Once it's beside the camera it's gone, softly.
            guard distance > 0.15 else { continue }
            let nearer = 4 / distance
            let (screenX, screenY) = (x1 * across * nearer, -place[1] * up * nearer)
            let inHeartX = width / 2 + screenX * cr - screenY * sr, inHeartY = height / 2 + screenX * sr + screenY * cr
            let depth = min(1, max(0, (z1 + 1.8) / 3.6))
            let along = still ? 1 : smooth(elapsed / collapse * 1.35 - hash(Double(i) * 91.7) * 0.35)
            // A star behind the camera or far outside the picture comes in from just beyond its edge.
            let isFar = from[i].z <= 0.03 || hypot(from[i].x - width / 2, from[i].y - height / 2) > 500
            let start = moving > 0 ? (x: inHeartX, y: inHeartY)
                : (x: isFar ? width / 2 + cos(angle) * 300 : from[i].x, y: isFar ? height / 2 + sin(angle) * 300 : from[i].y)
            let x = start.x + (inHeartX - start.x) * along
            let y = start.y + (inHeartY - start.y) * along
            guard x >= 0, x < width, y >= 0, y < height else { continue }
            let near = max(0, 1 - from[i].z)
            let fieldSize = near > 0.75 ? 2 : 1.2
            seen.append(Star(x: x, y: y, ink: ink(near: near) + (110 + 145 * depth - ink(near: near)) * along,
                             alpha: min(1, 0.35 + near + along) * (1 - vignetted(x, y) * (1 - along)) * smooth((distance - 0.15) / 0.5) * fade,
                             size: min(3.5, fieldSize + ((1.0 + 0.5 * depth) * nearer - fieldSize) * along)))
        }
        return seen
    }

    private static func add(_ a: V, _ b: V, _ by: Double) -> V { [a[0] + b[0] * by, a[1] + b[1] * by, a[2] + b[2] * by] }
    private static func scaled(_ a: V, _ by: Double) -> V { [a[0] * by, a[1] * by, a[2] * by] }
    private static func normal(_ v: V) -> V { scaled(v, 1 / (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).squareRoot()) }

    /// The letters in view, farthest first: fixed in the scene as the camera moves past.
    static func letters(seconds: Double) -> [Letter] {
        let flight = flightFrom + seconds
        let right = [cos(refYaw), 0, -sin(refYaw)], forward = [sin(refYaw), 0, cos(refYaw)]
        let along = normal([1, 0.24, -0.44])
        let lineNormal = normal([along[2], 0, -along[0]])

        let shared = 0.25 + 0.75 * smooth((seconds - timing.cameraStarts) / 2.5)
        let moving = smooth((seconds - timing.cameraStarts) / 1.6) * (1 - smooth((seconds - timing.settleFrom) / settle))
        let yaw = refYaw + sin(flight * 0.21) * 0.25 * shared + moving * sin(seconds * 0.7) * 0.2
        let pitch = sin(flight * 0.15) * 0.35 * shared + moving * sin(seconds * 0.9) * 0.18
        let roll = sin(flight * 0.09) * 0.5 * shared + turned(seconds, rate: rollRate, from: timing.cameraStarts)
        let (cy, sy, cp, sp, cr, sr) = (cos(yaw), sin(yaw), cos(pitch), sin(pitch), cos(roll), sin(roll))
        func view(_ p: V) -> V {
            let w = [p[0] * right[0] + p[2] * forward[0], p[1], p[0] * right[2] + p[2] * forward[2]]
            let x1 = w[0] * cy - w[2] * sy, z1 = w[0] * sy + w[2] * cy
            let y2 = w[1] * cp - z1 * sp, z2 = w[1] * sp + z1 * cp
            return [x1 * cr - y2 * sr, x1 * sr + y2 * cr, z2]
        }

        // Circling the line while still looking at it: the letters turn around its axis.
        let around = turned(seconds, rate: circleRate, from: timing.cameraStarts)
        let (ca, sa) = (cos(around), sin(around))
        let wildness = smooth((seconds - timing.cameraStarts) / 1.6)
        let spinning = smooth((seconds - timing.lettersStart) / 1.6)
        let xAxis = normal([along[0] * cos(tilt), sin(tilt), along[2] * cos(tilt)])
        let y0 = [-along[0] * sin(tilt), cos(tilt), -along[2] * sin(tilt)]
        let yAxis = add(scaled(y0, ca), lineNormal, sa)
        let nAxis = add(scaled(lineNormal, ca), y0, -sa)
        let offset = [side[0], side[1] * (1 - wildness * 0.75), side[2] * (1 - wildness * 0.32)]

        var seen: [Letter] = []
        for (i, letter) in timing.line.enumerated() {
            let distance = arrives + (timing.places[i] - readSpeed * seconds - arrives) * (1 + wildness * 0.6)
            guard distance <= 7, distance >= -16 + wildness * 3, let shapes = font[letter] else { continue }
            // Out of step with their neighbors by a little, never by how far along the line.
            let spin = turned(seconds, rate: spinRate, from: timing.lettersStart) + spinning * sin(Double(i) * 1.7) * 0.7
            let (cs, ss) = (cos(spin), sin(spin))
            let base = add(offset, along, distance)
            let face = view(add(scaled(nAxis, cs), xAxis, ss))
            var far = 0.0, behind = false
            var projected: [[(Double, Double)]] = []
            for shape in shapes {
                var points: [(Double, Double)] = []
                for point in shape {
                    let u = (point.0 - 2.5) * letterWidth, v = (point.1 - 3.5) * letterHeight
                    let p = view(add(add(add(base, xAxis, u * cs), nAxis, u * ss), yAxis, v))
                    if p[2] < nearest { behind = true }
                    far = max(far, p[2])
                    points.append((width / 2 + p[0] / p[2] * focal, height / 2 + p[1] / p[2] * focal))
                }
                projected.append(points)
            }
            if !behind {
                seen.append(Letter(shapes: projected, far: far, light: 212 + 40 * abs(face[2])))
            }
        }
        return seen.sorted { $0.far > $1.far }
    }

    /// A letter's outline made bolder. Each point moves along the corner's bisector, away
    /// from the shape, with sharp corners held back so they don't spike.
    static func grown(_ points: [(Double, Double)], by: Double) -> [(Double, Double)] {
        let count = points.count
        let area = (0..<count).reduce(0.0) { sum, i in
            let p = points[i], q = points[(i + 1) % count]
            return sum + p.0 * q.1 - q.0 * p.1
        }
        let turn = area > 0 ? 1.0 : -1.0
        func direction(_ a: (Double, Double), _ b: (Double, Double)) -> (Double, Double) {
            let x = b.0 - a.0, y = b.1 - a.1, length = hypot(x, y)
            return (x / length, y / length)
        }
        return (0..<count).map { i in
            let p = points[i]
            let before = direction(points[(i + count - 1) % count], p), after = direction(p, points[(i + 1) % count])
            let n1 = (before.1 * turn, -before.0 * turn), n2 = (after.1 * turn, -after.0 * turn)
            var x = n1.0 + n2.0, y = n1.1 + n2.1
            let length = hypot(x, y)
            if length > 0 { x /= length; y /= length }
            let reach = min(1 / max(0.001, x * n1.0 + y * n1.1), mitre) * by
            return (p.0 + x * reach, p.1 + y * reach)
        }
    }
}
