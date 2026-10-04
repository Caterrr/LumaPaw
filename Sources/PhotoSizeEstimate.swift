import Foundation

struct PhotoCoatSample: Codable {
    let color: PhotoRGB
    let share: Float
    var name:String {
        let r=color.red,g=color.green,b=color.blue,hi=max(r,max(g,b)),lo=min(r,min(g,b))
        let light=r*0.3+g*0.59+b*0.11
        if light<0.18{return "Black"}
        if light>0.72 && r-b>0.055{return "Cream"}
        if r-g>0.045 && r-b>0.035{return light>0.55 ? "Tan":"Brown"}
        if hi-lo<0.12{return light>0.77 ? "White":"Grey"}
        return "Coat colour"
    }
}
struct PhotoSizeEstimate: Codable {
    var category:String
    var cue:String?
    var confidence:Float
    var targetHeight:Float?
    /// Choose an available silhouette afresh on each import. These are
    /// approximations, not a claim that every detected breed is in our library.
    func matchingBreed(fallback:DogBreed)->DogBreed {
        guard targetHeight != nil else{return fallback}
        switch cue {
        case "chihuahua":return .beagle
        case "beagle":return .beagle
        case "shiba inu":return .shiba
        case "dalmatian":return .dalmatian
        default:
            switch category {
            case "Tiny":return .beagle
            case "Small":return .beagle
            case "Medium":return .shiba
            case "Large":return .dalmatian
            default:return fallback
            }
        }
    }
    var summary:String {
        guard targetHeight != nil else{return "Size unclear · your current size is kept"}
        return "Estimated size: \(category) · \(cue ?? "breed") cues"
    }
}
extension PhotoPersonalizer {
    /// Conservative appearance priors. Broad/variable classes such as poodle,
    /// terrier and hound deliberately do not imply one physical size.
    static func assessSize(labels:[String:Float])->PhotoSizeEstimate {
        let groups:[String:(String,Float)] = [
            "chihuahua":("Tiny",1.5),"pomeranian":("Small",2.0),"bichon":("Small",2.0),
            "maltese":("Small",2.0),"pug":("Small",2.1),"dachshund":("Small",2.1),
            "corgi":("Small",2.2),"beagle":("Small",2.2),"shiba_inu":("Medium",2.8),
            "border_collie":("Medium",2.9),"australian_shepherd":("Medium",3.0),
            "retriever":("Large",3.5),"labrador_retriever":("Large",3.5),"golden_retriever":("Large",3.5),
            "german_shepherd":("Large",3.5),"dalmatian":("Large",3.5),"husky":("Large",3.3),
            "rottweiler":("Large",3.5),"newfoundland":("Large",3.7),"mastiff":("Large",3.7),
            "great_dane":("Large",3.7),"irish_wolfhound":("Large",3.7),"weimaraner":("Large",3.5)]
        let candidates=labels.filter{groups[$0.key] != nil && $0.value.isFinite}.sorted{$0.value>$1.value}
        guard let best=candidates.first,best.value>=0.55,
              best.value-(candidates.dropFirst().first(where:{groups[$0.key]?.0 != groups[best.key]?.0})?.value ?? 0)>=0.18,
              max(labels["poodle"] ?? 0,max(labels["terrier"] ?? 0,labels["hound"] ?? 0))<best.value,
              (labels["puppy"] ?? 0)<0.4,let match=groups[best.key] else {
            return PhotoSizeEstimate(category:"Unclear",cue:nil,confidence:0,targetHeight:nil)
        }
        return PhotoSizeEstimate(category:match.0,cue:best.key.replacingOccurrences(of:"_",with:" "),confidence:best.value,targetHeight:match.1)
    }
    static func summarizeCoat(_ samples:[PhotoCoatSample])->[PhotoCoatSample] {
        Dictionary(grouping:samples,by:{$0.name}).values.map{group in
            let total=group.reduce(Float(0)){$0+$1.share}
            var c=PhotoRGB(red:0,green:0,blue:0)
            for sample in group {let w=sample.share/max(total,0.0001);c.red+=sample.color.red*w;c.green+=sample.color.green*w;c.blue+=sample.color.blue*w}
            return PhotoCoatSample(color:c,share:total)
        }.sorted{$0.share>$1.share}
    }
    static func isAccessoryColor(_ c:SIMD3<Double>)->Bool {
        // Natural brown/ginger fur remains valid; bright blue/green fabric does not.
        (c.z>0.38 && c.z>c.x*1.65 && c.z>c.y*1.35) || (c.y>0.40 && c.y>c.x*1.45 && c.y>c.z*1.3)
    }
}
