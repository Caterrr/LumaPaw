import Foundation

/// Finish the feet for interrupted motion (lost input, touch, or window bounds).
/// Normal pursuit arrivals complete their physical stride in Pursuit itself.
struct GaitLanding {
    private(set) var active=false
    private var armed=false,time:Float=0,duration:Float=0.3,start:Float=0,remaining:Float=0,weight:Float=0,rate:Float=1,tangent:Float=1
    mutating func reset(){self=Self()}
    mutating func advance(dt:Float,distance:Float,stride:Float,phase:Float,blend:Float,speed:Float)->(phase:Float,blend:Float) {
        guard dt>0 else{return(phase,blend)}
        let cycles=max(0,distance)/max(0.1,stride)
        if speed>0.35 {
            armed=true;active=false
            rate+=(cycles/dt-rate)*(1-exp(-dt*8))
        }
        if armed && !active && speed<0.12 {
            armed=false;active=true;time=0;start=phase;remaining=1-phase;weight=blend
            duration=min(0.48,max(0.18,remaining/max(1.4,rate)))
            tangent=min(2.5,max(0.2,rate*duration/max(0.01,remaining)))
        }
        if active {
            time=min(duration,time+dt);let t=time/duration,t2=t*t,t3=t2*t
            let q=min(1,max(0,(-2*t3+3*t2)+(t3-2*t2+t)*tangent))
            let fade=min(1,max(0,(t-0.55)/0.45)),smooth=fade*fade*(3-2*fade)
            let next=(start+remaining*q).truncatingRemainder(dividingBy:1)
            if t>=1{active=false;return(0,0)}
            return(next,weight*(1-smooth))
        }
        return((phase+cycles).truncatingRemainder(dividingBy:1),blend)
    }
}
