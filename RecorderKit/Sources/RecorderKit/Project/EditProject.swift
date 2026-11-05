import Foundation

/// `project.json`: allt användaren har ändrat. Inspelningen i `recording/` rörs aldrig;
/// redigeringen är bara det här beslutet om hur den ska visas.
///
/// Alla tider är **källtid** — sekunder på inspelningens tidslinje — så att zoomar och klipp
/// sitter kvar på innehållet även när annat klipps bort.
public struct EditProject: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    /// Delarna av inspelningen som är med, i ordning, med hastighet. Klipp = luckor mellan dem.
    public var segments: [ClipSegment]
    public var zooms: [ZoomSegment]
    public var autoZoom: Bool
    /// Zoomgrad för automatiska zoomar (1 = ingen zoom).
    public var zoomScale: Double
    public var background: Background
    /// Marginal runt skärmen, andel av den kortaste sidan (0–0,3).
    public var padding: Double
    /// Hörnradie, andel av skärmytans kortaste sida.
    public var cornerRadius: Double
    /// Skuggans styrka 0–1.
    public var shadow: Double
    public var aspect: Aspect
    /// Hur inspelningen placeras i en bildyta med andra proportioner.
    public var framing: Framing
    public var cursor: CursorStyle
    public var camera: CameraStyle
    public var audio: AudioMix
    public var shortcuts: ShortcutStyle
    public var captions: CaptionStyle
    /// Dolda områden: känslig text som hittats automatiskt, och egna.
    public var masks: [Mask]
    /// Bildlagret: rubrikkort, markeringar, faktarutor, QR-kort.
    public var overlays: [Overlay]
    public var chapters: [Chapter]
    /// Visa en kort kapitelrad i bild när ett kapitel börjar.
    public var showsChapterBanner: Bool
    /// Extra ljud: berättarröst, musik och effekter, lagda på källtider.
    public var audioClips: [AudioClip]
    /// Övergången i varje snitt mellan delar.
    public var transition: Transition
    /// Tona in från svart i början och ut till svart i slutet.
    public var fadeInOut: Bool

    public init() {
        schemaVersion = RecorderKit.formatVersion
        segments = []
        zooms = []
        autoZoom = true
        zoomScale = 2.0
        background = .default
        padding = 0.07
        cornerRadius = 0.018
        shadow = 0.55
        aspect = .wide
        framing = .fit
        cursor = CursorStyle()
        camera = CameraStyle()
        audio = AudioMix()
        shortcuts = ShortcutStyle()
        captions = CaptionStyle()
        masks = []
        overlays = []
        chapters = []
        showsChapterBanner = true
        audioClips = []
        transition = Transition()
        fadeInOut = false
    }

    /// Ett nytt projekt för en inspelning: allt med, i normal hastighet.
    public static func initial(duration: Double) -> EditProject {
        var p = EditProject()
        p.segments = [ClipSegment(start: 0, end: duration)]
        return p
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditProject()
        schemaVersion = c.value(.schemaVersion, d.schemaVersion)
        segments = c.value(.segments, d.segments)
        zooms = c.value(.zooms, d.zooms)
        autoZoom = c.value(.autoZoom, d.autoZoom)
        zoomScale = c.value(.zoomScale, d.zoomScale)
        background = c.value(.background, d.background)
        padding = c.value(.padding, d.padding)
        cornerRadius = c.value(.cornerRadius, d.cornerRadius)
        shadow = c.value(.shadow, d.shadow)
        aspect = c.value(.aspect, d.aspect)
        framing = c.value(.framing, d.framing)
        cursor = c.value(.cursor, d.cursor)
        camera = c.value(.camera, d.camera)
        audio = c.value(.audio, d.audio)
        shortcuts = c.value(.shortcuts, d.shortcuts)
        captions = c.value(.captions, d.captions)
        masks = c.value(.masks, d.masks)
        overlays = c.value(.overlays, d.overlays)
        chapters = c.value(.chapters, d.chapters)
        showsChapterBanner = c.value(.showsChapterBanner, d.showsChapterBanner)
        audioClips = c.value(.audioClips, d.audioClips)
        transition = c.value(.transition, d.transition)
        fadeInOut = c.value(.fadeInOut, d.fadeInOut)
    }

    // MARK: - Delar

    public struct ClipSegment: Codable, Equatable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var start: Double
        public var end: Double
        public var speed: Double
        /// Övergången in i den här delen från delen före; nil = projektets standard.
        public var transitionIn: Transition?

        public init(id: UUID = UUID(), start: Double, end: Double, speed: Double = 1, transitionIn: Transition? = nil) {
            self.id = id; self.start = start; self.end = end; self.speed = speed; self.transitionIn = transitionIn
        }

        public var duration: Double { max(0, end - start) }
        public var outputDuration: Double { duration / max(speed, 0.01) }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.value(.id, UUID())
            start = c.value(.start, 0)
            end = c.value(.end, 0)
            speed = c.value(.speed, 1)
            transitionIn = c.value(.transitionIn, nil)
        }
    }

    public struct ZoomSegment: Codable, Equatable, Hashable, Sendable, Identifiable {
        public var id: UUID
        public var start: Double
        public var end: Double
        public var scale: Double
        /// Mittpunkt i innehållet (0–1, origo uppe till vänster) när zoomen börjar.
        public var centerX: Double
        public var centerY: Double
        /// Följ markören när den lämnar den säkra zonen, eller stå still på mittpunkten.
        public var followsCursor: Bool
        /// Skapad automatiskt. Ändrar användaren den blir den manuell och överlever när de
        /// automatiska skapas om.
        public var isAuto: Bool

        public init(id: UUID = UUID(), start: Double, end: Double, scale: Double,
                    centerX: Double, centerY: Double, followsCursor: Bool = true, isAuto: Bool = false) {
            self.id = id; self.start = start; self.end = end; self.scale = scale
            self.centerX = centerX; self.centerY = centerY
            self.followsCursor = followsCursor; self.isAuto = isAuto
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.value(.id, UUID())
            start = c.value(.start, 0); end = c.value(.end, 0)
            scale = c.value(.scale, 2)
            centerX = c.value(.centerX, 0.5); centerY = c.value(.centerY, 0.5)
            followsCursor = c.value(.followsCursor, true)
            isAuto = c.value(.isAuto, false)
        }
    }

    // MARK: - Utseende

    public struct Background: Codable, Equatable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable, CaseIterable {
            case gradient, solid, blur
        }
        public var kind: Kind
        /// Färger som "#RRGGBB".
        public var colorA: String
        public var colorB: String
        /// Gradientens vinkel i grader.
        public var angle: Double

        public init(kind: Kind, colorA: String, colorB: String, angle: Double = 135) {
            self.kind = kind; self.colorA = colorA; self.colorB = colorB; self.angle = angle
        }

        public static let `default` = Background(kind: .gradient, colorA: "#4F46E5", colorB: "#DB2777")

        /// Förvalda gradienter.
        public static let presets: [Background] = [
            .init(kind: .gradient, colorA: "#4F46E5", colorB: "#DB2777"),
            .init(kind: .gradient, colorA: "#0EA5E9", colorB: "#22C55E"),
            .init(kind: .gradient, colorA: "#F97316", colorB: "#FACC15"),
            .init(kind: .gradient, colorA: "#0F172A", colorB: "#334155"),
            .init(kind: .gradient, colorA: "#7C3AED", colorB: "#06B6D4"),
            .init(kind: .gradient, colorA: "#BE123C", colorB: "#F59E0B"),
            .init(kind: .gradient, colorA: "#065F46", colorB: "#A3E635"),
            .init(kind: .gradient, colorA: "#E2E8F0", colorB: "#94A3B8"),
        ]

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Background.default
            kind = c.value(.kind, d.kind)
            colorA = c.value(.colorA, d.colorA)
            colorB = c.value(.colorB, d.colorB)
            angle = c.value(.angle, d.angle)
        }
    }

    public enum Aspect: String, Codable, Sendable, CaseIterable {
        /// Samma proportioner som inspelningen.
        case source
        case wide, vertical, square, classic

        /// Bredd/höjd, eller nil för källans.
        public var ratio: Double? {
            switch self {
            case .source: nil
            case .wide: 16.0 / 9
            case .vertical: 9.0 / 16
            case .square: 1
            case .classic: 4.0 / 3
            }
        }
    }

    public enum Framing: String, Codable, Sendable, CaseIterable {
        /// Hela inspelningen syns, med bakgrund runt om.
        case fit
        /// Inspelningen fyller bildytan; det som inte får plats beskärs och bilden följer
        /// markören (Reel-läge för stående format).
        case fill
    }

    public struct CursorStyle: Codable, Equatable, Hashable, Sendable {
        public var visible: Bool
        /// Storlek relativt originalet (1 = som på skärmen).
        public var scale: Double
        /// Utjämning 0 (rå rörelse) – 1 (mjukast).
        public var smoothing: Double
        public var hideWhenIdle: Bool
        public var clickEffect: Bool

        public init(visible: Bool = true, scale: Double = 1.6, smoothing: Double = 0.6,
                    hideWhenIdle: Bool = true, clickEffect: Bool = true) {
            self.visible = visible; self.scale = scale; self.smoothing = smoothing
            self.hideWhenIdle = hideWhenIdle; self.clickEffect = clickEffect
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = CursorStyle()
            visible = c.value(.visible, d.visible)
            scale = c.value(.scale, d.scale)
            smoothing = c.value(.smoothing, d.smoothing)
            hideWhenIdle = c.value(.hideWhenIdle, d.hideWhenIdle)
            clickEffect = c.value(.clickEffect, d.clickEffect)
        }
    }

    public struct CameraStyle: Codable, Equatable, Hashable, Sendable {
        public enum Shape: String, Codable, Sendable, CaseIterable { case circle, rounded }
        public enum Corner: String, Codable, Sendable, CaseIterable { case bottomRight, bottomLeft, topRight, topLeft }
        public var visible: Bool
        public var shape: Shape
        /// Bubblans storlek som andel av bildytans höjd.
        public var size: Double
        public var corner: Corner
        public var mirror: Bool

        public init(visible: Bool = true, shape: Shape = .circle, size: Double = 0.24,
                    corner: Corner = .bottomRight, mirror: Bool = true) {
            self.visible = visible; self.shape = shape; self.size = size; self.corner = corner; self.mirror = mirror
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = CameraStyle()
            visible = c.value(.visible, d.visible)
            shape = c.value(.shape, d.shape)
            size = c.value(.size, d.size)
            corner = c.value(.corner, d.corner)
            mirror = c.value(.mirror, d.mirror)
        }
    }

    /// Kortkommandon som spelades in, visade som en bubbla i bilden.
    public struct ShortcutStyle: Codable, Equatable, Hashable, Sendable {
        public enum Position: String, Codable, Sendable, CaseIterable { case bottom, top }
        public var visible: Bool
        public var position: Position
        /// Storlek relativt standard (1).
        public var size: Double

        public init(visible: Bool = true, position: Position = .bottom, size: Double = 1) {
            self.visible = visible; self.position = position; self.size = size
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = ShortcutStyle()
            visible = c.value(.visible, d.visible)
            position = c.value(.position, d.position)
            size = c.value(.size, d.size)
        }
    }

    /// Ett område som döljs, i innehållets koordinater (0–1, origo uppe till vänster) så att
    /// det zoomar med bilden. Följer texten via nyckelrutor; mellan två olika lägen täcks
    /// båda (och allt mellan), så att inget syns medan texten rör sig.
    public struct Mask: Codable, Equatable, Hashable, Sendable, Identifiable {
        public enum Style: String, Codable, Sendable, CaseIterable { case blur, pixelate, solid }
        public struct Keyframe: Codable, Equatable, Hashable, Sendable {
            public var t: Double
            public var rect: Rect
            public init(t: Double, rect: Rect) { self.t = t; self.rect = rect }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                t = c.value(.t, 0); rect = c.value(.rect, .zero)
            }
        }
        public var id: UUID
        public var start: Double
        public var end: Double
        public var keyframes: [Keyframe]
        public var style: Style
        public var kind: SensitiveText.Kind
        /// Ofarlig beskrivning ("a•••••"), aldrig själva texten.
        public var hint: String
        public var enabled: Bool

        public init(id: UUID = UUID(), start: Double, end: Double, keyframes: [Keyframe], style: Style = .blur,
                    kind: SensitiveText.Kind = .manual, hint: String = "", enabled: Bool = true) {
            self.id = id; self.start = start; self.end = end; self.keyframes = keyframes
            self.style = style; self.kind = kind; self.hint = hint; self.enabled = enabled
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.value(.id, UUID())
            start = c.value(.start, 0); end = c.value(.end, 0)
            keyframes = c.value(.keyframes, [])
            style = c.value(.style, .blur)
            kind = c.value(.kind, .manual)
            hint = c.value(.hint, "")
            enabled = c.value(.enabled, true)
        }

        /// Området vid källtiden `t`, eller nil utanför maskens tid.
        public func rect(at t: Double) -> CGRect? {
            guard enabled, t >= start, t <= end, let first = keyframes.first else { return nil }
            guard keyframes.count > 1, t > first.t else { return first.rect.cgRect }
            for (a, b) in zip(keyframes, keyframes.dropFirst()) where t <= b.t {
                return a.rect == b.rect ? a.rect.cgRect : a.rect.cgRect.union(b.rect.cgRect)
            }
            return keyframes.last!.rect.cgRect
        }
    }

    /// Övergången i snitten. Ritas i bilden, så den kräver ingen överlappning av delarna.
    public struct Transition: Codable, Equatable, Hashable, Sendable {
        public enum Kind: String, Codable, Sendable, CaseIterable {
            case none
            /// Tona via svart.
            case dip
            /// Oskärpa och en lätt zoomstöt, som en snabb kamerarörelse.
            case blur
            /// En kort vit blixt.
            case flash
            /// Övertoning: delarna blandas, den förra fortsätter en bit förbi snittet och nästa
            /// börjar en bit före (ur ett andra skärmspår). Filmens längd ändras inte.
            case crossfade
        }
        public var kind: Kind
        /// Hela övergångens längd (s), hälften före och hälften efter snittet.
        public var duration: Double

        public init(kind: Kind = .none, duration: Double = 0.5) { self.kind = kind; self.duration = duration }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = c.value(.kind, .none); duration = c.value(.duration, 0.5)
        }
    }

    /// Undertexter ur transkriptet, inbrända i bilden.
    public struct CaptionStyle: Codable, Equatable, Hashable, Sendable {
        public var visible: Bool
        /// Storlek relativt standard (1).
        public var size: Double

        public init(visible: Bool = true, size: Double = 1) {
            self.visible = visible; self.size = size
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = CaptionStyle()
            visible = c.value(.visible, d.visible)
            size = c.value(.size, d.size)
        }
    }

    public struct AudioMix: Codable, Equatable, Hashable, Sendable {
        public var microphoneVolume: Double
        public var systemVolume: Double
        public var microphoneMuted: Bool
        public var systemMuted: Bool
        /// Sänk datorljudet medan någon talar (kräver transkript).
        public var duckSystem: Bool
        /// Datorljudets nivå under tal, andel av den vanliga.
        public var duckLevel: Double
        /// Använd den röstisolerade mikrofonen (`derived/mic-isolated.caf`) i stället för originalet.
        public var voiceIsolation: Bool

        public init(microphoneVolume: Double = 1, systemVolume: Double = 0.8,
                    microphoneMuted: Bool = false, systemMuted: Bool = false,
                    duckSystem: Bool = false, duckLevel: Double = 0.25, voiceIsolation: Bool = false) {
            self.microphoneVolume = microphoneVolume; self.systemVolume = systemVolume
            self.microphoneMuted = microphoneMuted; self.systemMuted = systemMuted
            self.duckSystem = duckSystem; self.duckLevel = duckLevel
            self.voiceIsolation = voiceIsolation
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = AudioMix()
            microphoneVolume = c.value(.microphoneVolume, d.microphoneVolume)
            systemVolume = c.value(.systemVolume, d.systemVolume)
            microphoneMuted = c.value(.microphoneMuted, d.microphoneMuted)
            systemMuted = c.value(.systemMuted, d.systemMuted)
            duckSystem = c.value(.duckSystem, d.duckSystem)
            duckLevel = c.value(.duckLevel, d.duckLevel)
            voiceIsolation = c.value(.voiceIsolation, d.voiceIsolation)
        }
    }
}

extension RecordingBundle {
    /// Läser `project.json`, eller skapar ett nytt projekt om det saknas eller är oläsbart.
    public func loadProject(duration: Double) -> EditProject {
        if var p = try? BundleJSON.read(EditProject.self, from: projectURL) {
            if p.segments.isEmpty { p.segments = [.init(start: 0, end: duration)] }
            return p
        }
        return .initial(duration: duration)
    }

    public func saveProject(_ project: EditProject) throws {
        try BundleJSON.write(project, to: projectURL)
    }
}
