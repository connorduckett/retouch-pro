import Foundation

enum ShootType: String, CaseIterable, Identifiable {
    case wedding = "Wedding"
    case engagement = "Engagement"
    case portrait = "Portraits"
    case family = "Family"
    case event = "Event"
    case general = "Other"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .wedding: return "heart"
        case .engagement: return "person.2"
        case .portrait: return "person.crop.square"
        case .family: return "figure.2.and.child.holdinghands"
        case .event: return "party.popper"
        case .general: return "camera"
        }
    }
}

/// A guessed category: a name the user can change, and a scoring rule.
struct CategoryRule {
    let key: String
    let name: String
    let score: (PhotoAnalysis) -> Double
}

enum CullingCategories {
    static let otherKey = "other"

    static func rules(for type: ShootType) -> [CategoryRule] {
        func faces(_ a: PhotoAnalysis) -> Int { a.faceCount }
        func L(_ a: PhotoAnalysis, _ names: String...) -> Double { Double(names.map { a.labels[$0] ?? 0 }.max() ?? 0) }
        let dress: (PhotoAnalysis) -> Double = { L($0, "wedding_dress", "gown", "bride", "bridesmaid") }
        let suit: (PhotoAnalysis) -> Double = { L($0, "tuxedo", "suit", "necktie", "bowtie", "groom") }
        let detail: (PhotoAnalysis) -> Double = {
            L($0, "jewelry", "flower_arrangement", "bouquet", "shoes", "wedding_cake", "cake", "candle", "tableware",
              "table", "wine", "sparkling_wine", "decoration", "flower", "food", "dessert", "drinking_glass")
        }
        let party: (PhotoAnalysis) -> Double = {
            L($0, "dancing", "nightclub", "celebration", "concert", "wedding_cake", "sparkling_wine", "drinking_glass", "bar")
        }

        switch type {
        case .wedding:
            return [
                CategoryRule(key: "details", name: "Details & Décor") { a in
                    (faces(a) == 0 ? 0.6 : 0) + detail(a) * (faces(a) <= 1 ? 1 : 0.4)
                },
                CategoryRule(key: "ready", name: "Getting Ready") { a in
                    (a.timeline < 0.3 ? 0.55 : a.timeline < 0.4 ? 0.2 : -0.3) + L(a, "interior_room") * 0.4
                        + (1...4 ~= faces(a) ? 0.2 : 0) - L(a, "outdoor") * 0.3
                },
                CategoryRule(key: "bride", name: "Bride") { a in
                    (faces(a) == 1 ? 0.45 : -0.4) + dress(a) * 1.1 - suit(a) * 0.9
                },
                CategoryRule(key: "groom", name: "Groom") { a in
                    (faces(a) == 1 ? 0.45 : -0.4) + suit(a) * 1.1 - dress(a) * 0.9
                },
                CategoryRule(key: "bridesmaids", name: "Bridesmaids") { a in
                    (faces(a) >= 3 ? 0.35 : -0.4) + L(a, "bridesmaid", "gown", "bouquet", "wedding_dress") * 1.0 - suit(a) * 0.8
                },
                CategoryRule(key: "groomsmen", name: "Groomsmen") { a in
                    (faces(a) >= 3 ? 0.35 : -0.4) + suit(a) * 1.1 - dress(a) * 0.8
                },
                CategoryRule(key: "ceremony", name: "Ceremony") { a in
                    L(a, "ceremony") * 0.9 + L(a, "crowd") * 0.7 + (0.3...0.65 ~= a.timeline ? 0.3 : -0.2)
                        + (faces(a) >= 5 ? 0.15 : 0)
                },
                CategoryRule(key: "couple", name: "Couple Portraits") { a in
                    (faces(a) == 2 ? 0.55 : -0.3) + min(dress(a), suit(a)) * 0.8 + L(a, "wedding") * 0.3
                },
                CategoryRule(key: "family", name: "Family Formals") { a in
                    (faces(a) >= 4 ? 0.4 : -0.4) + (0.35...0.75 ~= a.timeline ? 0.2 : 0)
                        + (L(a, "child") > 0.2 && L(a, "adult") > 0.2 ? 0.2 : 0) - L(a, "crowd") * 0.4
                },
                CategoryRule(key: "reception", name: "Reception") { a in
                    party(a) * 1.1 + (a.timeline > 0.65 ? 0.4 : -0.2) + (a.brightness < 0.3 ? 0.15 : 0)
                },
            ]
        case .engagement:
            return [
                CategoryRule(key: "couple", name: "Couple") { a in faces(a) == 2 ? 0.8 : faces(a) > 2 ? 0.2 : -0.3 },
                CategoryRule(key: "individual", name: "Individual Portraits") { a in faces(a) == 1 ? 0.75 : -0.3 },
                CategoryRule(key: "details", name: "Details (Ring & Hands)") { a in
                    (faces(a) == 0 ? 0.55 : 0) + L(a, "jewelry", "hand", "flower", "bouquet") * 0.8
                },
                CategoryRule(key: "scenery", name: "Scenery & Wide Shots") { a in
                    (a.faces.allSatisfy { $0.size < 0.05 } ? 0.4 : -0.3) + L(a, "outdoor", "sky", "beach", "forest", "landscape") * 0.4
                },
            ]
        case .portrait:
            return [
                CategoryRule(key: "closeup", name: "Close-ups") { a in (a.faces.map(\.size).max() ?? 0) > 0.22 ? 0.8 : -0.2 },
                CategoryRule(key: "half", name: "Half-Length") { a in
                    let m = a.faces.map(\.size).max() ?? 0
                    return (0.09...0.22 ~= m) ? 0.7 : -0.2
                },
                CategoryRule(key: "full", name: "Full-Length") { a in
                    let m = a.faces.map(\.size).max() ?? 0
                    return (0.01..<0.09 ~= m) ? 0.65 : -0.2
                },
                CategoryRule(key: "groups", name: "With Others") { a in faces(a) >= 2 ? 0.7 : -0.3 },
                CategoryRule(key: "details", name: "Details") { a in faces(a) == 0 ? 0.6 : -0.3 },
            ]
        case .family:
            return [
                CategoryRule(key: "whole", name: "Whole Family") { a in faces(a) >= 4 ? 0.8 : faces(a) == 3 ? 0.4 : -0.3 },
                CategoryRule(key: "kids", name: "Kids") { a in
                    (1...2 ~= faces(a) ? 0.3 : -0.2) + L(a, "child", "baby", "teen") * 0.8 - L(a, "adult") * 0.3
                },
                CategoryRule(key: "parents", name: "Parents") { a in
                    (faces(a) == 2 ? 0.45 : -0.3) + L(a, "adult") * 0.4 - L(a, "child", "baby") * 0.6
                },
                CategoryRule(key: "individuals", name: "Individuals") { a in faces(a) == 1 ? 0.5 : -0.3 },
                CategoryRule(key: "details", name: "Details & Scenery") { a in faces(a) == 0 ? 0.6 : -0.3 },
            ]
        case .event:
            return [
                CategoryRule(key: "stage", name: "Speeches & Stage") { a in L(a, "concert", "crowd", "ceremony", "stage") * 1.0 },
                CategoryRule(key: "groups", name: "Groups") { a in faces(a) >= 3 ? 0.65 : -0.3 },
                CategoryRule(key: "people", name: "People & Candids") { a in 1...2 ~= faces(a) ? 0.6 : -0.3 },
                CategoryRule(key: "food", name: "Food & Drinks") { a in
                    L(a, "food", "dessert", "cake", "wine", "drinking_glass", "tableware", "sparkling_wine") * 1.1
                },
                CategoryRule(key: "venue", name: "Venue & Décor") { a in
                    (faces(a) == 0 ? 0.5 : -0.2) + L(a, "decoration", "interior_room", "building", "flower_arrangement") * 0.5
                },
            ]
        case .general:
            return []   // grouped by moment instead
        }
    }

    struct Category: Identifiable, Equatable {
        var id = UUID()
        var key: String
        var name: String
        var photoIDs: [UUID]
    }

    /// Sorts analyzed photos (already timeline-ordered) into named categories.
    static func categorize(_ photos: [PhotoAnalysis], type: ShootType) -> [Category] {
        let rules = rules(for: type)
        if rules.isEmpty { return byMoment(photos) }

        // Score every photo for every category.
        var scores: [[Double]] = photos.map { p in rules.map { $0.score(p) } }
        // Photos in the same moment tend to belong together: blend in the moment's average.
        let moments = Dictionary(grouping: photos.indices, by: { photos[$0].moment })
        for (_, idx) in moments where idx.count > 1 {
            var avg = [Double](repeating: 0, count: rules.count)
            for i in idx { for r in rules.indices { avg[r] += scores[i][r] } }
            for r in avg.indices { avg[r] /= Double(idx.count) }
            for i in idx { for r in rules.indices { scores[i][r] = scores[i][r] * 0.7 + avg[r] * 0.3 } }
        }

        var buckets: [String: [UUID]] = [:]
        for (i, p) in photos.enumerated() {
            let best = scores[i].indices.max { scores[i][$0] < scores[i][$1] }
            if let best, scores[i][best] >= 0.45 {
                buckets[rules[best].key, default: []].append(p.id)
            } else {
                buckets[otherKey, default: []].append(p.id)
            }
        }
        var result: [Category] = rules.compactMap { r in
            guard let ids = buckets[r.key], !ids.isEmpty else { return nil }
            return Category(key: r.key, name: r.name, photoIDs: ids)
        }
        if let other = buckets[otherKey], !other.isEmpty {
            result.append(Category(key: otherKey, name: type == .wedding ? "Candids & Other" : "Other", photoIDs: other))
        }
        return result
    }

    /// For "Other" shoots: one category per moment, named after what's in it.
    private static func byMoment(_ photos: [PhotoAnalysis]) -> [Category] {
        let grouped = Dictionary(grouping: photos, by: \.moment).sorted { $0.key < $1.key }
        let generic: Set<String> = ["people", "adult", "outdoor", "structure", "material", "textile", "art", "document",
                                    "screenshot", "clothing", "land", "plant", "sky", "decoration"]
        var used: [String: Int] = [:]
        return grouped.enumerated().map { n, entry in
            var totals: [String: Float] = [:]
            for p in entry.value { for (k, v) in p.labels where !generic.contains(k) { totals[k, default: 0] += v } }
            var name = totals.max { $0.value < $1.value }.map { $0.key.replacingOccurrences(of: "_", with: " ").capitalized }
                ?? "Moment \(n + 1)"
            used[name, default: 0] += 1
            if used[name]! > 1 { name += " \(used[name]!)" }
            return Category(key: "moment\(n)", name: name, photoIDs: entry.value.map(\.id))
        }
    }
}
