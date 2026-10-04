import Foundation
import simd

/// A short white blade stroke, independent of the dog's movement or body.
/// Nothing remains to collect: the entire stroke expires in 0.15 seconds.
final class LightTrail {
    struct Sample {var point:SIMD2<Float>;var age:Float;let stroke:Int}
    struct Vertex {var positionSide:SIMD4<Float>}
    private(set) var samples:[Sample]=[]
    let lifetime:Float=0.15
    private var last:SIMD2<Float>?,stroke=0
    func reset(){samples.removeAll();last=nil;stroke+=1}
    func stopDrawing(){if last != nil{stroke+=1};last=nil}
    // Keep a live stroke connected across one or two missing captures. Do not
    // fabricate movement, and never revive a stroke after its 0.15 s lifetime.
    func pauseDrawing(){if samples.isEmpty{stopDrawing()}}
    func draw(at point:SIMD2<Float>?){
        guard let point,point.x.isFinite,point.y.isFinite else{stopDrawing();return}
        guard let previous=last else{last=point;samples.append(Sample(point:point,age:0,stroke:stroke));return}
        let distance=simd_distance(previous,point)
        guard distance>0.015 else{return}
        if distance>4 {stopDrawing();draw(at:point);return}
        let steps=min(48,max(1,Int(ceil(distance/0.055))))
        for i in 1...steps {samples.append(Sample(point:previous+(point-previous)*Float(i)/Float(steps),age:0,stroke:stroke))}
        last=point
        if samples.count>160{samples.removeFirst(samples.count-160)}
    }
    func advance(dt:Float){
        guard dt.isFinite,dt>=0 else{return}
        for i in samples.indices{samples[i].age+=dt}
        samples.removeAll{$0.age>=lifetime}
    }
    func vertices(worldPerPixel:Float)->[Vertex]{
        guard samples.count>1 else{return []}
        var result:[Vertex]=[];result.reserveCapacity(samples.count*6)
        for i in 1..<samples.count {
            let a=samples[i-1],b=samples[i];guard a.stroke==b.stroke else{continue}
            let delta=b.point-a.point,d=simd_length(delta);guard d>0.0001 else{continue}
            let side=SIMD2(-delta.y,delta.x)/d
            let lifeA=max(0,1-a.age/lifetime),lifeB=max(0,1-b.age/lifetime)
            let wa=worldPerPixel*(0.25+2.0*lifeA),wb=worldPerPixel*(0.25+2.0*lifeB)
            func v(_ p:SIMD2<Float>,_ s:Float,_ width:Float,_ life:Float)->Vertex {
                let q=p+side*s*width
                return Vertex(positionSide:SIMD4(q.x,q.y,s,pow(life,1.5)))
            }
            let al=v(a.point,-1,wa,lifeA),ar=v(a.point,1,wa,lifeA),bl=v(b.point,-1,wb,lifeB),br=v(b.point,1,wb,lifeB)
            result += [al,ar,bl,bl,ar,br]
        }
        return result
    }
}
