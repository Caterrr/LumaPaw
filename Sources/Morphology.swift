import Foundation
import simd

struct MorphologyParameters: Codable, Equatable {
    // Missing in legacy profiles, so nil always retains the original Shiba.
    var breed: DogBreed? = nil
    var overallScale: Float? = nil
    var sizeScale: Float { let x=overallScale ?? 1;return x.isFinite ? min(2.4,max(0.45,x)):1 }
    var bodyLength: Float = 1
    var legLength: Float = 1
    var headSize: Float = 1
    var muzzleLength: Float = 1
    var earSize: Float = 1
    var earDroop: Float = 0
    var bodyWidth: Float = 1
    init(bodyLength: Float = 1, legLength: Float = 1, headSize: Float = 1,
         muzzleLength: Float = 1, earSize: Float = 1, earDroop: Float = 0,
         bodyWidth: Float = 1, breed: DogBreed? = nil, overallScale: Float? = nil) {
        self.overallScale=overallScale
        self.breed=breed == .shiba ? nil:breed
        self.bodyLength=bodyLength; self.legLength=legLength; self.headSize=headSize
        self.muzzleLength=muzzleLength; self.earSize=earSize; self.earDroop=earDroop; self.bodyWidth=bodyWidth
    }
    func clamped() -> Self {
        func c(_ x:Float,_ a:Float,_ b:Float,_ fallback:Float=1)->Float { x.isFinite ? min(max(x,a),b) : fallback }
        return Self(bodyLength:c(bodyLength,0.78,1.40),legLength:c(legLength,0.60,1.32),
                    headSize:c(headSize,0.82,1.24),muzzleLength:c(muzzleLength,0.65,1.35),
                    earSize:c(earSize,0.70,1.55),earDroop:c(earDroop,0,1,0),bodyWidth:c(bodyWidth,0.68,1.35),breed:breed,overallScale:overallScale == nil ? nil:sizeScale)
    }
    var shapeIsDefault:Bool { var p=self;p.breed=nil;p.overallScale=nil;return p == MorphologyParameters() }
}

struct BakedMorphologyClip {
    let positions: Data
    let normals: Data
    let frameCount: Int
    let fps: Float
    let duration: Float
    let loop: Bool
    let endpointIncluded: Bool
}
struct BakedMorphology {
    let parameters: MorphologyParameters
    let clips: [String:BakedMorphologyClip]
    let noseMean: [String:SIMD3<Float>]
    let pawContactMean: [String:SIMD3<Float>]
    let pawSampleIndices: [Int]
    let noseSampleIndices: [Int]
    let fetchNoseContact: SIMD3<Float>
    let boundsMin: SIMD3<Float>
    let boundsMax: SIMD3<Float>
    let bakeSeconds: Double
}

/// Rebinds the original 46-joint rig and original skin, then evaluates the author's
/// local bone animation against the new rest pose. No Blender process or network
/// is used during a photo import. All output clips retain the same 24k particles.
final class ParametricDogAssets {
    private struct Clip: Decodable { let name:String; let file:String; let frameCount:Int; let fps:Float; let duration:Float; let contactTime:Float?; let contactWindow:[Float]?; let loop:Bool?; let endpointIncluded:Bool? }
    private struct Model: Decodable {
        let motionScale:Float?
        let version:Int; let particleCount:Int; let boneNames:[String]; let parents:[Int]
        let restMatrices:[[Float]]; let vertices:[[Float]]; let joints:[[Int]]; let weights:[[Float]]
        let triangles:[[Int]]; let weld:[Int]; let sampleTriangles:[[Int]]; let sampleBarycentric:[[Float]]
        let noseSamples:[Int]; let highfivePawSamples:[Int]?; let clips:[Clip]
    }
    private let model:Model
    private let vertices:[SIMD3<Float>], rest:[simd_float4x4]
    private let weights:[SIMD4<Float>], joints:[SIMD4<Int32>]
    private let triangles:[SIMD3<Int32>], samples:[SIMD3<Int32>], bary:[SIMD3<Float>]
    private let motion:[[Float]]
    private let weldCount:Int
    let particleCount:Int
    var boneCount:Int { rest.count }
    var pawSampleIndices:[Int] { model.highfivePawSamples ?? [] }
    init(resources:URL,breed:DogBreed = .shiba) throws {
        let json=try Data(contentsOf:resources.appendingPathComponent(breed.rigFilename))
        model=try JSONDecoder().decode(Model.self,from:json)
        guard model.version==1,model.boneNames.count==46,model.particleCount==24000 else { throw Self.error("Unsupported dog rig") }
        particleCount=model.particleCount
        vertices=model.vertices.map { SIMD3($0[0],$0[1],$0[2]) }
        rest=model.restMatrices.map { a in simd_float4x4(columns:(SIMD4(a[0],a[1],a[2],a[3]),SIMD4(a[4],a[5],a[6],a[7]),SIMD4(a[8],a[9],a[10],a[11]),SIMD4(a[12],a[13],a[14],a[15]))) }
        joints=model.joints.map { SIMD4(Int32($0[0]),Int32($0[1]),Int32($0[2]),Int32($0[3])) }
        weights=model.weights.map { SIMD4($0[0],$0[1],$0[2],$0[3]) }
        triangles=model.triangles.map { SIMD3(Int32($0[0]),Int32($0[1]),Int32($0[2])) }
        samples=model.sampleTriangles.map { SIMD3(Int32($0[0]),Int32($0[1]),Int32($0[2])) }
        bary=model.sampleBarycentric.map { SIMD3($0[0],$0[1],$0[2]) }
        weldCount=(model.weld.max() ?? 0)+1
        motion=try model.clips.map { clip in
            let d=try Data(contentsOf:resources.appendingPathComponent(clip.file))
            guard d.count==(clip.frameCount+1)*46*10*4 else { throw Self.error("Truncated original bone animation: \(clip.name)") }
            return d.withUnsafeBytes { Array($0.bindMemory(to:Float.self)) }
        }
    }
    private static func error(_ text:String)->NSError { NSError(domain:"LuminousPup.Morphology",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
    private static func xyz(_ p:SIMD4<Float>)->SIMD3<Float> { SIMD3(p.x,p.y,p.z) }
    private static func safeNormal(_ p:SIMD3<Float>)->SIMD3<Float> { p/max(simd_length(p),0.000001) }
    private static func smooth(_ a:Float,_ b:Float,_ x:Float)->Float { let t=min(max((x-a)/(b-a),0),1);return t*t*(3-2*t) }
    private static func smoother(_ x:Float)->Float {let t=min(max(x,0),1);return t*t*t*(t*(t*6-15)+10)}

    /// Keep the chest over its supporting paws while the pelvis settles back.
    /// Each hind leg folds into its own outside lane, with the knee forward and
    /// the hock behind it. Paw roots must travel with this fold: pinning them to
    /// their standing positions stretched the imported thighs across the belly.
    private func seatedPose(neutral:[simd_float4x4],amount a:Float,breath:Float,
                            parameters m:MorphologyParameters)->[simd_float4x4] {
        guard a>0 else{return neutral}
        var g=neutral
        func n(_ i:Int)->SIMD3<Float>{Self.xyz(neutral[i].columns.3)}
        func p(_ i:Int)->SIMD3<Float>{Self.xyz(g[i].columns.3)}
        let ratio=min(1.15,max(0.40,m.legLength/m.bodyLength))
        let isShiba = m.breed == nil || m.breed == .shiba
        let fullAngle:Float=(m.breed == .beagle ? 0.57:(isShiba ? 0.88:0.78))*ratio
        let pivot=(n(18)+n(21))*0.5
        func torso(_ amount:Float)->simd_float4x4 {
            var t=simd_float4x4(simd_quatf(angle:fullAngle*amount,axis:SIMD3(0,0,1)))
            t.columns.3=SIMD4(pivot-Self.xyz(t*SIMD4(pivot,0)),1);return t
        }
        let transform=torso(a),seated=torso(1)
        for i in 0..<38 {g[i]=transform*neutral[i]}
        func aimed(_ matrix:simd_float4x4,_ old:SIMD3<Float>,_ new:SIMD3<Float>,_ position:SIMD3<Float>)->simd_float4x4 {
            var r=simd_float4x4(simd_quatf(from:Self.safeNormal(old),to:Self.safeNormal(new)))*matrix
            r.columns.3=SIMD4(position,1);return r
        }
        func solve(_ upper:Int,_ lower:Int,_ oldEnd:SIMD3<Float>,_ target:SIMD3<Float>,pole preferred:SIMD3<Float>?=nil,lowerScale:Float=1)->SIMD3<Float> {
            let shoulder=p(upper),oldElbow=p(lower),l1=simd_length(oldElbow-shoulder),l2=simd_length(oldEnd-oldElbow)*lowerScale
            let direction=Self.safeNormal(target-shoulder)
            let distance=min(max(simd_length(target-shoulder),abs(l1-l2)+0.00001),(l1+l2)*0.99999)
            let end=shoulder+direction*distance,source=Self.safeNormal(oldEnd-shoulder)
            var pole=oldElbow-shoulder-source*simd_dot(oldElbow-shoulder,source)
            pole-=direction*simd_dot(pole,direction)
            if let preferred {
                let desired=preferred-direction*simd_dot(preferred,direction)
                if isShiba {
                    let start=Self.safeNormal(pole),finish=Self.safeNormal(desired)
                    let angle=atan2(simd_dot(simd_cross(start,finish),direction),simd_dot(start,finish))
                    pole=simd_quatf(angle:angle*a,axis:direction).act(start)
                } else {pole=simd_mix(Self.safeNormal(pole),Self.safeNormal(desired),SIMD3(repeating:a))}
            }
            if simd_length(pole)<0.000001 {pole=SIMD3(1,0,0)-direction*direction.x}
            pole=Self.safeNormal(pole)
            let along=(l1*l1-l2*l2+distance*distance)/(2*distance)
            let elbow=shoulder+direction*along+pole*sqrt(max(0,l1*l1-along*along))
            g[upper]=aimed(g[upper],oldElbow-shoulder,elbow-shoulder,shoulder)
            g[lower]=aimed(g[lower],oldEnd-oldElbow,end-elbow,elbow)
            if lowerScale != 1 {
                let axis=Self.safeNormal(end-elbow)
                for column in 0..<3 {
                    let v=Self.xyz(g[lower][column])
                    g[lower][column]=SIMD4(v+axis*(simd_dot(axis,v)*(lowerScale-1)),0)
                }
            }
            return end
        }
        for (upper,lower,foot) in [(18,19,40),(21,22,44)] {
            _=solve(upper,lower,Self.xyz(transform*neutral[foot].columns.3),p(foot))
        }
        for (hip,knee,hock,foot,front) in [(24,25,26,38,40),(28,29,30,42,44)] {
            let side:Float=n(foot).z<0 ? -1:1
            let thigh=simd_length(n(knee)-n(hip)),shin=simd_length(n(hock)-n(knee)),ankle=simd_length(n(foot)-n(hock))
            let seatedHip=Self.xyz(seated*neutral[hip].columns.3)
            // Fold the metatarsus close to horizontal, preserving its length.
            // Leave room between each rear paw and the planted front paw.
            let lane=max(abs(n(foot).z),abs(n(front).z))+(isShiba ? 0.075:0.055)*m.bodyWidth
            let hockHeight=n(foot).y+ankle*0.30
            // The source Shiba tibia is twice its femur length. A gradual
            // seated corrective brings this stylised segment into a compact
            // fold; preserve the joint axis rather than crushing the whole leg.
            let seatedShin=shin*(isShiba ? 0.76:1)
            var hockX=isShiba ? -seatedShin*0.36:max(-shin*0.32,(thigh-shin)*1.3)
            let vertical=hockHeight-seatedHip.y
            let minimumReach=abs(thigh-seatedShin)+min(thigh,seatedShin)*0.16
            if hockX<0 {hockX = -max(abs(hockX),sqrt(max(0,minimumReach*minimumReach-vertical*vertical)))}
            let seatedHock=SIMD3(seatedHip.x+hockX,hockHeight,side*lane)
            let seatedFoot=seatedHock+SIMD3(sqrt(1-0.30*0.30)*ankle,-0.30*ankle,0)
            let footPosition=simd_mix(n(foot),seatedFoot,SIMD3(repeating:a))
            let target=simd_mix(n(hock),seatedHock,SIMD3(repeating:a))
            let oldHock=p(hock),oldFoot=Self.xyz(transform*neutral[foot].columns.3)
            let solved=solve(hip,knee,oldHock,target,pole:SIMD3(1,isShiba ? 0.38:0,side*(isShiba ? 0.22:0.16)),lowerScale:isShiba ? 1-0.24*a:1)
            g[hock]=aimed(g[hock],oldFoot-oldHock,footPosition-solved,solved)
            // A level paw and its toes follow together; neither inherits the
            // hock rotation, which previously folded the toes under the leg.
            g[foot]=neutral[foot];g[foot].columns.3=SIMD4(footPosition,1)
            g[foot+1]=g[foot]*simd_inverse(neutral[foot])*neutral[foot+1]
        }
        func rotateBranch(_ root:Int,_ angle:Float,_ axis:SIMD3<Float>) {
            let center=p(root)
            var r=simd_float4x4(simd_quatf(angle:angle,axis:axis))
            r.columns.3=SIMD4(center-Self.xyz(r*SIMD4(center,0)),1)
            for i in root..<38 {
                var ancestor=i
                while ancestor>=0 && ancestor != root {ancestor=model.parents[ancestor]}
                if ancestor==root {g[i]=r*g[i]}
            }
        }
        rotateBranch(5,-fullAngle*0.57*a,SIMD3(0,0,1))
        rotateBranch(8,-fullAngle*0.41*a,SIMD3(0,0,1))
        rotateBranch(6,0.018*breath,SIMD3(1,0,0))
        // Uncurl the tail from the pelvis tilt so a long tail rests behind
        // the haunch instead of penetrating the floor and lifting every paw.
        rotateBranch(31,-fullAngle*(m.breed == nil ? 0.72:0.94)*a,SIMD3(0,0,1))
        rotateBranch(31,0.06*breath,SIMD3(0,1,0))
        return g
    }

    /// One original front leg reaches the glass; the other three paws stay
    /// planted. Solve the two physical limb bones and roll the authored wrist
    /// so its underside faces local +X (the camera at yaw -pi/2). The same bind
    /// skin and barycentric surface samples are used for every coat/profile.
    private func screenHighFivePose(neutral:[simd_float4x4],time:Float,
                                   parameters m:MorphologyParameters)->[simd_float4x4] {
        var g=neutral
        let reach=Self.smoother(time/1.02)*(1-Self.smoother((time-1.40)/0.92))
        guard reach>0 else{return g}
        func p(_ i:Int)->SIMD3<Float>{Self.xyz(neutral[i].columns.3)}
        let shoulder=p(21),elbow=p(22),wrist=p(44)
        let upperLength=simd_length(elbow-shoulder),lowerLength=simd_length(wrist-elbow)
        let direction=Self.safeNormal(SIMD3<Float>(0.91,0.40,0.18))
        // A small outward lane keeps the raised paw beside the muzzle in the
        // frontal view; its reach remains inside the original limb length.
        let desired=shoulder+direction*(upperLength+lowerLength)*0.96
        let target=simd_mix(wrist,desired,SIMD3(repeating:reach))
        let axis=Self.safeNormal(target-shoulder)
        let distance=min(max(simd_length(target-shoulder),abs(upperLength-lowerLength)+0.00001),(upperLength+lowerLength)*0.99999)
        let end=shoulder+axis*distance
        var pole=elbow-shoulder
        pole-=axis*simd_dot(pole,axis)
        if simd_length(pole)<0.00001 {pole=SIMD3(-1,0,0)-axis*(-axis.x)}
        pole=Self.safeNormal(pole)
        let along=(upperLength*upperLength-lowerLength*lowerLength+distance*distance)/(2*distance)
        let bend=shoulder+axis*along+pole*sqrt(max(0,upperLength*upperLength-along*along))
        func aim(_ joint:Int,_ old:SIMD3<Float>,_ new:SIMD3<Float>,_ origin:SIMD3<Float>) {
            var rotation=simd_float4x4(simd_quatf(from:Self.safeNormal(old),to:Self.safeNormal(new)))*neutral[joint]
            rotation.columns.3=SIMD4(origin,1);g[joint]=rotation
        }
        aim(21,elbow-shoulder,bend-shoulder,shoulder)
        aim(22,wrist-elbow,end-bend,bend)
        // 90 degrees takes the ground-facing -Y pad normal to +X. No repeated
        // handshake oscillation: a single soft landing, a hold, and withdrawal.
        let roll=simd_float4x4(simd_quatf(angle:Float.pi/2*reach,axis:SIMD3(0,0,1)))
        g[44]=roll*neutral[44];g[44].columns.3=SIMD4(end,1)
        g[45]=g[44]*simd_inverse(neutral[44])*neutral[45]
        // Small head attention and a single tail sway are smoothly enveloped;
        // the supporting legs never borrow the reaching leg's animation.
        func rotateBranch(_ root:Int,_ angle:Float,_ axis:SIMD3<Float>) {
            let center=p(root)
            var r=simd_float4x4(simd_quatf(angle:angle,axis:axis))
            r.columns.3=SIMD4(center-Self.xyz(r*SIMD4(center,0)),1)
            for i in root..<34 {
                var ancestor=i
                while ancestor>=0 && ancestor != root {ancestor=model.parents[ancestor]}
                if ancestor==root {g[i]=r*g[i]}
            }
        }
        rotateBranch(6,0.06*reach,SIMD3(0,0,1))
        rotateBranch(31,sin(time*4.2)*0.09*reach,SIMD3(0,1,0))
        return g
    }

    /// A reach to the floor: the chest folds gently over planted front paws,
    /// then the neck lowers independently. Four limb chains are re-solved to
    /// their original contacts instead of rotating the entire dog onto its nose.
    private func fetchPickupPose(neutral:[simd_float4x4],nose:SIMD3<Float>,time:Float)->[simd_float4x4] {
        let amount=Self.smoother(time/0.72)*(1-Self.smoother((time-1.0)/0.80))
        guard amount>0 else{return neutral}
        var g=neutral
        func p(_ i:Int)->SIMD3<Float>{Self.xyz(neutral[i].columns.3)}
        let radius=min(0.14,max(0.075,nose.y*0.05)),height=max(1,nose.y)
        func bodyTransform(_ angle:Float,_ drop:Float)->simd_float4x4 {
            let pivot=p(1);var t=simd_float4x4(simd_quatf(angle:angle,axis:SIMD3(0,0,1)))
            t.columns.3=SIMD4(pivot-Self.xyz(t*SIMD4(pivot,0))+SIMD3(0,-drop,0),1);return t
        }
        var fullAngle:Float = -0.16
        for _ in 0..<14 {
            let body=bodyTransform(fullAngle,0),neck=Self.xyz(body*SIMD4(p(5),1)),tip=Self.xyz(body*SIMD4(nose,1))
            if neck.y-simd_length(tip-neck)<radius*1.65{break}
            fullAngle-=0.02
        }
        let fullBody=bodyTransform(fullAngle,0),fullNeck=Self.xyz(fullBody*SIMD4(p(5),1)),fullNose=Self.xyz(fullBody*SIMD4(nose,1))
        let drop=min(height*0.18,max(0,fullNeck.y-simd_length(fullNose-fullNeck)-radius*1.65))
        let body=bodyTransform(fullAngle*amount,drop*amount)
        for i in 1..<34 {g[i]=body*neutral[i]}
        let pivot=Self.xyz(g[5].columns.3),tip=Self.xyz(body*SIMD4(nose,1)),vector=tip-pivot
        let length=max(0.05,sqrt(vector.x*vector.x+vector.y*vector.y))
        let targetY=nose.y+(radius*2.0-nose.y)*amount
        let dy=max(-length*0.995,min(length*0.995,targetY-pivot.y))
        let dx=sqrt(max(0.0001,length*length-dy*dy))
        let angle=atan2(dy,dx)-atan2(vector.y,vector.x)
        var neck=simd_float4x4(simd_quatf(angle:angle,axis:SIMD3(0,0,1)))
        neck.columns.3=SIMD4(pivot-Self.xyz(neck*SIMD4(pivot,0)),1)
        for i in 5..<17 {g[i]=neck*g[i]}
        g=retargetPuppyLimbs(global:g,neutral:neutral)
        return g
    }

    /// Keep the shared animated foot trajectories attached to this FBX's shorter limbs.
    /// Bone rotations and clip timing still come from the existing authored actions.
    private func retargetPuppyLimbs(global:[simd_float4x4],neutral:[simd_float4x4])->[simd_float4x4] {
        var g=global
        func p(_ i:Int)->SIMD3<Float>{Self.xyz(g[i].columns.3)}
        func aim(_ j:Int,_ old:SIMD3<Float>,_ new:SIMD3<Float>,_ at:SIMD3<Float>) {
            var r=simd_float4x4(simd_quatf(from:Self.safeNormal(old),to:Self.safeNormal(new)))*g[j]
            r.columns.3=SIMD4(at,1);g[j]=r
        }
        func solve(_ a:Int,_ b:Int,_ oldEnd:SIMD3<Float>,_ target:SIMD3<Float>)->SIMD3<Float> {
            let start=p(a),bend=p(b),l1=simd_length(bend-start),l2=simd_length(oldEnd-bend)
            let axis=Self.safeNormal(target-start)
            let d=min(max(simd_length(target-start),abs(l1-l2)+0.00001),(l1+l2)*0.99999)
            var pole=bend-start;pole-=axis*simd_dot(pole,axis)
            if simd_length(pole)<0.00001 {pole=SIMD3(-1,0,0)-axis*(-axis.x)}
            let along=(l1*l1-l2*l2+d*d)/(2*d)
            let elbow=start+axis*along+Self.safeNormal(pole)*sqrt(max(0,l1*l1-along*along)),end=start+axis*d
            aim(a,bend-start,elbow-start,start);aim(b,oldEnd-bend,end-elbow,elbow)
            return end
        }
        for (upper,lower,foot,toe) in [(18,19,40,41),(21,22,44,45)] {
            let oldEnd=Self.xyz(g[lower]*simd_inverse(neutral[lower])*neutral[foot].columns.3)
            let end=solve(upper,lower,oldEnd,p(foot)),offset=end-p(foot)
            g[foot].columns.3+=SIMD4(offset,0);g[toe].columns.3+=SIMD4(offset,0)
        }
        for (hip,knee,hock,foot) in [(24,25,26,38),(28,29,30,42)] {
            let oldHock=p(hock),oldEnd=Self.xyz(g[hock]*simd_inverse(neutral[hock])*neutral[foot].columns.3)
            let target=p(foot),hockTarget=target+(oldHock-oldEnd)
            let end=solve(hip,knee,oldHock,hockTarget)
            aim(hock,oldEnd-oldHock,target-end,end)
        }
        return g
    }

    /// Continuous rest-space proportion map. Both joints and the unposed bind mesh
    /// pass through this same map before the original skin weights are evaluated.
    private func reshape(_ p:SIMD3<Float>,_ m:MorphologyParameters)->SIMD3<Float> {
        if m.breed != nil && m.shapeIsDefault { return p }
        let legShift=(m.legLength-1)*min(max(p.y,0),1.40)
        var q=SIMD3(p.x*m.bodyLength,p.y+legShift,p.z*m.bodyWidth)
        // Keep the tail curl locally shaped as the rump moves with body length.
        if p.x < -1.0 { q.x = -m.bodyLength+(p.x+1) }
        let head=Self.smooth(0.63,1.08,p.x)*Self.smooth(1.42,1.96,p.y)
        let h=SIMD3(1.10*m.bodyLength+(p.x-1.10)*m.headSize,
                    2.18+(m.legLength-1)*1.40+(p.y-2.18)*m.headSize,p.z*m.headSize)
        q=simd_mix(q,h,SIMD3(repeating:head))
        q.x+=max(p.x-1.40,0)*(m.muzzleLength-1)*m.headSize*head
        // Original ear mesh is lengthened and rotated outward around its base.
        // This creates droopy ears but does not invent a new breed-specific mesh.
        let ear=Self.smooth(2.43,2.70,p.y)*Self.smooth(0.91,1.13,p.x)*(1-Self.smooth(1.63,1.78,p.x))
        if ear>0 && m.breed == nil {
            let side:Float=p.z<0 ? -1:1
            let base=SIMD3(1.27*m.bodyLength,2.45+(m.legLength-1)*1.40,side*0.17*m.headSize)
            var v=q-base;v*=m.earSize
            let angle=m.earDroop*1.95*side,c=cos(angle),s=sin(angle)
            let y=v.y*c-v.z*s,z=v.y*s+v.z*c
            v.y=y;v.z=z;v.x-=m.earDroop*0.12*m.earSize
            q=simd_mix(q,base+v,SIMD3(repeating:ear))
        }
        return q
    }
    private func adaptedRest(_ m:MorphologyParameters)->[simd_float4x4] {
        if m.shapeIsDefault { return rest }
        return rest.map { r in
            let p=Self.xyz(r.columns.3),q=reshape(p,m),eps:Float=0.01
            let x=Self.safeNormal(reshape(p+Self.xyz(r.columns.0)*eps,m)-q)
            let rawY=reshape(p+Self.xyz(r.columns.1)*eps,m)-q
            let y=Self.safeNormal(rawY-x*simd_dot(rawY,x)),z=Self.safeNormal(simd_cross(x,y))
            return simd_float4x4(columns:(SIMD4(x,0),SIMD4(y,0),SIMD4(z,0),SIMD4(q,1)))
        }
    }

    func bake(parameters input:MorphologyParameters, onlyClips:Set<String>?=nil) throws -> BakedMorphology {
        let start=Date.timeIntervalSinceReferenceDate,m=input.clamped(),boneCount=rest.count
        let newRest=adaptedRest(m),inverseRest=newRest.map(simd_inverse)
        let bind=vertices.map { reshape($0,m) }
        let localRest=newRest.enumerated().map { i,r in model.parents[i]<0 ? r : inverseRest[model.parents[i]]*r }
        var baked:[String:BakedMorphologyClip]=[:],nose:[String:SIMD3<Float>]=[:],pawContact:[String:SIMD3<Float>]=[:]
        var allMin=SIMD3<Float>(repeating:Float.greatestFiniteMagnitude),allMax = -allMin
        var sitNeutral:[simd_float4x4]?
        let procedural=Clip(name:"screen_highfive",file:"",frameCount:145,fps:60,duration:2.4,
                            contactTime:1.05,contactWindow:[1.05,1.40],loop:false,endpointIncluded:true)
        let pickup=Clip(name:"fetch_pickup",file:"",frameCount:109,fps:60,duration:1.8,contactTime:0.84,contactWindow:[0.80,0.90],loop:false,endpointIncluded:true)
        let clips=model.clips+[procedural,pickup]
        var fetchNoseContact=SIMD3<Float>(1.6,0.24,0)
        let idleIndex=model.clips.firstIndex(where:{$0.name=="idle"}) ?? 0
        for (clipIndex,clip) in clips.enumerated() {
            if let onlyClips, !onlyClips.contains(clip.name) {continue}
            let screenClip=clip.name=="screen_highfive",fetchClip=clip.name=="fetch_pickup"
            let isProcedural=screenClip || fetchClip
            var neutralFetchNose:SIMD3<Float>?
            let trs=motion[isProcedural ? idleIndex:clipIndex],frames=clip.frameCount,n=particleCount
            var output=[Float](repeating:0,count:(frames+1)*n*3),normalOutput=output
            var global=[simd_float4x4](repeating:matrix_identity_float4x4,count:boneCount),skin=global
            var posed=[SIMD3<Float>](repeating:.zero,count:bind.count)
            var normals=[SIMD3<Float>](repeating:.zero,count:weldCount)
            for frame in 0...frames {
                for j in 0..<boneCount {
                    let at=((isProcedural ? 0:frame)*boneCount+j)*10
                    var t=SIMD3(trs[at],trs[at+1],trs[at+2])
                    if !m.shapeIsDefault {
                        // Local animated translation is carried through the same
                        // rest-space map and expressed in the adapted joint axes.
                        let p=Self.xyz(rest[j].columns.3)
                        let worldDelta=Self.xyz(rest[j]*SIMD4(t,0))
                        var changed=reshape(p+worldDelta,m)-reshape(p,m)
                        // Feet have separate authored IK root joints. Scale their
                        // stride with limb length, not torso length, so short legs
                        // do not chase the original long-legged foot trajectory.
                        if model.parents[j]<0 && model.boneNames[j].hasPrefix("IK") {
                            changed=SIMD3(worldDelta.x*m.legLength,worldDelta.y*m.legLength,worldDelta.z*m.bodyWidth)
                        }
                        t=Self.xyz(inverseRest[j]*SIMD4(changed,0))
                    }
                    t *= model.motionScale ?? 1
                    let q=simd_quatf(ix:trs[at+3],iy:trs[at+4],iz:trs[at+5],r:trs[at+6])
                    var delta=simd_float4x4(q)
                    delta.columns.0*=trs[at+7];delta.columns.1*=trs[at+8];delta.columns.2*=trs[at+9];delta.columns.3=SIMD4(t,1)
                    let local=localRest[j]*delta,parent=model.parents[j]
                    global[j]=parent<0 ? local : global[parent]*local
                    skin[j]=global[j]*inverseRest[j]
                }
                if m.breed != nil {
                    global=retargetPuppyLimbs(global:global,neutral:newRest)
                    for j in 0..<boneCount {skin[j]=global[j]*inverseRest[j]}
                }
                if clip.name.hasPrefix("sit_") {
                    if clip.name=="sit_enter" && frame==0 {sitNeutral=global}
                    if let neutral=sitNeutral {
                        let t=min(Float(frame)/clip.fps/clip.duration,1)
                        let a:Float=clip.name=="sit_enter" ? Self.smoother(t) : (clip.name=="sit_exit" ? 1-Self.smoother(t) : 1)
                        let wave=sin(t*2*Float.pi)
                        global=seatedPose(neutral:neutral,amount:a,breath:clip.name=="sit_hold" ? wave*wave*wave : 0,parameters:m)
                        for j in 0..<boneCount {skin[j]=global[j]*inverseRest[j]}
                    }
                }
                if screenClip {
                    global=screenHighFivePose(neutral:global,time:min(Float(frame)/clip.fps,clip.duration),parameters:m)
                    for j in 0..<boneCount {skin[j]=global[j]*inverseRest[j]}
                }
                if fetchClip {
                    if neutralFetchNose == nil {
                        var nose=SIMD3<Float>.zero
                        for sample in model.noseSamples {
                            let ids=samples[sample],b=bary[sample]
                            for corner in 0..<3 {
                                let v=Int(ids[corner]),p=SIMD4(bind[v],1),js=joints[v],w=weights[v]
                                var q=SIMD4<Float>.zero
                                for k in 0..<4 {q+=(skin[Int(js[k])]*p)*w[k]}
                                nose+=Self.xyz(q)*b[corner]
                            }
                        }
                        neutralFetchNose=nose/Float(model.noseSamples.count)
                    }
                    global=fetchPickupPose(neutral:global,nose:neutralFetchNose!,time:min(Float(frame)/clip.fps,clip.duration))
                    for j in 0..<boneCount {skin[j]=global[j]*inverseRest[j]}
                }
                for v in bind.indices {
                    let p=SIMD4(bind[v],1),js=joints[v],w=weights[v]
                    var q=(skin[Int(js.x)]*p)*w.x
                    q+=(skin[Int(js.y)]*p)*w.y
                    q+=(skin[Int(js.z)]*p)*w.z
                    q+=(skin[Int(js.w)]*p)*w.w
                    posed[v]=Self.xyz(q)
                }
                for i in normals.indices { normals[i] = .zero }
                for t in triangles {
                    let a=Int(t.x),b=Int(t.y),c=Int(t.z),cross=simd_cross(posed[b]-posed[a],posed[c]-posed[a])
                    normals[model.weld[a]]+=cross;normals[model.weld[b]]+=cross;normals[model.weld[c]]+=cross
                }
                for i in normals.indices { normals[i]=Self.safeNormal(normals[i]) }
                for i in 0..<n {
                    let t=samples[i],b=bary[i],a=Int(t.x),c=Int(t.y),d=Int(t.z)
                    let p=(posed[a]*b.x+posed[c]*b.y+posed[d]*b.z)*m.sizeScale
                    let norm=Self.safeNormal(normals[model.weld[a]]*b.x+normals[model.weld[c]]*b.y+normals[model.weld[d]]*b.z)
                    let at=(frame*n+i)*3
                    output[at]=p.x;output[at+1]=p.y;output[at+2]=p.z
                    normalOutput[at]=norm.x;normalOutput[at+1]=norm.y;normalOutput[at+2]=norm.z
                }
            }
            // Close tiny endpoint discrepancies already present in the source
            // authored clips; this is not the morphology deformation itself.
            let stride=n*3,end=frames*stride
            var meanNose=SIMD3<Float>.zero,meanPaw=SIMD3<Float>.zero
            var pawCount=0
            for frame in 0..<frames {
                let factor:Float=(clip.loop ?? true) ? 0.5-0.5*cos(Float(frame)/Float(frames)*Float.pi) : 0,base=frame*stride
                var minY=Float.greatestFiniteMagnitude
                for i in 0..<n {
                    let at=base+i*3
                    for axis in 0..<3 {output[at+axis]-=factor*(output[end+i*3+axis]-output[i*3+axis])}
                    minY=min(minY,output[at+1])
                }
                let lift=max(0,-minY)
                for i in 0..<n {
                    let at=base+i*3;output[at+1]+=lift
                    let p=SIMD3(output[at],output[at+1],output[at+2])
                    guard p.x.isFinite && p.y.isFinite && p.z.isFinite else { throw Self.error("Non-finite parametric skeleton output") }
                    allMin=simd_min(allMin,p);allMax=simd_max(allMax,p)
                }
                var frameNose=SIMD3<Float>.zero
                for i in model.noseSamples {let at=base+i*3;frameNose+=SIMD3(output[at],output[at+1],output[at+2])}
                meanNose+=frameNose
                if fetchClip && frame==50 {fetchNoseContact=frameNose/Float(model.noseSamples.count)}
                if let window=clip.contactWindow,window.count==2,
                   Float(frame)/clip.fps>=window[0],Float(frame)/clip.fps<=window[1] {
                    for i in pawSampleIndices { let at=base+i*3;meanPaw+=SIMD3(output[at],output[at+1],output[at+2]);pawCount+=1 }
                }
            }
            nose[clip.name]=meanNose/Float(frames*model.noseSamples.count)
            if pawCount>0 { pawContact[clip.name]=meanPaw/Float(pawCount) }
            let byteCount=frames*stride*MemoryLayout<Float>.size
            let positions=output.withUnsafeBytes { Data(bytes:$0.baseAddress!,count:byteCount) }
            let normalData=normalOutput.withUnsafeBytes { Data(bytes:$0.baseAddress!,count:byteCount) }
            baked[clip.name]=BakedMorphologyClip(positions:positions,normals:normalData,frameCount:frames,fps:clip.fps,duration:clip.duration,loop:clip.loop ?? true,endpointIncluded:clip.endpointIncluded ?? false)
        }
        return BakedMorphology(parameters:m,clips:baked,noseMean:nose,pawContactMean:pawContact,pawSampleIndices:pawSampleIndices,noseSampleIndices:model.noseSamples,fetchNoseContact:fetchNoseContact,boundsMin:allMin-SIMD3(repeating:0.035),boundsMax:allMax+SIMD3(repeating:0.035),bakeSeconds:Date.timeIntervalSinceReferenceDate-start)
    }
}
