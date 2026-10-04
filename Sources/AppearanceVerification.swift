import Foundation
import MetalKit
import simd

extension PupRenderer {
    /// Optional artifact verification for complete, rig-rebound custom appearances.
    func verifyAppearances(to directory:URL,photoURL:URL?)throws {
        guard let engine=morphologyEngine else{return}
        var cases:[(String,MorphologyParameters,DogCoatPalette)]=[
            ("01_默认体型",MorphologyParameters(),.amber),
            ("02_短腿长身体",MorphologyParameters(bodyLength:1.34,legLength:0.64,headSize:1.05,muzzleLength:0.90,earSize:1.3,earDroop:0.9,bodyWidth:1.05),.amber),
            ("03_修长体型",MorphologyParameters(bodyLength:1.13,legLength:1.28,headSize:0.86,muzzleLength:1.2,earSize:0.85,earDroop:0.15,bodyWidth:0.74),.amber)
        ]
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        if let photoURL {
            let p=try PhotoPersonalizer.analyze(url:photoURL)
            cases.append(("04_照片定制",p.morphology,p.palette))
            try JSONEncoder().encode(p).write(to:directory.appendingPathComponent("照片分析.json"))
        }
        let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm_srgb,width:1440,height:900,mipmapped:false);d.usage=[.renderTarget,.shaderRead];d.storageMode = .shared
        let texture=device.makeTexture(descriptor:d)!
        var report:[[String:Any]]=[]
        for (name,parameters,palette) in cases {
            let baked=try engine.bake(parameters:parameters);try applyMorphology(baked);applyPalette(palette)
            clearInput();touching=false;petBlend=0;movingBlend=0;motion.position=SIMD2(-0.35,-1.4);motion.velocity = .zero;motion.yaw = -0.22
            elapsed=0;idleTime=0;runTime=0;walkTime=0;petTime=0
            update(dt:0,size:CGSize(width:1440,height:900));memset(states.contents(),0,states.length)
            uniforms.clock.z=0;uniforms.gait.w=0
            for running in [false,true] {
                uniforms.clock.z=running ? 1:0;uniforms.gait.z=running ? 1:0
                uniforms.frames.z=UInt32(runInfo.frameCount/4);uniforms.frames.w=uniforms.frames.z
                let cb=encode(texture:texture);cb.commit();cb.waitUntilCompleted();if let error=cb.error{throw error}
                try savePNG(texture,to:directory.appendingPathComponent(name+(running ? "_跑步.png":"_站立.png")))
            }
            report.append(["name":name,"bakeSeconds":baked.bakeSeconds,"particles":count,"clips":baked.clips.keys.sorted(),"boundsMin":[baked.boundsMin.x,baked.boundsMin.y,baked.boundsMin.z],"boundsMax":[baked.boundsMax.x,baked.boundsMax.y,baked.boundsMax.z]])
        }
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("体型渲染验证.json"))
    }
}
