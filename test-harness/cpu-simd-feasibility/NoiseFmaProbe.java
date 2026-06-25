// Probe C: keep gather scalar, but tighten the arithmetic with Math.fma (-> AVX2 vfmadd)
// and a flattened gradient table (no int[][] indirection). Measures the realistic win
// available on gather-bound real noise. Must stay within tolerance vs the stock formula.
import java.util.concurrent.ThreadLocalRandom;

public class NoiseFmaProbe {
    static final int[][] GRAD = {
        {1,1,0},{-1,1,0},{1,-1,0},{-1,-1,0},{1,0,1},{-1,0,1},{1,0,-1},{-1,0,-1},
        {0,1,1},{0,-1,1},{0,1,-1},{0,-1,-1},{1,1,0},{0,-1,1},{-1,1,0},{0,-1,-1}};
    static final double[] GX=new double[16],GY=new double[16],GZ=new double[16];
    static { for(int i=0;i<16;i++){GX[i]=GRAD[i][0];GY[i]=GRAD[i][1];GZ[i]=GRAD[i][2];} }
    static byte[] perm=new byte[256];
    static double xo,yo,zo;
    static { var r=ThreadLocalRandom.current(); xo=r.nextDouble()*256;yo=r.nextDouble()*256;zo=r.nextDouble()*256;
        for(int i=0;i<256;i++)perm[i]=(byte)i;
        for(int i=0;i<256;i++){int o=r.nextInt(256-i);byte t=perm[i];perm[i]=perm[i+o];perm[i+o]=t;}}
    static int p(int x){return perm[x&0xFF]&0xFF;}
    static int floor(double v){int i=(int)v;return v<i?i-1:i;}
    static double smoothstep(double x){return x*x*x*(x*(x*6-15)+10);}
    static double gradDot(int h,double x,double y,double z){int[] g=GRAD[h&15];return g[0]*x+g[1]*y+g[2]*z;}
    static double lerp(double a,double p0,double p1){return p0+a*(p1-p0);}
    static double lerp2(double a,double b,double x00,double x10,double x01,double x11){return lerp(b,lerp(a,x00,x10),lerp(a,x01,x11));}
    static double lerp3(double a,double b,double c,double x000,double x100,double x010,double x110,double x001,double x101,double x011,double x111){
        return lerp(c,lerp2(a,b,x000,x100,x010,x110),lerp2(a,b,x001,x101,x011,x111));}

    static double sampleScalar(double _x,double _y,double _z){
        double x=_x+xo,y=_y+yo,z=_z+zo;
        int xf=floor(x),yf=floor(y),zf=floor(z);
        double xr=x-xf,yr=y-yf,zr=z-zf;
        int x0=p(xf),x1=p(xf+1);
        int xy00=p(x0+yf),xy01=p(x0+yf+1),xy10=p(x1+yf),xy11=p(x1+yf+1);
        double d000=gradDot(p(xy00+zf),xr,yr,zr);
        double d100=gradDot(p(xy10+zf),xr-1,yr,zr);
        double d010=gradDot(p(xy01+zf),xr,yr-1,zr);
        double d110=gradDot(p(xy11+zf),xr-1,yr-1,zr);
        double d001=gradDot(p(xy00+zf+1),xr,yr,zr-1);
        double d101=gradDot(p(xy10+zf+1),xr-1,yr,zr-1);
        double d011=gradDot(p(xy01+zf+1),xr,yr-1,zr-1);
        double d111=gradDot(p(xy11+zf+1),xr-1,yr-1,zr-1);
        return lerp3(smoothstep(xr),smoothstep(yr),smoothstep(zr),d000,d100,d010,d110,d001,d101,d011,d111);
    }
    static double gradDotF(int h,double x,double y,double z){h&=15;return Math.fma(GX[h],x,Math.fma(GY[h],y,GZ[h]*z));}
    static double lerpF(double a,double p0,double p1){return Math.fma(a,p1-p0,p0);}
    static double lerp2F(double a,double b,double x00,double x10,double x01,double x11){return lerpF(b,lerpF(a,x00,x10),lerpF(a,x01,x11));}
    static double sampleFma(double _x,double _y,double _z){
        double x=_x+xo,y=_y+yo,z=_z+zo;
        int xf=floor(x),yf=floor(y),zf=floor(z);
        double xr=x-xf,yr=y-yf,zr=z-zf;
        int x0=p(xf),x1=p(xf+1);
        int xy00=p(x0+yf),xy01=p(x0+yf+1),xy10=p(x1+yf),xy11=p(x1+yf+1);
        double xm=xr-1,ym=yr-1,zm=zr-1;
        double d000=gradDotF(p(xy00+zf),xr,yr,zr);
        double d100=gradDotF(p(xy10+zf),xm,yr,zr);
        double d010=gradDotF(p(xy01+zf),xr,ym,zr);
        double d110=gradDotF(p(xy11+zf),xm,ym,zr);
        double d001=gradDotF(p(xy00+zf+1),xr,yr,zm);
        double d101=gradDotF(p(xy10+zf+1),xm,yr,zm);
        double d011=gradDotF(p(xy01+zf+1),xr,ym,zm);
        double d111=gradDotF(p(xy11+zf+1),xm,ym,zm);
        double au=smoothstep(xr),av=smoothstep(yr),aw=smoothstep(zr);
        return lerpF(aw,lerp2F(au,av,d000,d100,d010,d110),lerp2F(au,av,d001,d101,d011,d111));
    }

    public static void main(String[] a){
        int N=1<<16;
        double[] X=new double[N],Y=new double[N],Z=new double[N];
        var r=ThreadLocalRandom.current();
        for(int i=0;i<N;i++){X[i]=r.nextDouble()*64-32;Y[i]=r.nextDouble()*64-32;Z[i]=r.nextDouble()*64-32;}
        double maxRel=0;
        for(int i=0;i<N;i++){double s=sampleScalar(X[i],Y[i],Z[i]);double c=sampleFma(X[i],Y[i],Z[i]);double e=Math.abs(s-c)/(Math.abs(s)+1e-9);if(e>maxRel)maxRel=e;}
        System.out.printf("max relErr fma-vs-scalar = %.3e%n",maxRel);
        long bestS=Long.MAX_VALUE,bestF=Long.MAX_VALUE;double sink=0;
        for(int t=0;t<16;t++){long t0=System.nanoTime();for(int rep=0;rep<50;rep++){double s=0;for(int i=0;i<N;i++)s+=sampleScalar(X[i],Y[i],Z[i]);sink+=s;}long d=System.nanoTime()-t0;if(t>=6)bestS=Math.min(bestS,d);}
        for(int t=0;t<16;t++){long t0=System.nanoTime();for(int rep=0;rep<50;rep++){double s=0;for(int i=0;i<N;i++)s+=sampleFma(X[i],Y[i],Z[i]);sink+=s;}long d=System.nanoTime()-t0;if(t>=6)bestF=Math.min(bestF,d);}
        double nsS=(double)bestS/(50.0*N),nsF=(double)bestF/(50.0*N);
        System.out.printf("scalar     %.3f ns/cell%n",nsS);
        System.out.printf("fma-tight  %.3f ns/cell  speedup=%.2fx%n",nsF,nsS/nsF);
        if(sink==1.0)System.out.println(sink);
    }
}
