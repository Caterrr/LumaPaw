import Foundation

enum DogBreed: String, Codable, CaseIterable {
    case shiba, beagle, dalmatian
    init(from decoder:Decoder)throws {
        let value=try decoder.singleValueContainer().decode(String.self)
        // Migrate a removed companion in an existing saved photo profile.
        if value=="chihuahua" {self = .beagle;return}
        guard let breed=Self(rawValue:value) else {throw DecodingError.dataCorrupted(.init(codingPath:decoder.codingPath,debugDescription:"Unknown dog breed"))}
        self=breed
    }
    static let menuOrder: [DogBreed] = [.dalmatian, .shiba, .beagle]
    var title: String {
        switch self {
        case .shiba: return "Medium"
        case .beagle: return "Small"
        case .dalmatian: return "Large"
        }
    }
    /// Neutral baked height, used only to fit an estimated on-screen size.
    var referenceHeight:Float {switch self{case .shiba:return 3.06;case .beagle:return 2.31;case .dalmatian:return 3.12}}
    var profileFilename: String { self == .shiba ? "profile.json" : "\(rawValue)_profile.json" }
    var photoFilename: String { self == .shiba ? "photo.png" : "\(rawValue)_photo.png" }
    var rigFilename: String { self == .shiba ? "parametric_rig.json" : "\(rawValue)_rig.json" }
    var parameters: MorphologyParameters { MorphologyParameters(breed: self == .shiba ? nil : self) }
    var motionScale: Float {
        switch self {case .shiba: return 1; case .beagle: return 0.70; case .dalmatian: return 1.10}
    }
    var profileNote: String {
        switch self {
        case .shiba: return "Use a clear full-body side photo, or fine-tune the proportions yourself."
        case .beagle: return "A tricolour beagle puppy with floppy ears and a smaller stride."
        case .dalmatian: return "A long-legged Dalmatian with its original black-and-white spotted coat."
        }
    }
    var palette: DogCoatPalette {
        if self != .shiba {
            // Neutral tints preserve the supplied UV coat; sliders can tint each region.
            let white=PhotoRGB(red:1,green:1,blue:1)
            return DogCoatPalette(body:white,head:white,legs:white,tail:white,accent:white)
        }
        return .amber
    }
}
