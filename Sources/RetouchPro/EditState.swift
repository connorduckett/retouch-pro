import CoreGraphics
import Foundation

/// Slider values. Every value is on a friendly -100…100 (or 0…100) scale and 0 means "untouched".
struct Adjustments: Equatable, Codable {
    // Light
    var exposure: Double = 0
    var contrast: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var whites: Double = 0
    var blacks: Double = 0
    // Color
    var temperature: Double = 0
    var tint: Double = 0
    var vibrance: Double = 0
    var saturation: Double = 0
    // Detail
    var clarity: Double = 0
    var sharpness: Double = 0
    var noiseReduction: Double = 0
    // Retouch (0…100)
    /// Lifts harsh, hard-edged shadows (under eyes, hats, trees) and warms them back to match.
    var shadowRemoval: Double = 0
    /// Tames bright, blown patches of dappled sunlight.
    var sunSpotRemoval: Double = 0
    /// Fades small dark marks on skin: sun spots, age spots, blemishes.
    var skinSpotRemoval: Double = 0
    // Effects
    var vignette: Double = 0
    var grain: Double = 0
    var fade: Double = 0

    var isIdentity: Bool { self == Adjustments() }

    mutating func resetLight() { exposure = 0; contrast = 0; highlights = 0; shadows = 0; whites = 0; blacks = 0 }
    mutating func resetColor() { temperature = 0; tint = 0; vibrance = 0; saturation = 0 }
    mutating func resetDetail() { clarity = 0; sharpness = 0; noiseReduction = 0 }
    mutating func resetRetouch() { shadowRemoval = 0; sunSpotRemoval = 0; skinSpotRemoval = 0 }
    mutating func resetEffects() { vignette = 0; grain = 0; fade = 0 }
}

/// One heal click or brush stroke. Coordinates are in the *original* photo, normalized by its
/// longest side, with a bottom-left origin (Core Image convention).
struct HealSpot: Equatable, Codable {
    /// Stroke centerline as [x, y] pairs (one pair for a click).
    var points: [[Double]]
    var radius: Double
    /// Offset from the healed area to the clean area the texture is copied from.
    var dx: Double
    var dy: Double
    /// Bounding box [x, y, w, h] of the healed region.
    var box: [Double]
    /// Smooth color-correction field (linear RGB triples) that blends the patch into its surroundings.
    var gridWidth: Int
    var gridHeight: Int
    var grid: [Float]
}

// MARK: - Layers

struct RGBAColor: Equatable, Codable {
    var r: Double, g: Double, b: Double, a: Double = 1
    static let white = RGBAColor(r: 1, g: 1, b: 1)
    static let black = RGBAColor(r: 0, g: 0, b: 0)
    static let charcoal = RGBAColor(r: 0x6A / 255.0, g: 0x6A / 255.0, b: 0x6A / 255.0)
    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
}

enum LayerKind: String, Codable {
    case adjustment, text, shape, path
    var icon: String {
        switch self {
        case .adjustment: return "slider.horizontal.below.square.filled.and.square"
        case .text: return "textformat"
        case .shape: return "square.on.circle"
        case .path: return "scribble.variable"
        }
    }
}

enum ShapeKind: String, Codable, CaseIterable, Identifiable {
    case rectangle = "Rectangle", ellipse = "Ellipse", line = "Line", triangle = "Triangle", star = "Star"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .triangle: return "triangle"
        case .star: return "star"
        }
    }
}

enum LayerBlendMode: String, Codable, CaseIterable, Identifiable {
    case normal = "Normal", multiply = "Multiply", screen = "Screen", overlay = "Overlay", softLight = "Soft Light"
    var id: String { rawValue }
    var filterName: String? {
        switch self {
        case .normal: return nil
        case .multiply: return "CIMultiplyBlendMode"
        case .screen: return "CIScreenBlendMode"
        case .overlay: return "CIOverlayBlendMode"
        case .softLight: return "CISoftLightBlendMode"
        }
    }
}

enum TextAlign: String, Codable, CaseIterable, Identifiable {
    case left, center, right
    var id: String { rawValue }
    var icon: String { "text.align\(rawValue)" }
}

enum MaskMode: String, Codable, CaseIterable, Identifiable {
    case none = "Whole Photo", brush = "Brush", linear = "Gradient", radial = "Radial"
    // Automatic (AI) selections
    case people = "People", sky = "Sky", subject = "Subject", background = "Background"
    var id: String { rawValue }

    static let manual: [MaskMode] = [.none, .brush, .linear, .radial]
    static let automatic: [MaskMode] = [.people, .sky, .subject, .background]
    var isAutomatic: Bool { MaskMode.automatic.contains(self) }
    /// Automatic selections made of separate things you can click to include or exclude.
    var hasInstances: Bool { self == .people || self == .subject }

    var icon: String {
        switch self {
        case .none: return "rectangle"
        case .brush: return "paintbrush.pointed"
        case .linear: return "square.bottomhalf.filled"
        case .radial: return "circle.dashed"
        case .people: return "person.2"
        case .sky: return "cloud.sun"
        case .subject: return "viewfinder"
        case .background: return "mountain.2"
        }
    }

    var autoDescription: String {
        switch self {
        case .people: return "Finds every person in the photo. Click a person to leave them out or add them back."
        case .sky: return "Finds the sky, including around the horizon and through gaps."
        case .subject: return "Finds the main subjects — people, pets and objects. Click one to leave it out or add it back."
        case .background: return "Everything except the people and main subjects."
        default: return ""
        }
    }
}

/// A brush stroke on a layer mask, in source-photo coordinates (normalized by the longest side, y-up).
struct MaskStroke: Equatable, Codable {
    var points: [[Double]]
    var radius: Double
    var erase: Bool
}

struct LayerMask: Equatable, Codable {
    var mode: MaskMode = .none
    var strokes: [MaskStroke] = []
    /// Edge softness 0…100.
    var feather: Double = 40
    var inverted = false
    /// Linear gradient: fully applied at `start`, fades out by `end`. Source-normalized, y-up.
    var start: [Double] = [0.5, 0.2]
    var end: [Double] = [0.5, 0.45]
    /// Radial: ellipse center and radii (source-normalized).
    var center: [Double] = [0.5, 0.33]
    var radiusX: Double = 0.18
    var radiusY: Double = 0.18
    /// Automatic selection result: grayscale PNG covering the original photo (top row = top of photo).
    var autoMaskPNG: Data? = nil
    /// Which detected people/subjects are included (indexes), or empty for all of them.
    var autoExcluded: [Int] = []
    var autoInstanceCount: Int = 0
    /// Sky only: how far the selection reaches into clouds and haze (0…100).
    var autoSensitivity: Double = 50
}

/// A layer stacked on top of the photo. Text, shape and path geometry is stored relative to the
/// photo's frame (0…1, top-left origin), so it re-flows and scales when you crop or export at any size.
struct Layer: Identifiable, Equatable, Codable {
    var id = UUID()
    var name: String
    var kind: LayerKind
    var visible = true
    var opacity: Double = 100
    var blend: LayerBlendMode = .normal
    var mask = LayerMask()

    // Adjustment layer
    var adjustments = Adjustments()

    // Text & shape box (normalized to the frame, top-left origin)
    var frame = CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.2)

    // Text
    var text = "Your text here"
    var fontFamily = "Didot"
    var fontWeight: Double = 5          // NSFontManager weight 1…12 (5 = regular)
    var italic = false
    /// Font size as a % of the frame's shorter side.
    var fontSize: Double = 7
    /// Shrink text so it always fits inside its box.
    var autoFit = true
    var textColor = RGBAColor.white
    var alignment: TextAlign = .center
    var letterSpacing: Double = 0       // % of font size
    var lineSpacing: Double = 0         // % of font size
    var uppercase = false
    var textShadow = true

    // Shape & path
    var shapeKind: ShapeKind = .rectangle
    var fillEnabled = true
    var fillColor = RGBAColor(r: 1, g: 1, b: 1, a: 0.85)
    var strokeEnabled = false
    var strokeColor = RGBAColor.charcoal
    /// Stroke width as a % of the frame's shorter side.
    var strokeWidth: Double = 0.6
    /// Corner radius as a % of the frame's shorter side.
    var cornerRadius: Double = 0
    /// Pen-tool points (frame-normalized, top-left origin).
    var pathPoints: [[Double]] = []
    var pathClosed = false
    var pathSmooth = true

    var isContent: Bool { kind != .adjustment }
}

struct EditState: Equatable, Codable {
    var adjustments = Adjustments()
    var lookID: String? = nil
    var lookAmount: Double = 100

    /// Counter-clockwise quarter turns.
    var quarterTurns: Int = 0
    var flipHorizontal = false
    var flipVertical = false
    /// Degrees, positive = clockwise.
    var straighten: Double = 0
    /// Normalized crop rect (0…1) in the rotated/straightened frame, bottom-left origin.
    var crop = CGRect(x: 0, y: 0, width: 1, height: 1)

    var heals: [HealSpot] = []
    /// Bottom to top.
    var layers: [Layer] = []

    var isIdentity: Bool { self == EditState() }
    static let fullCrop = CGRect(x: 0, y: 0, width: 1, height: 1)
}

/// A one-click "look" (preset). It layers on top of the user's own slider settings.
struct Look: Identifiable {
    let id: String
    let name: String
    var adjustments: Adjustments? = nil
    var filterName: String? = nil

    static let all: [Look] = {
        func adj(_ build: (inout Adjustments) -> Void) -> Adjustments {
            var a = Adjustments(); build(&a); return a
        }
        return [
            Look(id: "vivid", name: "Vivid", adjustments: adj { $0.vibrance = 35; $0.saturation = 12; $0.contrast = 18 }),
            Look(id: "warm", name: "Warm", adjustments: adj { $0.temperature = 30; $0.vibrance = 10 }),
            Look(id: "cool", name: "Cool", adjustments: adj { $0.temperature = -30; $0.tint = -4 }),
            Look(id: "golden", name: "Golden Hour", adjustments: adj {
                $0.temperature = 42; $0.tint = 10; $0.highlights = -25; $0.shadows = 20; $0.saturation = 10; $0.vignette = -15
            }),
            Look(id: "portrait", name: "Soft Portrait", adjustments: adj {
                $0.clarity = -30; $0.highlights = -20; $0.temperature = 8; $0.vibrance = -5; $0.fade = 10
            }),
            Look(id: "airy", name: "Light & Airy", adjustments: adj {
                $0.exposure = 18; $0.shadows = 35; $0.contrast = -18; $0.saturation = -12; $0.temperature = 6; $0.fade = 15
            }),
            Look(id: "matte", name: "Matte", adjustments: adj { $0.fade = 55; $0.contrast = -12; $0.saturation = -10 }),
            Look(id: "moody", name: "Moody", adjustments: adj {
                $0.exposure = -12; $0.contrast = 25; $0.saturation = -28; $0.shadows = -15; $0.vignette = -40; $0.temperature = -6
            }),
            Look(id: "film", name: "Film", adjustments: adj {
                $0.fade = 30; $0.grain = 30; $0.temperature = 10; $0.saturation = -8; $0.contrast = 8
            }),
            Look(id: "mono", name: "Mono", filterName: "CIPhotoEffectMono"),
            Look(id: "noir", name: "Noir", filterName: "CIPhotoEffectNoir"),
            Look(id: "silver", name: "Silver", filterName: "CIPhotoEffectTonal"),
            Look(id: "chrome", name: "Chrome", filterName: "CIPhotoEffectChrome"),
            Look(id: "instant", name: "Instant", filterName: "CIPhotoEffectInstant"),
            Look(id: "fadefx", name: "Faded", filterName: "CIPhotoEffectFade"),
            Look(id: "transfer", name: "Transfer", filterName: "CIPhotoEffectTransfer"),
        ]
    }()

    static func find(_ id: String?) -> Look? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}

enum AspectRatio: String, CaseIterable, Identifiable {
    case free = "Free"
    case original = "Original"
    case square = "1:1"
    case r4x5 = "4:5"
    case r2x3 = "2:3"
    case r5x7 = "5:7"
    case r8x10 = "8:10"
    case r16x9 = "16:9"

    var id: String { rawValue }

    /// Width ÷ height in portrait orientation (or nil for free/original).
    var portraitValue: Double? {
        switch self {
        case .free, .original: return nil
        case .square: return 1
        case .r4x5: return 4.0 / 5.0
        case .r2x3: return 2.0 / 3.0
        case .r5x7: return 5.0 / 7.0
        case .r8x10: return 8.0 / 10.0
        case .r16x9: return 9.0 / 16.0
        }
    }
}

enum Tool: String, CaseIterable, Identifiable {
    case adjust, looks, crop, heal, layers
    var id: String { rawValue }

    var title: String {
        switch self {
        case .adjust: return "Adjust"
        case .looks: return "Looks"
        case .crop: return "Crop"
        case .heal: return "Heal"
        case .layers: return "Layers"
        }
    }

    var icon: String {
        switch self {
        case .adjust: return "slider.horizontal.3"
        case .looks: return "camera.filters"
        case .crop: return "crop.rotate"
        case .heal: return "bandage"
        case .layers: return "square.3.layers.3d"
        }
    }

    var shortcut: Character {
        switch self {
        case .adjust: return "1"
        case .looks: return "2"
        case .crop: return "3"
        case .heal: return "4"
        case .layers: return "5"
        }
    }
}
