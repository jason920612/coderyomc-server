// Probe: vectorize the REAL ImprovedNoise.sampleAndLerp across a batch of cells.
// Mirrors net.minecraft...ImprovedNoise faithfully (p[] permutation gather + GRADIENT dot
// + trilinear smoothstep lerp). Question: does batching across cells + Vector API for the
// FP arithmetic (gather stays scalar) beat the scalar per-cell loop on this AVX2 box?
import jdk.incubator.vector.*;
import java.util.concurrent.ThreadLocalRandom;

public class NoiseBatchProbe {
    static final VectorSpecies<Double> DS = DoubleVector.SPECIES_PREFERRED;
    static final int[][] GRAD = {
        {1,1,0},{-1,1,0},{1,-1,0},{-1,-1,0},{1,0,1},{-1,0,1},{1,0,-1},{-1,0,-1},
        {0,1,1},{0,-1,1},{0,1,-1},{0,-1,-1},{1,1,0},{0,-1,1},{-1,1,0},{0,-1,-1}};
    static byte[] perm = new byte[256];
    static double xo,yo,zo;
    static { var r = ThreadLocalRandom.current();
        xo=r.nextDouble()*256; yo=r.nextDouble()*256; zo=r.nextDouble()*256;
        for(int i=0;i<256;i++) perm[i]=(byte)i;
        for(int i=0;i<256;i++){int o=r.nextInt(256-i);byte t=perm[i];perm[i]=perm[i+o];perm[i+o]=t;}
    }
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

    // Batched: scalar gather to fill per-corner gradient component arrays, then Vector API lerp math.
    static void sampleBatch(double[] X,double[] Y,double[] Z,double[] out,int n){
        // temp lane buffers
        double[] xr=new double[n],yr=new double[n],zr=new double[n];
        double[] d000=new double[n],d100=new double[n],d010=new double[n],d110=new double[n];
        double[] d001=new double[n],d101=new double[n],d011=new double[n],d111=new double[n];
        for(int k=0;k<n;k++){
            double x=X[k]+xo,y=Y[k]+yo,z=Z[k]+zo;
            int xf=floor(x),yf=floor(y),zf=floor(z);
            double rx=x-xf,ry=y-yf,rz=z-zf; xr[k]=rx;yr[k]=ry;zr[k]=rz;
            int x0=p(xf),x1=p(xf+1);
            int xy00=p(x0+yf),xy01=p(x0+yf+1),xy10=p(x1+yf),xy11=p(x1+yf+1);
            d000[k]=gradDot(p(xy00+zf),rx,ry,rz);
            d100[k]=gradDot(p(xy10+zf),rx-1,ry,rz);
            d010[k]=gradDot(p(xy01+zf),rx,ry-1,rz);
            d110[k]=gradDot(p(xy11+zf),rx-1,ry-1,rz);
            d001[k]=gradDot(p(xy00+zf+1),rx,ry,rz-1);
            d101[k]=gradDot(p(xy10+zf+1),rx-1,ry,rz-1);
            d011[k]=gradDot(p(xy01+zf+1),rx,ry-1,rz-1);
            d111[k]=gradDot(p(xy11+zf+1),rx-1,ry-1,rz-1);
        }
        DoubleVector C6=DoubleVector.broadcast(DS,6),C15=DoubleVector.broadcast(DS,15),C10=DoubleVector.broadcast(DS,10),ONE=DoubleVector.broadcast(DS,1);
        int i=0,ub=DS.loopBound(n);
        for(;i<ub;i+=DS.length()){
            DoubleVector u=DoubleVector.fromArray(DS,xr,i),v=DoubleVector.fromArray(DS,yr,i),w=DoubleVector.fromArray(DS,zr,i);
            DoubleVector au=u.mul(u).mul(u).mul(u.mul(u.mul(C6).sub(C15)).add(C10));
            DoubleVector av=v.mul(v).mul(v).mul(v.mul(v.mul(C6).sub(C15)).add(C10));
            DoubleVector aw=w.mul(w).mul(w).mul(w.mul(w.mul(C6).sub(C15)).add(C10));
            DoubleVector v000=DoubleVector.fromArray(DS,d000,i),v100=DoubleVector.fromArray(DS,d100,i),
                v010=DoubleVector.fromArray(DS,d010,i),v110=DoubleVector.fromArray(DS,d110,i),
                v001=DoubleVector.fromArray(DS,d001,i),v101=DoubleVector.fromArray(DS,d101,i),
                v011=DoubleVector.fromArray(DS,d011,i),v111=DoubleVector.fromArray(DS,d111,i);
            // lerp(au): a + au*(b-a)
            DoubleVector l00=v000.add(au.mul(v100.sub(v000)));
            DoubleVector l01=v010.add(au.mul(v110.sub(v010)));
            DoubleVector l10=v001.add(au.mul(v101.sub(v001)));
            DoubleVector l11=v011.add(au.mul(v111.sub(v011)));
            DoubleVector lo=l00.add(av.mul(l01.sub(l00)));
            DoubleVector hi=l10.add(av.mul(l11.sub(l10)));
            DoubleVector res=lo.add(aw.mul(hi.sub(lo)));
            res.intoArray(out,i);
        }
        for(;i<n;i++){
            double au=smoothstep(xr[i]),av=smoothstep(yr[i]),aw=smoothstep(zr[i]);
            out[i]=lerp3(au,av,aw,d000[i],d100[i],d010[i],d110[i],d001[i],d101[i],d011[i],d111[i]);
        }
    }

    public static void main(String[] a){
        System.out.println("DoubleVector SPECIES_PREFERRED lanes="+DS.length()+" bits="+DS.vectorBitSize());
        int N=1<<16; // 65536 cells
        double[] X=new double[N],Y=new double[N],Z=new double[N],out=new double[N];
        var r=ThreadLocalRandom.current();
        for(int i=0;i<N;i++){X[i]=r.nextDouble()*64-32;Y[i]=r.nextDouble()*64-32;Z[i]=r.nextDouble()*64-32;}
        // correctness
        double maxRel=0;
        sampleBatch(X,Y,Z,out,N);
        for(int i=0;i<N;i++){double s=sampleScalar(X[i],Y[i],Z[i]);double e=Math.abs(s-out[i])/(Math.abs(s)+1e-9);if(e>maxRel)maxRel=e;}
        System.out.printf("max relErr batch-vs-scalar = %.3e%n",maxRel);
        // bench
        long bestS=Long.MAX_VALUE,bestB=Long.MAX_VALUE;
        double sink=0;
        for(int t=0;t<12;t++){
            long t0=System.nanoTime();
            for(int rep=0;rep<40;rep++){double s=0;for(int i=0;i<N;i++)s+=sampleScalar(X[i],Y[i],Z[i]);sink+=s;}
            long d=System.nanoTime()-t0; if(t>=4)bestS=Math.min(bestS,d);
        }
        for(int t=0;t<12;t++){
            long t0=System.nanoTime();
            for(int rep=0;rep<40;rep++){sampleBatch(X,Y,Z,out,N);sink+=out[rep&1023];}
            long d=System.nanoTime()-t0; if(t>=4)bestB=Math.min(bestB,d);
        }
        double nsS=(double)bestS/(40.0*N), nsB=(double)bestB/(40.0*N);
        System.out.printf("scalar  %.3f ns/cell%n",nsS);
        System.out.printf("batch+VAPI %.3f ns/cell   speedup=%.2fx%n",nsB,nsS/nsB);
        if(sink==12345.6789)System.out.println(sink);
    }
}
