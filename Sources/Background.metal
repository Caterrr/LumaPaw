#include <metal_stdlib>
using namespace metal;
struct BarnetGaussian {float4 positionSeed;float4 basis0Wind;float4 basis1;float4 basis2;float4 color;};
struct BarnetProjected {float4 centreAxis;float4 axisDepthSeed;float4 color;};
struct BarnetUniforms {
    float4 clock; // time, dynamics, interaction quieting, transition progress
    float4 transition; // active, incoming, count, frame aspect
    float4 camera; // reference width, height, focal length, reserved
    float4 interaction; // field centre UV, pressure, radius
};
float ease(float t){t=clamp(t,0.0f,1.0f);return t*t*t*(t*(t*6-15)+10);}
float2 rotate2(float2 p,float a){float c=cos(a),s=sin(a);return float2(c*p.x-s*p.y,s*p.x+c*p.y);}
float motionAmount(constant BarnetUniforms& u){return sqrt(u.clock.y)*(1-u.clock.z*.32)*mix(1.0f,.075f,u.camera.w);}
float scatter(constant BarnetUniforms& u){return u.transition.x>.5 ? pow(sin(u.clock.w*M_PI_F),.72f):0;}
float surfaceWeight(constant BarnetUniforms& u){
    if(u.transition.x<.5)return 1;
    return u.transition.y>.5 ? ease((u.clock.w-.52)/.40):1-ease((u.clock.w-.07)/.40);
}
float2 flowField(float2 uv,float seed,constant BarnetUniforms& u){
    float2 d=uv-u.interaction.xy;d.x*=1.6;
    float radius=max(.1f,u.interaction.w),r=length(d);
    float influence=exp(-r*r/(radius*radius))*u.interaction.z;
    float2 swirl=float2(-d.y,d.x)/float2(1.6,1);
    float2 noise=float2(sin(uv.y*12+u.clock.x*.85)+.5*sin(uv.x*7-u.clock.x*.52),cos(uv.x*11-u.clock.x*.63)+.5*sin(uv.y*6+u.clock.x*.71));
    return swirl*influence*.42+noise*.015;
}
BarnetProjected projected(BarnetGaussian g,float3 p,constant BarnetUniforms& u){
    float z=max(.25f,p.z),f=u.camera.z;
    float3 Jx=float3(f/z,0,-f*p.x/(z*z)),Jy=float3(0,f/z,-f*p.y/(z*z));
    float3 ax=float3(dot(Jx,g.basis0Wind.xyz),dot(Jx,g.basis1.xyz),dot(Jx,g.basis2.xyz));
    float3 ay=float3(dot(Jy,g.basis0Wind.xyz),dot(Jy,g.basis1.xyz),dot(Jy,g.basis2.xyz));
    float a=dot(ax,ax)+.3,b=dot(ax,ay),c=dot(ay,ay)+.3;
    float middle=(a+c)*.5,delta=sqrt(max(0.0f,(a-c)*(a-c)*.25+b*b));
    float l1=max(.3f,middle+delta),l2=max(.3f,middle-delta);
    float2 direction=abs(b)>.00001f ? normalize(float2(b,l1-a)):(a>=c ? float2(1,0):float2(0,1));
    BarnetProjected o;o.centreAxis=float4(p.xy/z*f/u.camera.xy+.5,direction*sqrt(l1)*3/u.camera.xy);
    o.axisDepthSeed=float4(float2(-direction.y,direction.x)*sqrt(l2)*3/u.camera.xy,p.z,g.positionSeed.w);o.color=g.color;return o;
}
kernel void barnetProject(device const BarnetGaussian* source [[buffer(0)]],device BarnetProjected* output [[buffer(1)]],constant BarnetUniforms& u [[buffer(2)]],uint i [[thread_position_in_grid]]){
    if(i>=uint(u.transition.z))return;
    BarnetGaussian g=source[i];float seed=g.positionSeed.w,t=u.clock.x,motion=motionAmount(u);
    float3 p=g.positionSeed.xyz;
    // Coherent XY deformation keeps the depth-sorted architecture stable while
    // the source splats visibly travel through the moving interaction field.
    float2 anchor=p.xy/max(.25f,p.z)*u.camera.z/u.camera.xy+.5;
    float2 field=flowField(anchor,seed,u)*motion;
    float breathing=1+sin(t*.29)*.042*motion;
    p.xy=p.xy*breathing+field*p.z*u.camera.xy/u.camera.z;
    p.xy-=float2(sin(t*.32)*.16,cos(t*.25)*.075)*motion;
    BarnetProjected o=projected(g,p,u);
    if(u.camera.w>.5){
        // World-space sway and small lateral camera movement reveal depth:
        // nearby dots move further on screen; immutable Z keeps sorting valid.
        float wind=sqrt(max(0.0f,u.clock.y));
        float wave=sin(p.x*1.25+p.z*.72-t*1.55);
        float gust=.65+.35*sin(t*.61+p.z*.43);
        float3 ground=g.positionSeed.xyz;
        ground.x+=(wave*.065*gust+sin(t*1.9+seed*23)*.014)*wind;
        ground.y-=(.016+.025*(.5+.5*sin(p.x*1.7+p.z*.6-t*1.8)))*wind;
        ground.xy-=float2(sin(t*.43)*.10,cos(t*.36)*.024)*wind;
        float2 delta=anchor-u.interaction.xy;
        float push=exp(-dot(delta,delta)/.015)*u.interaction.z*wind;
        ground.x+=delta.x*.40*push;ground.y-=.045*push;
        float2 uv=ground.xy/ground.z*u.camera.z/u.camera.xy+.5;
        float radius=g.basis1.w*u.camera.z/ground.z;
        float shape=g.basis2.w,angle=seed*18+.32*wave*wind;
        o.centreAxis=float4(uv,rotate2(float2(radius,0),angle)/u.camera.xy);
        o.axisDepthSeed=float4(rotate2(float2(0,radius*(.64+shape*.33)),angle)/u.camera.xy,ground.z,-1-seed);
        float horizon=smoothstep(.615f,.715f,anchor.y);
        float edge=smoothstep(-.025f,.08f,anchor.x)*(1-smoothstep(.92f,1.025f,anchor.x));
        o.color.a*=horizon*edge;
        float distanceTone=mix(.52f,1.06f,saturate((12-ground.z)/10));
        o.color.rgb*=distanceTone*(.96+.04*sin(t*.75+seed*15)*wind);

    }
    float burst=scatter(u),incoming=u.transition.y;
    float2 centre=float2(.5,.48),relative=o.centreAxis.xy-centre;
    // On scene change the actual old splats peel away into a vortex; the new
    // scene arrives from the same vortex and settles into its own structure.
    float local=burst*(.66+.34*seed);
    o.centreAxis.xy=centre+rotate2(relative,local*(incoming>.5 ? -1.15f:1.15f))*(1+local*.52);
    o.centreAxis.xy+=float2(sin(seed*81+t*.9),cos(seed*59+t*.75))*.16*local;
    float shrink=mix(mix(.80f,1.0f,u.camera.w),.22f,burst);
    o.centreAxis.zw*=shrink;o.axisDepthSeed.xy*=shrink;
    o.color.a*=mix(.90f,1.0f,u.camera.w);output[i]=o;
}
struct BarnetSplatOut {float4 position [[position]];float2 local;float4 color;float grass [[flat]];};
vertex BarnetSplatOut barnetSplatVertex(uint v [[vertex_id]],uint i [[instance_id]],device const BarnetProjected* points [[buffer(0)]]){
    const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
    BarnetProjected g=points[i];float2 corner=corners[v];
    float2 uv=g.centreAxis.xy+g.centreAxis.zw*corner.x+g.axisDepthSeed.xy*corner.y;
    BarnetSplatOut o;o.position=float4(uv.x*2-1,1-uv.y*2,0,1);o.local=corner*3;o.color=g.color;o.grass=g.axisDepthSeed.w<0 ? 1:0;return o;
}
fragment float4 barnetSplatFragment(BarnetSplatOut in [[stage_in]]){
    float d=dot(in.local,in.local);if(d>9 && in.grass<.5)discard_fragment();
    if(in.grass>.5){
        float2 q=in.local/3;
        float r2=dot(q,q),aa=max(fwidth(r2)*.7,.012f);
        float alpha=in.color.a*(1-smoothstep(1-aa,1+aa,r2));
        // A restrained lit cap and shaded underside give each dot volume.
        float3 normal=float3(q,sqrt(max(0.0f,1-r2)));
        float light=.55+.45*max(0.0f,dot(normal,normalize(float3(-.40,-.55,.85))));
        float glint=pow(max(0.0f,dot(normal,normalize(float3(-.30,-.45,.85)))),20)*.12;
        float3 color=in.color.rgb*light+float3(.65,.82,.40)*glint;
        return float4(color*alpha,alpha);
    }
    float alpha=min(.97f,in.color.a*exp(-.5*d));return float4(in.color.rgb*alpha,alpha);
}
// These are coloured ellipses from the scan, not generic luminous point dust.
// Their depth is sorted every frame on the CPU before this small population is
// drawn. They detach, flow toward the camera, enlarge and fade before wrapping.
vertex BarnetSplatOut barnetMoteVertex(uint v [[vertex_id]],uint instance [[instance_id]],device const BarnetGaussian* points [[buffer(0)]],device const uint* order [[buffer(1)]],constant BarnetUniforms& u [[buffer(2)]]){
    uint i=order[instance];BarnetGaussian g=points[i];float seed=g.positionSeed.w,t=u.clock.x;
    float motion=motionAmount(u),life=fract(t*(.095+seed*.022)+seed*7.19);
    float burst=scatter(u),travel=ease(life/.90),amount=max(travel*motion,burst*.98);
    float3 p=g.positionSeed.xyz;
    p.z=max(.32f,p.z*(1-.88*amount));
    p.xy*=1-.75*amount;
    BarnetProjected o=projected(g,p,u);
    float2 anchor=g.positionSeed.xy/max(.25f,g.positionSeed.z)*u.camera.z/u.camera.xy+.5;
    float2 centre=u.interaction.xy,relative=o.centreAxis.xy-centre;
    o.centreAxis.xy=centre+rotate2(relative,(.18+seed*.32)*amount+burst*1.3)*(1+burst*.30);
    o.centreAxis.xy+=flowField(anchor,seed,u)*(1.8+amount*2.8)*motion;
    o.centreAxis.xy+=float2(sin(seed*37+life*5.3),cos(seed*63+life*4.6))*(.016+amount*.06+burst*.12);
    float2 pa=o.centreAxis.zw*u.camera.xy,pb=o.axisDepthSeed.xy*u.camera.xy;
    float radius=length(pa),minor=length(pb);
    float nearSize=(3.5+seed*7.5)*(1+amount*3.2+burst*1.6);
    // Clamped pixel footprints keep foreground discs legible and bounded.
    float longRadius=clamp(max(radius*.45,nearSize),2.0f,38.0f+burst*16);
    float shortRadius=clamp(max(minor,nearSize*(.35+.45*seed)),longRadius*.42,longRadius*.78);
    float angle=seed*23+t*(.13+seed*.19)+amount*1.5;
    float2 a=rotate2(float2(longRadius,0),angle)/u.camera.xy;
    float2 b=rotate2(float2(0,shortRadius),angle)/u.camera.xy;
    float envelope=ease(life/.10)*(1-ease((life-.75)/.25));
    float blend=max(motion,burst);
    float alpha=(.40+seed*.40)*envelope*blend*(1-u.clock.z*.20);
    if(u.transition.x>.5)alpha*=u.transition.y>.5 ? ease((u.clock.w-.22)/.5):1-ease((u.clock.w-.45)/.5);
    float luma=dot(g.color.rgb,float3(.2126,.7152,.0722));
    float3 color=mix(float3(luma),g.color.rgb,1.08);
    const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
    float2 corner=corners[v],uv=o.centreAxis.xy+a*corner.x+b*corner.y;
    BarnetSplatOut result;result.position=float4(uv.x*2-1,1-uv.y*2,0,1);result.local=corner*2.15;result.grass=0;result.color=float4(max(color,float3(.04)),alpha);return result;
}
fragment float4 barnetMoteFragment(BarnetSplatOut in [[stage_in]]){
    float d=dot(in.local,in.local);if(d>4.62)discard_fragment();
    float alpha=in.color.a*exp(-d*.40)*(1-smoothstep(3.8f,4.62f,d));return float4(in.color.rgb*alpha,alpha);
}
kernel void barnetMix(texture2d<float,access::read> oldScene [[texture(0)]],texture2d<float,access::read> newScene [[texture(1)]],texture2d<float,access::write> scene [[texture(2)]],constant float& progress [[buffer(0)]],uint2 p [[thread_position_in_grid]]){
    if(p.x>=scene.get_width()||p.y>=scene.get_height())return;
    float oldWeight=1-ease((progress-.07)/.40),newWeight=ease((progress-.52)/.40);
    scene.write(oldScene.read(p)*oldWeight+newScene.read(p)*newWeight,p);
}
kernel void barnetDogMask(depth2d<float,access::read> depth [[texture(0)]],texture2d<float,access::write> mask [[texture(1)]],uint2 p [[thread_position_in_grid]]){
    if(p.x>=mask.get_width()||p.y>=mask.get_height())return;
    float coverage=0;uint2 start=p*4;
    for(uint y=0;y<4;y++)for(uint x=0;x<4;x++){uint2 at=min(start+uint2(x,y),uint2(depth.get_width()-1,depth.get_height()-1));coverage+=depth.read(at)<.999 ? 1.0f:0.0f;}
    mask.write(float4(coverage/16),p);
}
