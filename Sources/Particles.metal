#include <metal_stdlib>
using namespace metal;
struct State { float4 offset, velocity; };
struct Uniforms {
    float4 clock,viewport,root;
    uint4 frames;
    float4 animation;
    uint4 otherFrames;
    float4 gait;
    float4 touch;
    uint4 clipCounts; // idle, run, walk, pet
    float4 effects;  // normalized speed, petting duration, turn rate, reserved
    float4 praise; // heart emitter xy, age, active
    float4 highFiveTouch; // contact xy, age, active
    float4 background;
    float4 ball,ballInfo;
    float4 presentation; // root-anchored size and close-camera perspective
};
float3 stream(float3 p,float t) {
    return float3(sin(p.y*1.35+t*.33)+cos(p.z*1.7-t*.27),sin(p.z*1.25+t*.29)+cos(p.x*1.32+t*.23),sin(p.x*1.4-t*.31)+cos(p.y*1.2+t*.24))*.5;
}
float3 rotateY(float3 p,float a){return float3(p.x*cos(a)+p.z*sin(a),p.y,-p.x*sin(a)+p.z*cos(a));}
float3 cubicPose(uint i,device const packed_float3* clip,uint a,uint b,float t,uint frameCount,uint n,bool nonloop=false){
    uint frames=max(frameCount,1u);a%=frames;b%=frames;
    float3 p0=float3(clip[(nonloop ? (a>0 ? a-1:0):((a+frames-1)%frames))*n+i]);
    float3 p1=float3(clip[a*n+i]),p2=float3(clip[b*n+i]);
    float3 p3=float3(clip[(nonloop ? min(b+1,frames-1):((b+1)%frames))*n+i]);
    t=clamp(t,0.0f,1.0f);float t2=t*t,t3=t2*t;
    float3 p=.5f*((2*p1)+(-p0+p2)*t+(2*p0-5*p1+4*p2-p3)*t2+(-p0+3*p1-3*p2+p3)*t3);
    // Cubic interpolation cannot overshoot a paw's neighboring contact poses.
    // CPU hit testing uses this identical formula and component-wise clamp.
    return clamp(p,min(p1,p2),max(p1,p2));
}
float3 blendPose(uint i,device const packed_float3* idle,device const packed_float3* run,device const packed_float3* walk,device const packed_float3* pet,constant Uniforms& u){
    uint n=uint(u.clock.w);
    float3 a=cubicPose(i,idle,u.frames.x,u.frames.y,u.animation.x,u.clipCounts.x,n);
    if(u.clock.z>0){
        float3 b=cubicPose(i,run,u.frames.z,u.frames.w,u.animation.y,u.clipCounts.y,n);
        float3 w=cubicPose(i,walk,u.otherFrames.x,u.otherFrames.y,u.gait.x,u.clipCounts.z,n);
        a=mix(a,mix(w,b,u.gait.z),u.clock.z);
    }
    if(u.gait.w>0){
        float3 p=cubicPose(i,pet,u.otherFrames.z,u.otherFrames.w,u.gait.y,u.clipCounts.w,n,u.effects.w>.5);
        a=mix(a,p,u.gait.w);
    }
    return a;
}
float3 base(uint i,device const packed_float3* idle,device const packed_float3* run,device const packed_float3* walk,device const packed_float3* pet,constant Uniforms& u){
    return rotateY(blendPose(i,idle,run,walk,pet,u),u.root.z)*u.presentation.x+float3(u.root.xy,0);
}
// Projection happens after affine pose reconstruction so the recovered depth
// mesh and the original barycentric particle samples stay on the same surface.
float3 projectDog(float3 p,constant Uniforms& u){
    float denominator=max(.65f,1-(p.z/max(.1f,u.presentation.x))*u.presentation.y);
    p.xy=u.root.xy+(p.xy-u.root.xy)/denominator;
    return p;
}
float4 clipDog(float3 p,constant Uniforms& u){
    p=projectDog(p,u);
    return float4(p.x/(u.viewport.z*.5),p.y/(u.viewport.w*.5),.5-p.z*.025,1);
}
kernel void simulate(device const packed_float3* idle [[buffer(0)]],device const packed_float3* run [[buffer(1)]],device State* s [[buffer(2)]],constant Uniforms& u [[buffer(3)]],device const float4* seeds [[buffer(4)]],device const packed_float3* walk [[buffer(8)]],device const packed_float3* pet [[buffer(10)]],uint i [[thread_position_in_grid]]){
    if(i>=uint(u.clock.w))return;
    float dt=u.clock.y;if(dt<=0)return;
    float3 home=base(i,idle,run,walk,pet,u);
    float radius=max(u.touch.w,.001f);
    float proximity=1-smoothstep(radius*.28,radius,length(home.xy-u.touch.xy));
    // A small extra population drifts from the petting area. Body particles
    // stay bound to the animated dog: no push force, disintegration or holes.
    float target=seeds[i].y>.91 ? proximity*u.touch.z:0;
    float strength=mix(s[i].velocity.w,target,1-exp(-dt*(target>0 ? 5.0f:1.8f)));
    s[i].offset=float4(0);
    s[i].velocity=float4(0,0,0,strength);
}
kernel void reconstructSurface(device const packed_float3* idle [[buffer(0)]],device const packed_float3* run [[buffer(1)]],constant Uniforms& u [[buffer(3)]],device const packed_float3* walk [[buffer(8)]],device const packed_float3* reaction [[buffer(10)]],device const uint2* ranges [[buffer(12)]],device const uint2* coefficients [[buffer(13)]],device float4* vertices [[buffer(14)]],uint i [[thread_position_in_grid]]){
    uint2 range=ranges[i];float3 p=0;
    for(uint j=0;j<range.y;j++){
        uint2 coefficient=coefficients[range.x+j];
        p+=base(coefficient.x,idle,run,walk,reaction,u)*as_type<float>(coefficient.y);
    }
    vertices[i]=float4(p,1);
}
struct SurfaceOut {float4 position [[position]];};
vertex SurfaceOut surfaceVertex(uint i [[vertex_id]],device const float4* vertices [[buffer(0)]],constant Uniforms& u [[buffer(3)]]){
    float3 p=vertices[i].xyz;SurfaceOut o;
    o.position=clipDog(p,u);return o;
}
fragment void surfaceFragment(){}
// A bounded, continuous displacement of the MAIN coat grains, in dog-local
// tangents. Each grain wanders a few screen pixels, without a lifetime reset.
// Facial features keep their exact pose; skeletal hit testing uses the skin.
float3 driftingCoatPosition(float3 home,float3 localNormal,float seed,int material,constant Uniforms& u){
    if(material>=2)return home;
    localNormal=length(localNormal)>.001 ? normalize(localNormal):float3(0,1,0);
    float3 tangent=normalize(cross(abs(localNormal.y)<.90 ? float3(0,1,0):float3(1,0,0),localNormal));
    float3 bitangent=cross(localNormal,tangent);
    float random=fract(sin(seed*271.9+13.2)*43758.5453);
    float phase=u.clock.x*(1.05+random*.65)+seed*47;
    float activity=clamp(u.effects.x*.55+u.touch.z*.45,0.0f,1.0f);
    float amplitude=(.78+.22*random)*(1+activity*.12);
    float3 offset=tangent*(sin(phase)*.030+sin(phase*.53+seed*19)*.008)
                 +bitangent*(cos(phase*.81+seed*11)*.024)
                 +localNormal*(.008+.004*sin(phase*.67+seed*7));
    return home+rotateY(offset*amplitude,u.root.z)*u.presentation.x;
}
struct VertexOut {float4 position [[position]];float pointSize [[point_size]];float4 color;float2 sparkle;float depthTolerance;};
vertex VertexOut particleVertex(uint vid [[vertex_id]],device const packed_float3* idle [[buffer(0)]],device const packed_float3* run [[buffer(1)]],device const State* states [[buffer(2)]],constant Uniforms& u [[buffer(3)]],device const float4* seeds [[buffer(4)]],device const float4* colors [[buffer(5)]],device const packed_float3* normals [[buffer(6)]],device const packed_float3* runNormals [[buffer(7)]],device const packed_float3* walk [[buffer(8)]],device const packed_float3* walkNormals [[buffer(9)]],device const packed_float3* pet [[buffer(10)]],device const packed_float3* petNormals [[buffer(11)]]){
    uint n=uint(u.clock.w),i=vid%n,layer=vid/n;
    const float pi=3.14159265359f;
    float seed=seeds[i].y,t=u.clock.x;
    float random=fract(sin(seed*127.1+19.7)*43758.5453);
    float random2=fract(sin(seed*311.7+71.2)*19642.3491);
    float3 home=base(i,idle,run,walk,pet,u);
    float3 mixedNormal=blendPose(i,normals,runNormals,walkNormals,petNormals,u);
    float3 normal=rotateY(mixedNormal/max(length(mixedNormal),.001f),u.root.z);
    float3 p=home;
    float rim=pow(1-abs(normal.z),1.55f);
    // Surface-space waves travel over the coat even when the dog is resting.
    // Independent phases avoid a whole-body blink; motion only raises amplitude.
    float3 bind=float3(idle[i]);
    float activity=clamp(u.effects.x*.65+u.touch.z*.50+abs(u.effects.z)*.06,0.0f,1.0f);
    float flowPhase=bind.x*4.1+bind.y*2.7+sin(bind.z*5.3)*.65+t*1.85;
    float flow=pow(.5+.5*sin(flowPhase),5.0f);
    float twinkle=pow(.5+.5*sin(t*(1.7+random*1.4)+seed*173),7.0f);
    float shimmer=.5+.5*sin(flowPhase*.55+seed*6.28);
    float alpha=(.48+rim*.35)*colors[i].w*(.89+.11*sin(t*.55+seed*31));
    float3 coat=colors[i].rgb;
    int material=int(seeds[i].w+.5);
    // True animated depth below removes the far-side eye and overlapping limbs.
    // Normal weighting now only controls soft surface light, not visibility.
    alpha*=mix(.68f,1.0f,smoothstep(-.15f,.35f,normal.z));
    if(material==3 || material==4)alpha*=1.3;
    float3 color=coat*(.91+.09*shimmer)+coat*rim*shimmer*.23;
    float darkCoat=1-smoothstep(.10f,.26f,max(coat.r,max(coat.g,coat.b)));
    color+=float3(.065,.075,.090)*darkCoat*(.35+.65*rim);
    float pixelScale=u.viewport.x/u.viewport.z*u.animation.z*u.presentation.x;
    float pointSize=clamp(seeds[i].x*3.20*pixelScale*(1+.035*p.z),1.35f,10.0f);
    float glint=0;
    if(material<2 && layer==0){
        // The primary, visible body grains really move. Their bounded drift
        // follows the animated skin and preserves the original coat colors.
        p=driftingCoatPosition(home,mixedNormal,seed,material,u);
        float localTouch=(1-smoothstep(.10f,max(.11f,u.touch.w),length(home.xy-u.touch.xy)))*u.touch.z;
        float life=.88+.15*shimmer+flow*(.16+.10*activity)+twinkle*(.10+.07*activity);
        color*=life;alpha*=.92+.08*shimmer;
        color+=coat*localTouch*(.10+.20*flow);
    }
    if(layer==1){
        // Tiny, asynchronous pinpricks skim the local fur, with roots intact.
        // Build tangents in dog space so a turn carries the sparkle with it.
        float3 localNormal=mixedNormal/max(length(mixedNormal),.001f);
        float3 tangent=normalize(cross(abs(localNormal.y)<.90 ? float3(0,1,0):float3(1,0,0),localNormal));
        tangent=rotateY(tangent,u.root.z);float3 bitangent=cross(normal,tangent);
        float wander=t*(1.1+random*.55)+seed*47;
        float coatMask=material<2 ? 1.0f:0.0f;
        p=driftingCoatPosition(home,mixedNormal,seed,material,u);
        p+=normal*(.006+.006*twinkle)*u.presentation.x;
        p+=(tangent*sin(wander)*.010+bitangent*cos(wander*.83)*.006)*u.presentation.x*coatMask;
        float selection=smoothstep(.77f,.94f,random2)*coatMask;
        glint=selection*twinkle*(.62+.38*flow)*(1+.30*activity);
        alpha*=.10+glint*1.10;
        // Coat-tinted glints remain readable on the dark saddle; only their
        // sparse highlights receive a little warm light, never the full coat.
        color=coat*(1.0+glint*.85)+float3(.20,.17,.12)*glint*darkCoat;
        pointSize=mix(pointSize*.64,2.0+glint*3.4,smoothstep(.08f,.62f,glint));
    }else if(layer==2){
        // A light halo of drifting coat-colored motes, additional to the skin.
        float life=fract(t*.15+random);
        float envelope=pow(sin(life*pi),1.8f);
        p+=(normal*(.08+life*.24)+stream(home,t)*(.045+life*.12))*u.presentation.x;
        p+=rotateY(float3(sin(seed*173+life*4.2)*(.08+life*.10),life*.40,cos(seed*91+life*3.6)*.08),u.root.z)*u.presentation.x;
        alpha*=seed>.977 ? envelope*.44:0;
        color=mix(coat,float3(.98,.68,.34),.28);
        pointSize=clamp(1.7+random2*1.4,1.7f,3.2f);
    }else if(layer==3){
        // A short, sparse trail follows the direction of the dog. The source
        // body remains exactly on its rig; only these extra motes lag behind.
        float speed=clamp(u.effects.x,0.0f,1.0f),life=fract(t*.72+random);
        float envelope=pow(sin(life*pi),1.4f);
        p+=rotateY(float3(-(.05+life*.48)*speed,.015+life*.055,0),u.root.z);
        p+=normal*.045+float3(0,sin(seed*57+life*5)*.018,0);
        alpha*=seed>.963 ? envelope*speed*.32:0;
        color=mix(coat,float3(.90,.60,.26),.12);
        pointSize=clamp(1.25+random2*1.3,1.25f,3.5f);
    }else if(layer==7){
        // Each heart is 112 independent luminous grains, mostly along its
        // outline with a sparse interior. There is no filled heart billboard.
        uint heart=i/112,grain=i%112;
        float heartSeed=fract(sin(float(heart)*17.31+8.7)*43758.5453);
        float age=u.praise.z-float(heart)*.135,life=clamp(age/2.6f,0.0f,1.0f);
        float lane=float(int(heart%3)-1),theta=float(grain%80)/80.0f*2*pi;
        float radius=grain<80 ? 1.0f:sqrt(random)*.84;
        float2 curve=float2(16*sin(theta)*sin(theta)*sin(theta),13*cos(theta)-5*cos(2*theta)-2*cos(3*theta)-cos(4*theta))/18.0f;
        float size=(.20+heartSeed*.075)*(1+life*.20);
        float2 center=u.praise.xy+float2(lane*.40+sin(life*4+heartSeed*5)*life*.18,.16+life*(1.25+heartSeed*.65));
        p=float3(center+curve*radius*size,.9);
        alpha=(heart<8 && age>0 && age<2.6 ? 1.0f:0.0f)*u.praise.w*pow(sin(life*pi),.75f)*(.40+.60*random);
        color=mix(float3(1.8,.12,.42),float3(1.4,.47,.67),random2);
        glint=pow(.5+.5*sin(t*(3+random*2)+seed*173),10.0f);
        pointSize=1.25+random2*1.10+glint*3.0;
    }else if(layer==6){
        // A one-shot ring and sparks originate at the verified paw contact.
        // These are additional particles, never displaced body samples.
        float age=max(0.0f,u.highFiveTouch.z),life=clamp(age/1.2f,0.0f,1.0f);
        float angle=random*2*pi;
        bool ring=i%3==0;
        float travel=ring ? .08+life*.95 : .03+age*(.35+random2*1.1);
        p=float3(u.highFiveTouch.xy+float2(cos(angle),sin(angle))*travel,.7);
        if(!ring)p.y-=age*age*.18;
        alpha=u.highFiveTouch.w*(i<560 ? 1.0f:0.0f)*pow(1-life,2.2f)*(ring ? .60f:1.05f);
        color=mix(float3(1.25,.72,.21),float3(1.15,1.03,.67),random2);
        glint=ring ? .10f:.80f;
        pointSize=(ring ? 2.2f:3.6f)*(1-life*.30);
    }else if(layer>=4){
        // Two interleaved rising curves share the same local emitter strength.
        // They read as fine gold/coat-tinted ribbons close to the petting hand,
        // while every original surface point stays on the animated animal.
        float lane=layer==4 ? 1.0f:-1.0f;
        float life=fract(t*(.27+random2*.07)+random+float(layer)*.43);
        float envelope=pow(sin(life*pi),1.15f);
        float theta=life*pi*1.75+random2*.65+min(u.effects.y,8.0f)*.06;
        float radius=.16+life*.50;
        float rise=life*(.85+random2*.38);
        p+=normal*(.065+life*.13);
        p+=float3(lane*sin(theta)*radius,rise+cos(theta)*radius*.25,
                  cos(theta)*radius*.18);
        p+=stream(home,t)*life*.045;
        alpha=states[i].velocity.w*envelope*(layer==4 ? .82f:.57f)*colors[i].w;
        float3 gold=float3(1.12,.74,.32);
        color=mix(coat*1.12,gold,layer==4 ? .54f:.32f);
        glint=pow(.5+.5*sin(t*2.4+seed*173),10.0f)*.65;
        pointSize=clamp(2.3+random2*1.4+glint*2.5,2.3f,6.3f);
    }
    // Wallpaper can tighten surrounding particles without changing the coat.
    if(layer>=2 && layer<=5){
        float ambientScale=clamp(u.presentation.z,0.1f,1.0f);
        p=home+(p-home)*ambientScale;
        pointSize*=ambientScale;
    }
    VertexOut o;o.position=layer<6 ? clipDog(p,u):float4(p.x/(u.viewport.z*.5),p.y/(u.viewport.w*.5),.5-p.z*.025,1);
    o.pointSize=pointSize;o.color=float4(color,alpha);o.sparkle=float2(glint,seed*pi);
    // Allow the tiny coat displacement against the undeformed occlusion skin.
    // Eyes/nose retain the previous strict depth tolerance.
    o.depthTolerance=layer<2 ? (material<2 ? .0015f:((material>=3 && material<=5) ? .00048f:.00090f)):-1.0f;
    return o;
}
fragment float4 particleFragment(VertexOut in [[stage_in]],float2 point [[point_coord]],depth2d<float> surfaceDepth [[texture(0)]]) {
    float visible=1;
    if(in.depthTolerance>0){
        float depth=surfaceDepth.read(uint2(in.position.xy));
        visible=1-smoothstep(in.depthTolerance*.25,in.depthTolerance,in.position.z-depth);
        if(visible<.001)discard_fragment();
    }
    float2 q=point*2-1;float d=length(q);if(d>1)discard_fragment();
    float soft=exp(-d*d*3.2)*(1-smoothstep(.78f,1.0f,d));
    float a=in.sparkle.y,c=cos(a),s=sin(a);
    float2 rotated=float2(q.x*c-q.y*s,q.x*s+q.y*c);
    float rays=max(exp(-abs(rotated.x)*24-abs(rotated.y)*2.8),
                   exp(-abs(rotated.y)*24-abs(rotated.x)*2.8));
    float alpha=(soft+rays*in.sparkle.x*.65)*in.color.a*visible;
    return float4(in.color.rgb*alpha,alpha);
}
// Short coat fibres are additional surface-bound particle strands. Their
// granular, tapered shape produces the furry contour without a blurred halo.
struct FurOut {float4 position [[position]];float2 local;float4 color;float seed;float rootDepth;};
vertex FurOut furVertex(uint vid [[vertex_id]],uint i [[instance_id]],device const packed_float3* idle [[buffer(0)]],device const packed_float3* run [[buffer(1)]],constant Uniforms& u [[buffer(3)]],device const float4* seeds [[buffer(4)]],device const float4* colors [[buffer(5)]],device const packed_float3* normals [[buffer(6)]],device const packed_float3* runNormals [[buffer(7)]],device const packed_float3* walk [[buffer(8)]],device const packed_float3* walkNormals [[buffer(9)]],device const packed_float3* pet [[buffer(10)]],device const packed_float3* petNormals [[buffer(11)]]){
    const float2 corners[6]={float2(-1,0),float2(1,0),float2(-1,1),float2(-1,1),float2(1,0),float2(1,1)};
    float2 corner=corners[vid%6];float seed=seeds[i].y;
    float random=fract(sin(seed*271.9+13.2)*43758.5453);
    float3 home=base(i,idle,run,walk,pet,u);
    float3 n=blendPose(i,normals,runNormals,walkNormals,petNormals,u);
    n=rotateY(n/max(length(n),.001f),u.root.z);
    float rim=pow(1-abs(n.z),.85f);
    float length=(.014+.032*random)*(.45+.55*rim)*u.presentation.x;
    float wind=sin(u.clock.x*1.7+seed*45)*.05+u.effects.x*.13;
    float lean=sin(seed*391.7)*.28;
    float3 tip=home+n*length+float3(-n.y,n.x,0)*(lean*length)+rotateY(float3(-wind*length,length*.08,0),u.root.z);
    float3 a=projectDog(home,u),b=projectDog(tip,u);
    float2 direction=b.xy-a.xy;
    // Face-on grains follow a short upward grooming direction.
    if(dot(direction,direction)<.000015)direction=float2(sin(seed*27)*.005,.012)*u.presentation.x;
    float2 tangent=normalize(direction),side=float2(-tangent.y,tangent.x);
    float halfWidth=(.40+random*.33)*u.viewport.z/u.viewport.x;
    float2 xy=a.xy+direction*corner.y+side*corner.x*halfWidth*(1-.65*corner.y);
    float depth=mix(home.z,tip.z,corner.y);
    FurOut o;o.position=float4(xy.x/(u.viewport.z*.5),xy.y/(u.viewport.w*.5),.5-depth*.025,1);
    o.local=corner;o.seed=seed;o.rootDepth=.5-home.z*.025;
    float alpha=(.25+.28*rim)*smoothstep(-.35f,.08f,n.z);
    if(seeds[i].w>1.5)alpha=0; // eyes, nose, mouth and paw pads remain crisp.
    float3 coat=colors[i].rgb*(.64+.30*random);
    float dark=1-smoothstep(.1f,.26f,max(coat.r,max(coat.g,coat.b)));
    coat+=float3(.05,.055,.065)*dark;
    float3 bind=float3(idle[i]);
    float wave=pow(.5+.5*sin(bind.x*4.1+bind.y*2.7+u.clock.x*1.85-corner.y*2.4),5.0f);
    coat*=.93+.22*wave;
    o.color=float4(coat,alpha);return o;
}
fragment float4 furFragment(FurOut in [[stage_in]],depth2d<float> surfaceDepth [[texture(0)]]){
    if(in.color.a<.001)discard_fragment();
    float depth=surfaceDepth.read(uint2(in.position.xy));
    float visible=1-smoothstep(.0006f,.0017f,in.position.z-depth);
    float edge=1-smoothstep(.35f,1.0f,abs(in.local.x));
    float grain=.66+.34*pow(.5+.5*cos(in.local.y*22+in.seed*40),2.0f);
    float taper=(1-smoothstep(.68f,1.0f,in.local.y));
    float alpha=in.color.a*edge*grain*taper*visible;
    return float4(in.color.rgb*alpha,alpha);
}

kernel void downsample(texture2d<float,access::read> src [[texture(0)]],texture2d<float,access::write> dst [[texture(1)]],uint2 p [[thread_position_in_grid]]){
    if(p.x>=dst.get_width()||p.y>=dst.get_height())return;
    uint2 base=p*4;float3 sum=0;
    for(uint y=0;y<4;y++)for(uint x=0;x<4;x++){
        uint2 at=min(base+uint2(x,y),uint2(src.get_width()-1,src.get_height()-1));
        float3 color=src.read(at).rgb;
        // Four Gentlemen's low-threshold bloom extraction; source particles,
        // fur, coat shading and background compositing remain unchanged.
        sum+=max(color-.16f,0.0f);
    }
    dst.write(float4(sum/16,1),p);
}
struct QuadOut{float4 position [[position]];float2 uv;};
vertex QuadOut fullscreen(uint i [[vertex_id]]){float2 uv=float2((i<<1)&2,i&2);QuadOut o;o.position=float4(uv*2-1,0,1);o.uv=float2(uv.x,1-uv.y);return o;}
fragment float4 finish(QuadOut in [[stage_in]],texture2d<float> scene [[texture(0)]],texture2d<float> bloom [[texture(1)]],texture2d<float> background [[texture(2)]],texture2d<float> motes [[texture(3)]],depth2d<float> dogDepth [[texture(4)]],texture2d<float> dogMask [[texture(5)]],constant Uniforms& u [[buffer(0)]]){
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 pixel=1.0f/float2(scene.get_width(),scene.get_height());
    float3 soft=scene.sample(s,in.uv).rgb*.80;
    soft+=(scene.sample(s,in.uv+float2(pixel.x,0)).rgb+scene.sample(s,in.uv-float2(pixel.x,0)).rgb+scene.sample(s,in.uv+float2(0,pixel.y)).rgb+scene.sample(s,in.uv-float2(0,pixel.y)).rgb)*.05;
    float3 c=soft+bloom.sample(s,in.uv).rgb*u.animation.w;
    // A shared exposure curve preserves the photograph's hue and the warm
    // particles' color as they brighten instead of washing each channel white.
    float peak=max(c.r,max(c.g,c.b));
    c*=peak>.00001 ? (1-exp(-peak*1.30))/peak:1.30f;
    if(u.background.x>0){
        // Aspect-fill the fixed perspective without distorting the scan.
        float aspect=u.viewport.x/u.viewport.y;
        float2 scale=aspect>1.6 ? float2(1,1.6/aspect):float2(aspect/1.6,1);
        float2 uv=(in.uv-.5)*scale+.5;
        // Ground band follows the window bottom even in tall or wide windows.
        uv=mix(uv,in.uv,u.background.w);
        float3 b=pow(clamp(background.sample(s,uv).rgb,0.0f,1.0f),float3(2.2));
        float3 daylight=b;
        float luma=dot(b,float3(.2126,.7152,.0722));
        b=mix(float3(luma),b,.88)*float3(.98,1.02,1.0);
        // Limit environmental highlights independently from the dog's bloom.
        b=b/(1+b*.90)*.34;
        float4 flecks=motes.sample(s,uv);
        float3 flakeColor=pow(clamp(flecks.rgb/max(.001f,flecks.a),0.0f,1.0f),float3(1.7));
        b+=flakeColor*flecks.a*.42*(1-u.background.y*.20);
        float edge=smoothstep(0.0f,.16f,in.uv.x)*smoothstep(0.0f,.16f,1-in.uv.x);
        float vertical=smoothstep(.04f,.24f,in.uv.y)*smoothstep(.02f,.22f,1-in.uv.y);
        float3 tone=float3(.002,.004,.005)*vertical;
        b=(b*(.28+.72*edge)*vertical+tone)*u.background.x*(1-u.background.y*.25);
        // Grass particles keep bright natural greens against the black ground band.
        float daylightLuma=dot(daylight,float3(.2126,.7152,.0722));
        daylight=max(float3(0),mix(float3(daylightLuma),daylight,1.12f));
        daylight=daylight*1.20f/(1+daylight*.16f);
        daylight*=smoothstep(.60f,.68f,in.uv.y);
        b=mix(b,daylight*u.background.x,u.background.w);
        uint2 at=min(uint2(in.position.xy),uint2(dogDepth.get_width()-1,dogDepth.get_height()-1));
        float occupied=dogDepth.read(at)<.999 ? 1.0f:0.0f;
        float softMask=dogMask.sample(s,in.uv).r;
        float protection=(1-occupied)*(1-smoothstep(0.0f,.58f,softMask)*.94);
        c+=b*protection;
    }
    return float4(c,1);
}

// A thin white blade that fades with time, without particles to collect.
struct TrailVertex {float4 positionSide;};
struct TrailOut {float4 position [[position]];float side;float alpha;};
vertex TrailOut lightTrailVertex(uint i [[vertex_id]],device const TrailVertex* trail [[buffer(0)]],constant Uniforms& u [[buffer(3)]]){
    float4 v=trail[i].positionSide;TrailOut o;
    o.position=float4(v.x/(u.viewport.z*.5),v.y/(u.viewport.w*.5),.45,1);
    o.side=v.z;o.alpha=v.w;return o;
}
fragment float4 lightTrailFragment(TrailOut in [[stage_in]]){
    float a=(1-smoothstep(.2f,1.0f,abs(in.side)))*in.alpha*.85;
    return float4(float3(a),a);
}
struct BallOut {float4 position [[position]];float2 uv;uint shadow [[flat]];};
vertex BallOut ballVertex(uint i [[vertex_id]],uint instance [[instance_id]],constant Uniforms& u [[buffer(3)]]){
    const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
    BallOut o;float2 uv=corners[i];float r=u.ball.w;
    float2 center=instance==0 ? float2(u.ball.x,u.ballInfo.z+r*.12):u.ball.xy;
    float2 extent=instance==0 ? float2(r*1.45,r*.32):float2(r);
    float2 p=center+uv*extent;
    o.position=float4(p.x/(u.viewport.z*.5),p.y/(u.viewport.w*.5),.4,1);o.uv=uv;o.shadow=instance==0;return o;
}
fragment float4 ballFragment(BallOut in [[stage_in]],constant Uniforms& u [[buffer(3)]]){
    float r2=dot(in.uv,in.uv);if(r2>1)discard_fragment();
    if(in.shadow){float a=exp(-r2*3)*.30/(1+max(0.0f,u.ball.y-u.ballInfo.z-u.ball.w)*1.5);return float4(0,0,0,a);}
    float3 n=float3(in.uv,sqrt(max(0.0f,1-r2)));
    float angle=u.ballInfo.y*.25;float2 p=float2(n.x*cos(angle)-n.y*sin(angle),n.x*sin(angle)+n.y*cos(angle));
    float seam=1-smoothstep(.025f,.075f,abs(abs(p.x)-(.48-.20*cos(p.y*3.1))));
    float light=.34+.66*max(0.0f,dot(n,normalize(float3(-.45,.65,.75))));
    float grain=fract(sin(dot(in.position.xy,float2(12.9898,78.233)))*43758.5453);
    float3 color=mix(float3(.64,.86,.13),float3(.95,.97,.80),seam)*light*(.94+.06*grain);
    float a=1-smoothstep(.94f,1.0f,r2);return float4(color*a,a);
}
