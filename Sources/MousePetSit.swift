import Foundation
import simd

/// Mouse presses and camera palms share one uninterrupted petting reward.
/// Both use the authored sit/stand clips; Home and wallpaper can disable it.
struct MousePetSitController {
    static let holdSeconds:Float=2
    enum Event {case sit,stand}
    private(set) var heldTime:Float=0
    private(set) var ownsSit=false
    private(set) var releaseRequested=false
    private(set) var rewardCount=0
    private var contactAnchor:SIMD2<Float>?

    func retainsContact(at point:SIMD2<Float>?)->Bool {
        guard ownsSit,!releaseRequested,let point,let contactAnchor else{return false}
        // Sitting moves the body away from a stationary pointer. Keep that
        // stroke attached; dragging away still releases the interaction.
        return simd_distance(point,contactAnchor)<0.22
    }
    mutating func reset(){let rewards=rewardCount;self=Self();rewardCount=rewards}
    @discardableResult mutating func release()->Bool {
        heldTime=0;contactAnchor=nil
        guard ownsSit,!releaseRequested else{return false}
        releaseRequested=true;return true
    }
    mutating func update(dt:Float,enabled:Bool,pressed:Bool,contact:Bool,
                         actualContact:Bool,point:SIMD2<Float>?,phase:VoiceActionPhase)->Event? {
        guard enabled else{reset();return nil}
        if ownsSit {
            if phase == .idle {reset();return nil}
            if !pressed || !contact {return release() ? .stand:nil}
            if actualContact {contactAnchor=point}
            return nil
        }
        guard phase == .idle,pressed,contact else{heldTime=0;contactAnchor=nil;return nil}
        heldTime+=max(0,dt);contactAnchor=point
        guard heldTime+0.00001>=Self.holdSeconds else{return nil}
        heldTime=Self.holdSeconds;ownsSit=true;releaseRequested=false;rewardCount+=1
        return .sit
    }
}
