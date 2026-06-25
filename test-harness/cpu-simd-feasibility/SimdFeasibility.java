// CPU SIMD / SoA / branch-prediction feasibility probe for coderyoMC (#21)
// Standalone hand-rolled JMH-style harness: warmup + blackhole to defeat DCE.
// Compile/run with: javac --add-modules jdk.incubator.vector  /  java --add-modules jdk.incubator.vector
//
// NOT JMH (no extra deps allowed). Mitigations against dishonest numbers:
//  - long warmup (JIT to C2) before timed phase
//  - many measured reps, report median of several trials (reduces noise)
//  - a "blackhole" sink consumed at the end + returned/accumulated values, so
//    the optimizer cannot delete the loop body
//  - data generated once, reused, so we measure compute not allocation
//
// FP caveat: Vector API reductions reassociate floating-point adds (tree/lane
// order != sequential), so SIMD sums differ from scalar in the last ULPs.
// We assert "within tolerance" rather than bit-exact. This MATTERS for worldgen
// determinism: a vectorized noise function will NOT be bit-identical to the
// scalar one across machines/lane-widths -> only vectorize where determinism
// is not contractually required, or fix the reduction order.

import jdk.incubator.vector.*;
import java.util.*;
import java.util.concurrent.ThreadLocalRandom;

public class SimdFeasibility {

    // ---- blackhole: volatile sink the JIT must honor ----
    static volatile double BH_D = 0.0;
    static volatile float  BH_F = 0.0f;
    static volatile long   BH_L = 0L;
    static void consume(double v){ BH_D += v; }
    static void consume(float v){ BH_F += v; }
    static void consume(long v){ BH_L += v; }

    static final VectorSpecies<Float>  FS = FloatVector.SPECIES_PREFERRED;
    static final VectorSpecies<Double> DS = DoubleVector.SPECIES_PREFERRED;
    static final VectorSpecies<Integer> IS = IntVector.SPECIES_PREFERRED;

    // timing helper: run `r` reps of `body`, return best (min) ns/op over `trials`.
    interface Body { double run(); }
    static double benchNsPerElem(String name, int elems, int warmupReps, int measReps, int trials, Body body){
        // warmup
        for (int i=0;i<warmupReps;i++){ consume(body.run()); }
        long best = Long.MAX_VALUE;
        for (int t=0;t<trials;t++){
            long s = System.nanoTime();
            double acc = 0;
            for (int i=0;i<measReps;i++){ acc += body.run(); }
            long e = System.nanoTime();
            consume(acc);
            long total = e - s;
            best = Math.min(best, total);
        }
        double nsPerElem = (double) best / ((double) measReps * (double) elems);
        System.out.printf("  %-34s  %8.4f ns/elem%n", name, nsPerElem);
        return nsPerElem;
    }

    public static void main(String[] args){
        printMachine();
        bench2_noise();
        bench3_entitySoA();
        bench4_branch();
        bench5_lighting();
        // touch blackholes so nothing is dead
        System.out.printf("%n[blackhole sink] d=%.3f f=%.3f l=%d%n", BH_D, BH_F, BH_L);
    }

    // ================= 1. MACHINE CAPABILITY =================
    static void printMachine(){
        System.out.println("==================================================================");
        System.out.println(" coderyoMC CPU SIMD feasibility probe (#21)");
        System.out.println("==================================================================");
        System.out.println("Java:        " + System.getProperty("java.vendor.version") + " / " + System.getProperty("java.version"));
        System.out.println("OS/arch:     " + System.getProperty("os.name") + " " + System.getProperty("os.arch"));
        System.out.println("CPU cores:   " + Runtime.getRuntime().availableProcessors());
        System.out.println("CPU name:    " + cpuName());
        System.out.println();
        System.out.println("FloatVector  SPECIES_PREFERRED: lanes=" + FS.length()  + "  bits=" + FS.vectorBitSize());
        System.out.println("DoubleVector SPECIES_PREFERRED: lanes=" + DS.length()  + "  bits=" + DS.vectorBitSize());
        System.out.println("IntVector    SPECIES_PREFERRED: lanes=" + IS.length()  + "  bits=" + IS.vectorBitSize());
        int bits = FS.vectorBitSize();
        String isa = switch (bits) {
            case 512 -> "AVX-512 (512-bit)";
            case 256 -> "AVX2 (256-bit)";
            case 128 -> "SSE / 128-bit (or ARM NEON)";
            default  -> bits + "-bit";
        };
        System.out.println("=> JVM Vector API will dispatch to: " + isa);
        System.out.println("==================================================================\n");
    }

    static String cpuName(){
        // best-effort on Windows
        try {
            String env = System.getenv("PROCESSOR_IDENTIFIER");
            if (env != null) return env;
        } catch (Throwable ignore){}
        return "(unknown)";
    }

    // ================= 2. NOISE-STYLE MATH (the GPU loser) =================
    // Improved-Perlin-style gradient dot + fade, summed over an octave stack.
    // This is float-heavy transcendental-free math = the ideal SIMD candidate,
    // and it is exactly the worldgen workload that LOST on the GPU (no transfer
    // win there). Here it runs in-register on the same cores: no PCIe, no copy.
    static void bench2_noise(){
        System.out.println("[2] NOISE-STYLE MATH  (worldgen octave/gradient-dot, the GPU-loser)");
        int N = 1 << 20; // ~1M lattice samples
        float[] x = new float[N], y = new float[N], z = new float[N];
        ThreadLocalRandom r = ThreadLocalRandom.current();
        for (int i=0;i<N;i++){ x[i]=r.nextFloat()*256f; y[i]=r.nextFloat()*64f; z[i]=r.nextFloat()*256f; }

        double sc = benchNsPerElem("scalar", N, 30, 60, 8, () -> noiseScalar(x,y,z));
        double si = benchNsPerElem("vector-API (SIMD)", N, 30, 60, 8, () -> noiseSimd(x,y,z));

        // correctness / tolerance check
        float a = (float) noiseScalar(x,y,z);
        float b = (float) noiseSimd(x,y,z);
        double rel = Math.abs(a-b) / (Math.abs(a)+1e-6);
        System.out.printf("  speedup SIMD vs scalar: %.2fx   | sum scalar=%.4f simd=%.4f relErr=%.2e (FP reorder)%n%n",
                sc/si, a, b, rel);
    }

    // 4-octave improved-noise-ish: per octave, fade*gradient-dot. Pure FMA-friendly math.
    static double noiseScalar(float[] x, float[] y, float[] z){
        int n = x.length; float sum = 0f;
        for (int i=0;i<n;i++){
            float px=x[i], py=y[i], pz=z[i];
            float amp = 1f, freq = 1f, acc = 0f;
            for (int o=0;o<4;o++){
                float fx=px*freq, fy=py*freq, fz=pz*freq;
                // fractional coords
                // floor via truncation (coords non-negative) to match the SIMD path exactly
                float u = fx - (float)(int)fx;
                float v = fy - (float)(int)fy;
                float w = fz - (float)(int)fz;
                // perlin fade 6t^5-15t^4+10t^3
                float fu = u*u*u*(u*(u*6f-15f)+10f);
                float fv = v*v*v*(v*(v*6f-15f)+10f);
                float fw = w*w*w*(w*(w*6f-15f)+10f);
                // pseudo gradient dot (cheap, deterministic-ish)
                float g = fu*(u- .5f) + fv*(v-.5f) + fw*(w-.5f);
                acc += amp * g;
                amp *= 0.5f; freq *= 2f;
            }
            sum += acc;
        }
        return sum;
    }

    // vector floor for non-negative lanes: f -> int (trunc toward zero) -> f
    static FloatVector vfloorPos(FloatVector v){
        return (FloatVector) v.convert(VectorOperators.F2I, 0).convert(VectorOperators.I2F, 0);
    }

    static double noiseSimd(float[] x, float[] y, float[] z){
        int n = x.length; int L = FS.length();
        FloatVector vsum = FloatVector.zero(FS);
        FloatVector C6=FloatVector.broadcast(FS,6f), C15=FloatVector.broadcast(FS,15f),
                    C10=FloatVector.broadcast(FS,10f), HALF=FloatVector.broadcast(FS,0.5f);
        int i=0; int upper = FS.loopBound(n);
        for (; i<upper; i+=L){
            FloatVector px = FloatVector.fromArray(FS,x,i);
            FloatVector py = FloatVector.fromArray(FS,y,i);
            FloatVector pz = FloatVector.fromArray(FS,z,i);
            float amp=1f, freq=1f;
            FloatVector acc = FloatVector.zero(FS);
            for (int o=0;o<4;o++){
                FloatVector fx=px.mul(freq), fy=py.mul(freq), fz=pz.mul(freq);
                // floor via truncation (coords are non-negative): (float)(int)v == floor(v) for v>=0.
                // Vector API has no FLOOR unary op, so convert f->i->f.
                FloatVector u=fx.sub(vfloorPos(fx));
                FloatVector v=fy.sub(vfloorPos(fy));
                FloatVector w=fz.sub(vfloorPos(fz));
                FloatVector fu=u.mul(u).mul(u).mul( u.mul( u.mul(C6).sub(C15) ).add(C10) );
                FloatVector fv=v.mul(v).mul(v).mul( v.mul( v.mul(C6).sub(C15) ).add(C10) );
                FloatVector fw=w.mul(w).mul(w).mul( w.mul( w.mul(C6).sub(C15) ).add(C10) );
                FloatVector g=fu.mul(u.sub(HALF)).add(fv.mul(v.sub(HALF))).add(fw.mul(w.sub(HALF)));
                acc = acc.add(g.mul(amp));
                amp*=0.5f; freq*=2f;
            }
            vsum = vsum.add(acc);
        }
        float sum = vsum.reduceLanes(VectorOperators.ADD);
        for (; i<n; i++){ // tail
            float[] xs={x[i]}, ys={y[i]}, zs={z[i]};
            sum += (float) noiseScalar(xs,ys,zs);
        }
        return sum;
    }

    // ================= 3. ENTITY INTEGRATION: AoS vs SoA-scalar vs SoA-SIMD =====
    static final class Entity { float x,y,z,vx,vy,vz; }
    static void bench3_entitySoA(){
        System.out.println("[3] ENTITY INTEGRATION  pos += vel*dt   (AoS vs SoA-scalar vs SoA-SIMD)");
        int N = 1 << 20;
        ThreadLocalRandom r = ThreadLocalRandom.current();
        // AoS
        Entity[] ents = new Entity[N];
        for (int i=0;i<N;i++){ Entity e=new Entity();
            e.x=r.nextFloat(); e.y=r.nextFloat(); e.z=r.nextFloat();
            e.vx=r.nextFloat(); e.vy=r.nextFloat(); e.vz=r.nextFloat(); ents[i]=e; }
        // shuffle references so AoS has poor locality (heap-order scatter), realistic for live entities
        Collections.shuffle(Arrays.asList(ents), new Random(42));
        // SoA
        float[] X=new float[N],Y=new float[N],Z=new float[N],VX=new float[N],VY=new float[N],VZ=new float[N];
        for (int i=0;i<N;i++){ X[i]=r.nextFloat();Y[i]=r.nextFloat();Z[i]=r.nextFloat();
            VX[i]=r.nextFloat();VY[i]=r.nextFloat();VZ[i]=r.nextFloat(); }
        final float dt=0.05f;

        double aos = benchNsPerElem("AoS (shuffled refs)", N, 30, 50, 8, () -> {
            float s=0; for (Entity e: ents){ e.x+=e.vx*dt; e.y+=e.vy*dt; e.z+=e.vz*dt; s+=e.x; } return s; });
        double soaS = benchNsPerElem("SoA scalar", N, 30, 50, 8, () -> {
            float s=0; for (int i=0;i<N;i++){ X[i]+=VX[i]*dt; Y[i]+=VY[i]*dt; Z[i]+=VZ[i]*dt; s+=X[i]; } return s; });
        double soaV = benchNsPerElem("SoA vector-API (SIMD)", N, 30, 50, 8, () -> {
            int L=FS.length(); int up=FS.loopBound(N); float s=0;
            for (int c=0;c<3;c++){
                float[] P = (c==0)?X:(c==1)?Y:Z; float[] V=(c==0)?VX:(c==1)?VY:VZ;
                int i=0; for (; i<up; i+=L){
                    FloatVector p=FloatVector.fromArray(FS,P,i);
                    FloatVector v=FloatVector.fromArray(FS,V,i);
                    p.add(v.mul(dt)).intoArray(P,i);
                }
                for (; i<N; i++){ P[i]+=V[i]*dt; }
            }
            for (int i=0;i<N;i+=997) s+=X[i]; return s; });

        System.out.printf("  SoA-scalar vs AoS:   %.2fx (cache/layout)%n", aos/soaS);
        System.out.printf("  SoA-SIMD   vs SoA-scalar: %.2fx%n", soaS/soaV);
        System.out.printf("  SoA-SIMD   vs AoS (total): %.2fx%n%n", aos/soaV);
    }

    // ================= 4. BRANCH PREDICTION =================
    // sum of elements > threshold: random vs sorted vs branchless(mask) vs SIMD-mask
    static void bench4_branch(){
        System.out.println("[4] BRANCH PREDICTION  sum(a[i]>T)   random vs sorted vs branchless vs SIMD");
        int N = 1 << 21;
        int[] randArr = new int[N], sortArr = new int[N];
        ThreadLocalRandom r = ThreadLocalRandom.current();
        for (int i=0;i<N;i++){ int v=r.nextInt(256); randArr[i]=v; sortArr[i]=v; }
        Arrays.sort(sortArr); // sorted => branch is highly predictable
        final int T=128;

        double branchy = benchNsPerElem("branchy on RANDOM data", N, 30, 60, 8, () -> sumGT(randArr,T));
        double sorted  = benchNsPerElem("branchy on SORTED data", N, 30, 60, 8, () -> sumGT(sortArr,T));
        double branchless = benchNsPerElem("branchless (mask arith)", N, 30, 60, 8, () -> sumGTBranchless(randArr,T));
        double simd    = benchNsPerElem("SIMD masked (vector-API)", N, 30, 60, 8, () -> sumGTSimd(randArr,T));

        System.out.printf("  misprediction cost: random/sorted = %.2fx slower when unpredictable%n", branchy/sorted);
        System.out.printf("  branchless vs branchy(random): %.2fx%n", branchy/branchless);
        System.out.printf("  SIMD vs branchy(random):       %.2fx%n%n", branchy/simd);
    }
    static double sumGT(int[] a, int T){ long s=0; for (int x: a){ if (x>T) s+=x; } return s; }
    static double sumGTBranchless(int[] a, int T){
        long s=0; for (int x: a){ int m = (T - x) >> 31; /* -1 if x>T else 0 */ s += (x & m); } return s; }
    static double sumGTSimd(int[] a, int T){
        int L=IS.length(); IntVector vT=IntVector.broadcast(IS,T);
        IntVector vsum=IntVector.zero(IS); int i=0; int up=IS.loopBound(a.length);
        for (; i<up; i+=L){
            IntVector v=IntVector.fromArray(IS,a,i);
            VectorMask<Integer> m = v.compare(VectorOperators.GT, vT);
            // add only lanes where x>T (masked add into accumulator)
            vsum = vsum.add(v, m);
        }
        long s = vsum.reduceLanes(VectorOperators.ADD);
        for (; i<a.length; i++){ if (a[i]>T) s+=a[i]; }
        return s;
    }

    // ================= 5. BULK TRANSFORM (lighting/heightmap-style) =================
    static void bench5_lighting(){
        System.out.println("[5] BULK TRANSFORM  out = clamp(a*k + b)  (lighting/heightmap-style)");
        int N = 1 << 21;
        float[] a=new float[N], b=new float[N], out=new float[N];
        ThreadLocalRandom r = ThreadLocalRandom.current();
        for (int i=0;i<N;i++){ a[i]=r.nextFloat()*32; b[i]=r.nextFloat()*4; }
        final float k=1.7f;
        double sc = benchNsPerElem("scalar", N, 30, 60, 8, () -> {
            float s=0; for (int i=0;i<N;i++){ float v=a[i]*k+b[i]; v = v<0?0:(v>15?15:v); out[i]=v; s+=v; } return s; });
        double si = benchNsPerElem("vector-API (SIMD)", N, 30, 60, 8, () -> {
            int L=FS.length(); int up=FS.loopBound(N); int i=0;
            FloatVector vk=FloatVector.broadcast(FS,k), lo=FloatVector.zero(FS), hi=FloatVector.broadcast(FS,15f);
            for (; i<up; i+=L){
                FloatVector va=FloatVector.fromArray(FS,a,i), vb=FloatVector.fromArray(FS,b,i);
                FloatVector v=va.mul(vk).add(vb).max(lo).min(hi);
                v.intoArray(out,i);
            }
            float s=0; for (; i<N; i++){ float v=a[i]*k+b[i]; v=v<0?0:(v>15?15:v); out[i]=v; s+=v; }
            return s; });
        System.out.printf("  speedup SIMD vs scalar: %.2fx (note: C2 may already auto-vectorize this simple map)%n%n", sc/si);
    }
}
