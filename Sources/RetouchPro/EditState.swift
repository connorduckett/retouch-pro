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
    // Effects
    var vignette: Double = 0
    var grain: Double = 0
    var fade: Double = 0

    var isIdentity: Bool { self == Adjustments() }

    mutating func resetLight() { exposure = 0; contrast = 0; highlights = 0; shadows = 0; whites = 0; blacks = 0 }
    mutating func resetColor() { temperature = 0; tint = 0; vibrance = 0; saturation = 0 }
    mutating func resetDetail() { clarity = 0; sharpness = 0; noiseReduction = 0 }
    mutating func resetEffects() { vignette = 0; grain = 0; fade = 0 }
}

/// One spot-heal stroke. Coordinates are in the *original* photo, normalized by its longest side,
/// with a bottom-left origin (Core Image convention).
struct HealSpot: Equatable, Codable {
    var x: Double
    var y: Double
    var radius: Double
    /// Offset from the spot to the clean area the patch is copied from.
    var dx: Double
    var dy: Double
    /// Linear-light color correction so the patch matches its new surroundings.
    var biasR: Double
    var biasG: Double
    var biasB: Double
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
    case adjust, looks, crop, heal
    var id: String { rawValue }

    var title: String {
        switch self {
        case .adjust: return "Adjust"
        case .looks: return "Looks"
        case .crop: return "Crop"
        case .heal: return "Heal"
        }
    }

    var icon: String {
        switch self {
        case .adjust: return "slider.horizontal.3"
        case .looks: return "camera.filters"
        case .crop: return "crop.rotate"
        case .heal: return "bandage"
        }
    }

    var shortcut: Character {
        switch self {
        case .adjust: return "1"
        case .looks: return "2"
        case .crop: return "3"
        case .heal: return "4"
        }
    }
}
