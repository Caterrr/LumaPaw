#include <metal_stdlib>
using namespace metal;
struct WorldSplat {float4 position;float4 basis0;float4 basis1;float4 basis2;float4 color;};
struct ExploreUniforms {float4 right;float4 down;float4 forward;float4 eye;float4 camera;};
struct ProjectedSplat {float4 centreAxis;float4 axis;float4 color;};
kernel void exploreProject(device const WorldSplat* source [[buffer(0)]],device ProjectedSplat* projected [[buffer(1)]],constant ExploreUniforms& u [[buffer(2)]],uint i [[thread_position_in_grid]]){
 if(i>=uint(u.camera.w))return;
 WorldSplat g=source[i];float3 relative=g.position.xyz-u.eye.xyz;
 float3 p=float3(dot(relative,u.right.xyz),dot(relative,u.down.xyz),dot(relative,u.forward.xyz));
 ProjectedSplat o;o.centreAxis=0;o.axis=0;o.color=0;
 if(p.z<.045f){projected[i]=o;return;}
 float3x3 view=transpose(float3x3(u.right.xyz,u.down.xyz,u.forward.xyz));
 float3 b0=view*g.basis0.xyz,b1=view*g.basis1.xyz,b2=view*g.basis2.xyz;
 float f=u.camera.z,z=p.z;float3 jx=float3(f/z,0,-f*p.x/(z*z)),jy=float3(0,f/z,-f*p.y/(z*z));
 float3 ax=float3(dot(jx,b0),dot(jx,b1),dot(jx,b2)),ay=float3(dot(jy,b0),dot(jy,b1),dot(jy,b2));
 float a=dot(ax,ax)+.3,b=dot(ax,ay),c=dot(ay,ay)+.3,mid=(a+c)*.5,delta=sqrt(max(0.0f,(a-c)*(a-c)*.25+b*b));
 float l1=max(.3f,mid+delta),l2=max(.3f,mid-delta);
 float2 dir=abs(b)>.00001 ? normalize(float2(b,l1-a)):(a>=c ? float2(1,0):float2(0,1));
 float2 uv=p.xy/z*f/u.camera.xy+.5;float radius=min(260.0f,sqrt(l1)*3);
 if(any(uv<float2(-.5))||any(uv>float2(1.5))){projected[i]=o;return;}
 o.centreAxis=float4(uv,dir*radius/u.camera.xy);
 o.axis=float4(float2(-dir.y,dir.x)*min(260.0f,sqrt(l2)*3)/u.camera.xy,0,0);
 o.color=float4(pow(g.color.rgb,float3(2.2)),g.color.a);projected[i]=o;
}
struct ExploreOut {float4 position [[position]];float2 local;float4 color;};
vertex ExploreOut exploreVertex(uint v [[vertex_id]],uint i [[instance_id]],device const ProjectedSplat* splats [[buffer(0)]],device const uint* order [[buffer(1)]]){
 const float2 corners[6]={float2(-1,-1),float2(1,-1),float2(-1,1),float2(-1,1),float2(1,-1),float2(1,1)};
 ProjectedSplat g=splats[order[i]];float2 corner=corners[v];float2 uv=g.centreAxis.xy+g.centreAxis.zw*corner.x+g.axis.xy*corner.y;
 ExploreOut o;o.position=float4(uv.x*2-1,1-uv.y*2,0,1);o.local=corner*3;o.color=g.color;return o;
}
fragment float4 exploreFragment(ExploreOut in [[stage_in]]){
 float r=dot(in.local,in.local);if(r>9)discard_fragment();float alpha=min(.99f,in.color.a*exp(-r*.5));return float4(in.color.rgb*alpha,alpha);
}
