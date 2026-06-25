// Probe variant B: vectorize the 8 CORNERS within one noise() call.
// 8 gradient dots -> use float[8] lane buffers built by scalar gather, then the trilinear
// lerp tree as a small SIMD reduction. Plus a pure-scalar-FMA rewrite for comparison.
import jdk.incubator.vector.*;
import java.util.concurrent.ThreadLocalRandom;

public class NoiseCornerProbe {
    static final int[][] GRAD = {
        {1,1,0},{-1,1,0},{1,-1,0},{-1,-1,0},{1,0,1},{-1,0,1},{1,0,-1},{-1,0,-1},
        {0,1,1},{0,-1,1},{0,1,-1},{0,-1,-1},{1,1,0},{0,-1,1},{-1,1,0},{0,-1,-1}};
    // flattened gradient: gx[16],gy[16],gz[16] for clean indexed access
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

    // 8-corner SIMD: build hash[8], then dx/dy/dz[8], gather gradient comps, dot in 8-lane (2x4 double) / or 1x8 if avail
    static final VectorSpecies<Double> DS=DoubleVector.SPECIES_PREFERRED;
    static double sampleCornerSimd(double _x,double _y,double _z){
        double x=_x+xo,y=_y+yo,z=_z+zo;
        int xf=floor(x),yf=floor(y),zf=floor(z);
        double xr=x-xf,yr=y-yf,zr=z-zf;
        int x0=p(xf),x1=p(xf+1);
        int xy00=p(x0+yf),xy01=p(x0+yf+1),xy10=p(x1+yf),xy11=p(x1+yf+1);
        // hash per corner, order: 000,100,010,110,001,101,011,111
        int h0=p(xy00+zf)&15,h1=p(xy10+zf)&15,h2=p(xy01+zf)&15,h3=p(xy11+zf)&15;
        int h4=p(xy00+zf+1)&15,h5=p(xy10+zf+1)&15,h6=p(xy01+zf+1)&15,h7=p(xy11+zf+1)&15;
        double xm=xr-1,ym=yr-1,zm=zr-1;
        // dot products via gathered grad comps
        double[] dx={xr,xm,xr,xm,xr,xm,xr,xm};
        double[] dy={yr,yr,ym,ym,yr,yr,ym,ym};
        double[] dz={zr,zr,zr,zr,zm,zm,zm,zm};
        int[] h={h0,h1,h2,h3,h4,h5,h6,h7};
        double[] d=new double[8];
        for(int k=0;k<8;k++) d[k]=GX[h[k]]*dx[k]+GY[h[k]]*dy[k]+GZ[h[k]]*dz[k];
        return lerp3(smoothstep(xr),smoothstep(yr),smoothstep(zr),d[0],d[1],d[2],d[3],d[4],d[5],d[6],d[7]);
    }

    public static void main(String[] a){
        int N=1<<16;
        double[] X=new double[N],Y=new double[N],Z=new double[N];
        var r=ThreadLocalRandom.current();
        for(int i=0;i<N;i++){X[i]=r.nextDouble()*64-32;Y[i]=r.nextDouble()*64-32;Z[i]=r.nextDouble()*64-32;}
        double maxRel=0;
        for(int i=0;i<N;i++){double s=sampleScalar(X[i],Y[i],Z[i]);double c=sampleCornerSimd(X[i],Y[i],Z[i]);double e=Math.abs(s-c)/(Math.abs(s)+1e-9);if(e>maxRel)maxRel=e;}
        System.out.printf("max relErr corner-vs-scalar = %.3e%n",maxRel);
        long bestS=Long.MAX_VALUE,bestC=Long.MAX_VALUE; double sink=0;
        for(int t=0;t<14;t++){long t0=System.nanoTime();for(int rep=0;rep<40;rep++){double s=0;for(int i=0;i<N;i++)s+=sampleScalar(X[i],Y[i],Z[i]);sink+=s;}long d=System.nanoTime()-t0;if(t>=5)bestS=Math.min(bestS,d);}
        for(int t=0;t<14;t++){long t0=System.nanoTime();for(int rep=0;rep<40;rep++){double s=0;for(int i=0;i<N;i++)s+=sampleCornerSimd(X[i],Y[i],Z[i]);sink+=s;}long d=System.nanoTime()-t0;if(t>=5)bestC=Math.min(bestC,d);}
        double nsS=(double)bestS/(40.0*N),nsC=(double)bestC/(40.0*N);
        System.out.printf("scalar       %.3f ns/cell%n",nsS);
        System.out.printf("corner-array %.3f ns/cell  speedup=%.2fx%n",nsC,nsS/nsC);
        if(sink==1.0)System.out.println(sink);
    }
}
