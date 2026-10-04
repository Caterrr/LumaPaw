import Foundation
import Vision
import CoreImage
import CoreGraphics
import ImageIO

/// Normalized sRGB appearance values, not linear-light shader colors.
struct PhotoRGB: Codable, Equatable {
    var red: Float
    var green: Float
    var blue: Float
}

struct DogCoatPalette: Codable, Equatable {
    var body: PhotoRGB
    var head: PhotoRGB
    var legs: PhotoRGB
    var tail: PhotoRGB
    var accent: PhotoRGB
    var fromPhoto: Bool? = nil

    static let amber = DogCoatPalette(
        body: PhotoRGB(red: 0.86, green: 0.61, blue: 0.30),
        head: PhotoRGB(red: 0.90, green: 0.68, blue: 0.39),
        legs: PhotoRGB(red: 0.94, green: 0.85, blue: 0.66),
        tail: PhotoRGB(red: 0.86, green: 0.65, blue: 0.37),
        accent: PhotoRGB(red: 1.0, green: 0.92, blue: 0.75))
}

struct DogPersonalization: Codable {
    var morphology: MorphologyParameters
    var palette: DogCoatPalette
    var name: String
    var photoFilename: String
    /// Confidence in automatic shape assessment, not a calibrated probability.
    var confidence: Float
    var note: String
    var warnings: [String]
    var measuredProportions: Bool
    var sizeEstimate: PhotoSizeEstimate? = nil
    var coatSamples: [PhotoCoatSample]? = nil
}

enum PhotoPersonalizationError: LocalizedError {
    case unreadableImage, noDog, multipleDogs, nonDog, noForeground, unsupportedSystem
    var errorDescription: String? {
        switch self {
        case .unreadableImage: return "Could not read this photo. Choose JPEG, PNG, HEIC or TIFF."
        case .noDog: return "No dog confidently detected. Try a clearer photo."
        case .multipleDogs: return "Choose a photo with just one dog."
        case .nonDog: return "Could not confirm a dog in this image. Try a clearer photo."
        case .noForeground: return "Coat colours could not be isolated. Try a clear full-body photo with a simple background."
        case .unsupportedSystem: return "Photo analysis requires macOS 14 or later."
        }
    }
}

/// Kept independent of Vision observation objects so proportion geometry can be
/// validated with known standing, sitting, cropped, and front-facing poses.
struct PhotoPoseLandmark {
    var x: Double
    var y: Double
    var confidence: Float
}
struct PhotoMorphologyAssessment {
    var morphology: MorphologyParameters
    var measured: Bool
    var confidence: Float
    var note: String
}

/// On-device analysis only. Invoke from a background queue; no source image is
/// uploaded, copied, or embedded in the returned profile.
enum PhotoPersonalizer {
    private struct Sample { var rgb: SIMD3<Double>; var point: CGPoint }
    private struct Cluster { var rgb: SIMD3<Double>; var weight: Double }

    static func analyze(url: URL, base: MorphologyParameters = MorphologyParameters()) throws -> DogPersonalization {
        guard #available(macOS 14.0, *) else { throw PhotoPersonalizationError.unsupportedSystem }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1200
              ] as CFDictionary) else { throw PhotoPersonalizationError.unreadableImage }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        let animals = VNRecognizeAnimalsRequest()
        let classifier = VNClassifyImageRequest()
        try handler.perform([animals, classifier])
        let dogs = (animals.results ?? []).filter { object in
            object.labels.contains { $0.identifier == VNAnimalIdentifier.dog.rawValue && $0.confidence >= 0.35 }
        }
        if dogs.count > 1 { throw PhotoPersonalizationError.multipleDogs }
        guard let dog = dogs.first else {
            if !(animals.results ?? []).isEmpty { throw PhotoPersonalizationError.nonDog }
            throw PhotoPersonalizationError.noDog
        }
        let box = dog.boundingBox
        let cropClassifier = VNClassifyImageRequest()
        let cropRect = CGRect(x: box.minX * CGFloat(image.width), y: (1 - box.maxY) * CGFloat(image.height),
                              width: box.width * CGFloat(image.width), height: box.height * CGFloat(image.height))
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if let crop = image.cropping(to: cropRect) {
            try VNImageRequestHandler(cgImage: crop, orientation: .up).perform([cropClassifier])
        }
        var labels: [String: Float] = [:]
        for label in (classifier.results ?? []) + (cropClassifier.results ?? []) {
            labels[label.identifier] = max(labels[label.identifier] ?? 0, label.confidence)
        }
        // The animal detector can mistake other mammals for dogs. A separate
        // image classifier must corroborate it before the existing pet changes.
        guard (labels["dog"] ?? 0) >= 0.12 else { throw PhotoPersonalizationError.nonDog }

        let foreground = VNGenerateForegroundInstanceMaskRequest()
        let poseRequest = VNDetectAnimalBodyPoseRequest()
        try handler.perform([foreground, poseRequest])
        guard let instance = foreground.results?.first,
              let instanceID = bestInstance(instance, dogBox: box) else { throw PhotoPersonalizationError.noForeground }
        let scaledMask = try instance.generateScaledMaskForImage(forInstances: IndexSet(integer: instanceID), from: handler)
        let mask = try maskValues(scaledMask, width: image.width, height: image.height)
        let pixels = try rgbaPixels(image)
        var samples: [Sample] = []
        var rejectedLeash = false
        let hasLeash = (labels["leash"] ?? 0) >= 0.25
        for y in stride(from: 0, to: image.height, by: 3) {
            for x in stride(from: 0, to: image.width, by: 3) {
                let index = y * image.width + x
                let position=CGPoint(x:(Double(x)+0.5)/Double(image.width),y:1-(Double(y)+0.5)/Double(image.height))
                guard box.insetBy(dx:-0.01,dy:-0.01).contains(position),mask[index] >= 0.88 else { continue }
                // Ignore antialiased mask edges where grass/walls bleed into fur.
                let neighbors=[index-2,index+2,index-image.width*2,index+image.width*2]
                guard neighbors.allSatisfy({$0>=0 && $0<mask.count && mask[$0]>=0.65}) else{continue}
                let offset = index * 4
                let rgb = SIMD3(Double(pixels[offset]) / 255, Double(pixels[offset + 1]) / 255, Double(pixels[offset + 2]) / 255)
                if (hasLeash && rgb.x > 0.50 && rgb.y < 0.27 && rgb.z < 0.30 && rgb.x > rgb.y * 2.8) || isAccessoryColor(rgb) {
                    rejectedLeash = true; continue
                }
                samples.append(Sample(rgb: rgb, point: CGPoint(x: (Double(x) + 0.5) / Double(image.width),
                                                             y: 1 - (Double(y) + 0.5) / Double(image.height))))
            }
        }
        guard samples.count >= 100 else { throw PhotoPersonalizationError.noForeground }
        let overall = cluster(samples.map(\.rgb))
        guard let main = overall.first else { throw PhotoPersonalizationError.noForeground }
        let pose = bestPose(poseRequest.results ?? [], dogBox: box)
        let landmarks = pose.map(poseLandmarks) ?? [:]
        let regional = regionalColors(samples, landmarks: landmarks, box: box, width: image.width, height: image.height)
        let fallback = color(main.rgb)
        let light = overall.filter { $0.weight >= 0.07 }.max { luminance($0.rgb) < luminance($1.rgb) } ?? main
        let palette = DogCoatPalette(body: regional["body"] ?? fallback,
                                     head: regional["head"] ?? fallback,
                                     legs: regional["legs"] ?? fallback,
                                     tail: regional["tail"] ?? fallback,
                                     accent: color(light.rgb), fromPhoto: true)
        let shape = assessMorphology(landmarks: landmarks, imageWidth: image.width, imageHeight: image.height)
        var warnings = ["Coat colours are estimated from the photo; lighting, shadows and accessories can affect them."]
        if regional.count < 4 { warnings.append("Unclear regions use the main coat colour.") }
        if rejectedLeash { warnings.append("Strongly coloured accessory or background pixels were excluded.") }
        let size = assessSize(labels:labels)
        let previousBreed=base.breed ?? .shiba
        let matchedBreed=size.matchingBreed(fallback:previousBreed)
        // Manual edits belong to their original rig; do not carry a stretched
        // large dog's proportions into a newly selected small-dog silhouette.
        let fitBase=matchedBreed == previousBreed ? base:matchedBreed.parameters
        var fitted=shape.measured ? shape.morphology:fitBase
        fitted.breed=matchedBreed == .shiba ? nil:matchedBreed
        fitted.bodyWidth=fitBase.bodyWidth;fitted.overallScale=fitBase.overallScale
        if let height=size.targetHeight {fitted.overallScale=height/matchedBreed.referenceHeight}
        warnings.append("Size is an appearance estimate from breed cues, not a physical measurement. Use Size to refine it.")
        if !shape.measured { warnings.append("Coat colours applied. Use a full side view or adjust proportions manually.") }
        let filename = url.lastPathComponent
        return DogPersonalization(morphology: fitted.clamped(), palette: palette,
                                  name: url.deletingPathExtension().lastPathComponent, photoFilename: filename,
                                  confidence: shape.confidence, note: size.summary + "\nModel: " + matchedBreed.title + " · approximate fit" + "\n" + (shape.measured ? "Side-view proportions fitted.":"Use a full side view to refine proportions."),
                                  warnings: warnings, measuredProportions: shape.measured, sizeEstimate:size, coatSamples:summarizeCoat(overall.filter{$0.weight>=0.07}.prefix(4).map{PhotoCoatSample(color:color($0.rgb),share:Float($0.weight))}))
    }

    /// Aspect-correct landmark ratios, never photo bounding-box scale or a breed
    /// label. Strict side/standing gates intentionally reject ambiguous photos.
    static func assessMorphology(landmarks: [String: PhotoPoseLandmark], imageWidth: Int, imageHeight: Int) -> PhotoMorphologyAssessment {
        let fallback = PhotoMorphologyAssessment(morphology: MorphologyParameters(), measured: false, confidence: 0,
            note: "Side-view proportions were unclear. Default proportions kept; adjust manually.")
        guard imageWidth > 0, imageHeight > 0 else { return fallback }
        func point(_ name: String, minimum: Float = 0.55) -> SIMD2<Double>? {
            guard let p = landmarks[name], p.confidence >= minimum, p.x.isFinite, p.y.isFinite,
                  p.x > 0.008, p.x < 0.992, p.y > 0.008, p.y < 0.992 else { return nil }
            return SIMD2(p.x * Double(imageWidth), p.y * Double(imageHeight))
        }
        func length(_ p: SIMD2<Double>) -> Double { sqrt(p.x * p.x + p.y * p.y) }
        func mean(_ values: [SIMD2<Double>]) -> SIMD2<Double>? {
            guard !values.isEmpty else { return nil }
            return values.reduce(SIMD2<Double>(repeating: 0), +) / Double(values.count)
        }
        guard let neck = point("neck", minimum: 0.35), let tail = point("tailBase"), let nose = point("nose"),
              let front = mean(["leftFrontPaw", "rightFrontPaw"].compactMap { point($0) }),
              let back = mean(["leftBackPaw", "rightBackPaw"].compactMap { point($0) }) else { return fallback }
        let trunk = length(neck - tail)
        guard trunk > 30 else { return fallback }
        let direction = neck.x > tail.x ? 1.0 : -1.0
        let ground = (front.y + back.y) * 0.5
        let standingHeight = (neck.y + tail.y) * 0.5 - ground
        // A long horizontal spine, separated grounded front/back paws, and a
        // forward-facing head distinguish a standing side view from sitting or
        // foreshortened frontal views. No absolute real-world size is inferred.
        guard abs(neck.x - tail.x) / trunk > 0.86,
              standingHeight > trunk * 0.35, standingHeight < trunk * 1.55,
              abs(front.y - back.y) < standingHeight * 0.24,
              (front.x - back.x) * direction > trunk * 0.48,
              abs(front.x - neck.x) < trunk * 0.40,
              abs(back.x - tail.x) < trunk * 0.40,
              (nose.x - neck.x) * direction > trunk * 0.06 else { return fallback }
        let frontMid = ["leftFrontElbow", "rightFrontElbow", "leftFrontKnee", "rightFrontKnee"].compactMap { point($0, minimum: 0.45) }
        let backMid = ["leftBackElbow", "rightBackElbow", "leftBackKnee", "rightBackKnee"].compactMap { point($0, minimum: 0.45) }
        guard frontMid.contains(where: { $0.y > ground + standingHeight * 0.15 && $0.y < neck.y - standingHeight * 0.10 }),
              backMid.contains(where: { $0.y > ground + standingHeight * 0.15 && $0.y < tail.y - standingHeight * 0.10 }) else { return fallback }

        var morphology = MorphologyParameters()
        // Vision tailBottom is the attachment/base, tailTop is the free tip.
        // Source neutral rig: neck-tail distance ~2.06, dorsal height ~1.56.
        // These are template calibration ratios, not anatomical ground truth.
        let ratio = (trunk / standingHeight) / 1.32
        morphology.bodyLength = Float(pow(ratio, 0.55))
        morphology.legLength = Float(pow(1 / ratio, 0.50))
        let headSpan = length(nose - neck)
        var measured = ["body length", "leg length"]
        if headSpan / trunk > 0.18 && headSpan / trunk < 0.85 {
            morphology.headSize = Float(pow((headSpan / trunk) / 0.56, 0.40))
            measured.append("head proportions")
        }
        if let eye = mean(["leftEye", "rightEye"].compactMap { point($0, minimum: 0.65) }), headSpan > 1 {
            let muzzle = length(nose - eye) / headSpan
            if muzzle > 0.10 && muzzle < 0.85 {
                morphology.muzzleLength = Float(pow(muzzle / 0.45, 0.45)); measured.append("muzzle")
            }
        }
        var ears: [(length: Double, droop: Double)] = []
        for side in ["left", "right"] {
            if let tip = point(side + "EarTop", minimum: 0.65), let base = point(side + "EarBottom", minimum: 0.65) {
                let earLength = length(tip - base)
                if earLength > headSpan * 0.07 && earLength < headSpan * 0.80 {
                    ears.append((earLength, max(0, min(1, (base.y - tip.y) / earLength))))
                }
            }
        }
        if !ears.isEmpty {
            let earLength = ears.map(\.length).reduce(0, +) / Double(ears.count)
            morphology.earSize = Float(pow((earLength / max(headSpan, 1)) / 0.35, 0.40))
            morphology.earDroop = Float(ears.map(\.droop).reduce(0, +) / Double(ears.count))
            measured.append("ears")
        }
        let coreConfidence = ["neck", "tailBase", "nose"].compactMap { landmarks[$0]?.confidence }.min() ?? 0
        return PhotoMorphologyAssessment(morphology: morphology.clamped(), measured: true,
            confidence: min(0.85, coreConfidence * 0.85),
            note: "Estimated from side-view landmarks: " + measured.joined(separator: ", ") + ". This estimates appearance, not exact 3D dimensions. Refine with the sliders." + (coreConfidence < 0.5 ? "Neck landmarks were unclear; check the fit." : ""))
    }

    @available(macOS 14.0, *)
    private static let jointNames: [(String, VNAnimalBodyPoseObservation.JointName)] = [
        ("neck", .neck), ("nose", .nose), ("tailTip", .tailTop), ("tailMiddle", .tailMiddle), ("tailBase", .tailBottom),
        ("leftEye", .leftEye), ("rightEye", .rightEye),
        ("leftEarTop", .leftEarTop), ("rightEarTop", .rightEarTop),
        ("leftEarMiddle", .leftEarMiddle), ("rightEarMiddle", .rightEarMiddle),
        ("leftEarBottom", .leftEarBottom), ("rightEarBottom", .rightEarBottom),
        ("leftFrontElbow", .leftFrontElbow), ("rightFrontElbow", .rightFrontElbow),
        ("leftFrontKnee", .leftFrontKnee), ("rightFrontKnee", .rightFrontKnee),
        ("leftFrontPaw", .leftFrontPaw), ("rightFrontPaw", .rightFrontPaw),
        ("leftBackElbow", .leftBackElbow), ("rightBackElbow", .rightBackElbow),
        ("leftBackKnee", .leftBackKnee), ("rightBackKnee", .rightBackKnee),
        ("leftBackPaw", .leftBackPaw), ("rightBackPaw", .rightBackPaw)]

    @available(macOS 14.0, *)
    private static func poseLandmarks(_ pose: VNAnimalBodyPoseObservation) -> [String: PhotoPoseLandmark] {
        var result: [String: PhotoPoseLandmark] = [:]
        for (name, joint) in jointNames {
            if let p = try? pose.recognizedPoint(joint) {
                result[name] = PhotoPoseLandmark(x: p.location.x, y: p.location.y, confidence: p.confidence)
            }
        }
        return result
    }
    @available(macOS 14.0, *)
    private static func bestPose(_ poses: [VNAnimalBodyPoseObservation], dogBox: CGRect) -> VNAnimalBodyPoseObservation? {
        let expanded = dogBox.insetBy(dx: -0.03, dy: -0.03)
        let scored = poses.map { pose -> (VNAnimalBodyPoseObservation, Double) in
            let p = poseLandmarks(pose).values.filter { $0.confidence >= 0.4 }
            let inside = p.filter { expanded.contains(CGPoint(x: $0.x, y: $0.y)) }.count
            return (pose, p.isEmpty ? 0 : Double(inside * inside) / Double(p.count))
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= 3 else { return nil }
        return best.0
    }

    private static func regionalColors(_ samples: [Sample], landmarks: [String: PhotoPoseLandmark], box: CGRect,
                                       width: Int, height: Int) -> [String: PhotoRGB] {
        let regions = ["head": ["nose", "leftEye", "rightEye", "leftEarMiddle", "rightEarMiddle"],
                       "body": ["neck", "tailBase"],
                       "legs": ["leftFrontElbow", "rightFrontElbow", "leftFrontKnee", "rightFrontKnee", "leftFrontPaw", "rightFrontPaw", "leftBackElbow", "rightBackElbow", "leftBackKnee", "rightBackKnee", "leftBackPaw", "rightBackPaw"],
                       "tail": ["tailMiddle", "tailTip"]]
        var result: [String: PhotoRGB] = [:]
        let scale = max(box.width * Double(width), box.height * Double(height))
        for (region, names) in regions {
            var anchors = names.compactMap { name -> CGPoint? in
                guard let p = landmarks[name], p.confidence >= (region == "body" ? 0.35 : 0.40) else { return nil }
                return CGPoint(x: p.x * Double(width), y: p.y * Double(height))
            }
            if region == "body", anchors.count == 2 {
                anchors = [CGPoint(x: (anchors[0].x + anchors[1].x) * 0.5, y: (anchors[0].y + anchors[1].y) * 0.5)]
            }
            let radius = scale * (region == "head" ? 0.13 : (region == "body" ? 0.20 : 0.07))
            let regionSamples = samples.filter { sample in
                anchors.contains { hypot(sample.point.x * Double(width) - $0.x, sample.point.y * Double(height) - $0.y) <= radius }
            }.map(\.rgb)
            if regionSamples.count >= 25, let first = cluster(regionSamples).first { result[region] = color(first.rgb) }
        }
        return result
    }

    @available(macOS 14.0, *)
    private static func bestInstance(_ observation: VNInstanceMaskObservation, dogBox: CGRect) -> Int? {
        let buffer = observation.instanceMask
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent8,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var totals: [Int: Int] = [:], overlaps: [Int: Int] = [:]
        let expanded = dogBox.insetBy(dx: -0.025, dy: -0.025)
        for y in 0..<height { for x in 0..<width {
            let id = Int(pixels[y * rowBytes + x]); guard id != 0 else { continue }
            totals[id, default: 0] += 1
            if expanded.contains(CGPoint(x: (Double(x) + 0.5) / Double(width), y: 1 - (Double(y) + 0.5) / Double(height))) { overlaps[id, default: 0] += 1 }
        } }
        return totals.keys.filter { (overlaps[$0] ?? 0) >= 30 }.max { a, b in
            Double(overlaps[a] ?? 0) * Double(overlaps[a] ?? 0) / Double(totals[a] ?? 1)
                < Double(overlaps[b] ?? 0) * Double(overlaps[b] ?? 0) / Double(totals[b] ?? 1)
        }
    }
    private static func maskValues(_ buffer: CVPixelBuffer, width: Int, height: Int) throws -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
              let base = CVPixelBufferGetBaseAddress(buffer) else { throw PhotoPersonalizationError.noForeground }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer), format = CVPixelBufferGetPixelFormatType(buffer)
        var result = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            if format == kCVPixelFormatType_OneComponent32Float {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<width { result[y * width + x] = row[x] }
            } else if format == kCVPixelFormatType_OneComponent8 {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { result[y * width + x] = Float(row[x]) / 255 }
            } else { throw PhotoPersonalizationError.noForeground }
        }
        return result
    }
    private static func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = pixels.withUnsafeMutableBytes { ptr -> Bool in
            guard let context = CGContext(data: ptr.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return true
        }
        guard success else { throw PhotoPersonalizationError.unreadableImage }
        return pixels
    }
    private static func color(_ rgb: SIMD3<Double>) -> PhotoRGB {
        PhotoRGB(red: Float(max(0, min(1, rgb.x))), green: Float(max(0, min(1, rgb.y))), blue: Float(max(0, min(1, rgb.z))))
    }
    private static func luminance(_ rgb: SIMD3<Double>) -> Double { rgb.x * 0.30 + rgb.y * 0.59 + rgb.z * 0.11 }
    private static func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b; return d.x * d.x * 0.30 + d.y * d.y * 0.59 + d.z * d.z * 0.11
    }
    private static func cluster(_ colors: [SIMD3<Double>]) -> [Cluster] {
        guard !colors.isEmpty else { return [] }
        var centroids = [colors.reduce(SIMD3<Double>(repeating: 0), +) / Double(colors.count)]
        for _ in 1..<4 {
            if let farthest = colors.max(by: { a, b in (centroids.map { distance(a, $0) }.min() ?? 0) < (centroids.map { distance(b, $0) }.min() ?? 0) }),
               (centroids.map { distance(farthest, $0) }.min() ?? 0) > 0.008 { centroids.append(farthest) }
        }
        var counts = [Int](repeating: 0, count: centroids.count)
        for _ in 0..<10 {
            var sums = [SIMD3<Double>](repeating: SIMD3(repeating: 0), count: centroids.count)
            counts = [Int](repeating: 0, count: centroids.count)
            for rgb in colors {
                let k = centroids.indices.min { distance(rgb, centroids[$0]) < distance(rgb, centroids[$1]) }!
                sums[k] += rgb; counts[k] += 1
            }
            for k in centroids.indices where counts[k] > 0 { centroids[k] = sums[k] / Double(counts[k]) }
        }
        return centroids.indices.compactMap { k in
            let weight = Double(counts[k]) / Double(colors.count)
            return weight >= 0.025 ? Cluster(rgb: centroids[k], weight: weight) : nil
        }.sorted { $0.weight > $1.weight }
    }
}
