import org.lwjgl.PointerBuffer;
import org.lwjgl.opencl.*;
import org.lwjgl.system.MemoryStack;

import java.nio.ByteBuffer;
import java.nio.FloatBuffer;
import java.nio.IntBuffer;
import java.util.*;
import java.util.concurrent.*;

import static org.lwjgl.opencl.CL10.*;
import static org.lwjgl.system.MemoryStack.stackPush;
import static org.lwjgl.system.MemoryUtil.*;

/**
 * Standalone OpenCL-vs-CPU microbenchmark for entity-style data-parallel compute.
 * coderyoMC GPU feasibility probe (issue #15).
 *
 * Three representative entity kernels:
 *   (a) position/velocity integration  -- cheap, ~handful FLOPs/entity
 *   (b) AABB broad-phase collision via uniform spatial grid -- moderate
 *   (c) batched A*-heuristic cost eval over KxK neighborhood -- heavy
 *
 * Each implemented in OpenCL (GPU), Java single-thread CPU, Java all-cores CPU.
 * No mocks: real OpenCL on the system GPU.
 */
public class EntityGpuFeasibility {

    static final int[] SIZES = {100, 1000, 10000, 50000, 100000};
    static final int RUNS = 8;       // measured runs per config
    static final int WARMUP = 3;     // discarded warmup runs
    static final float DT = 0.05f;   // ~one MC tick
    static final float GRAVITY = -0.08f * 20f; // blocks/s^2-ish
    static final int K = 7;          // pathfinding neighborhood half-extent => (2K+1)^2 cells
    static final int CORES = Runtime.getRuntime().availableProcessors();

    static long context, queue, device;
    static ExecutorService pool;

    public static void main(String[] args) {
        System.out.println("=== coderyoMC entity-GPU feasibility probe (#15) ===");
        System.out.println("CPU cores (availableProcessors): " + CORES);
        pool = Executors.newFixedThreadPool(CORES);

        initCL();

        List<Result> results = new ArrayList<>();
        for (Kernel k : Kernel.values()) {
            System.out.println("\n######## KERNEL " + k + " ########");
            for (int n : SIZES) {
                Result r = benchKernel(k, n);
                results.add(r);
                System.out.printf(Locale.US,
                    "N=%-7d  CPU1=%9.3f ms  CPUall=%9.3f ms  GPUtotal=%9.3f ms (kernel=%7.3f, xfer=%7.3f)  | GPU/all=%5.2fx%n",
                    n, r.cpu1Mean, r.cpuAllMean, r.gpuTotalMean, r.gpuKernelMean, r.gpuXferMean,
                    r.gpuTotalMean / r.cpuAllMean);
            }
        }

        printSummary(results);
        emitMarkdown(results);

        pool.shutdownNow();
        clReleaseCommandQueue(queue);
        clReleaseContext(context);
        System.out.println("\nDone.");
    }

    enum Kernel { INTEGRATE, COLLISION, PATHFIND }

    // ----------------------------------------------------------------------
    // OpenCL setup
    // ----------------------------------------------------------------------
    static String deviceName, platformName, deviceVendor;
    static boolean deviceIsGPU;

    static void initCL() {
        try (MemoryStack stack = stackPush()) {
            IntBuffer pi = stack.mallocInt(1);
            checkCL(clGetPlatformIDs(null, pi));
            int numPlat = pi.get(0);
            if (numPlat == 0) throw new RuntimeException("No OpenCL platforms found");
            PointerBuffer platforms = stack.mallocPointer(numPlat);
            checkCL(clGetPlatformIDs(platforms, (IntBuffer) null));

            long chosenPlatform = 0, chosenDevice = 0;
            // Prefer a GPU device (we want the RTX 4060, not a CPU ICD fallback).
            outer:
            for (int p = 0; p < numPlat; p++) {
                long plat = platforms.get(p);
                int err = clGetDeviceIDs(plat, CL_DEVICE_TYPE_GPU, null, pi);
                if (err != CL_SUCCESS) continue;
                int nd = pi.get(0);
                if (nd == 0) continue;
                PointerBuffer devs = stack.mallocPointer(nd);
                clGetDeviceIDs(plat, CL_DEVICE_TYPE_GPU, devs, (IntBuffer) null);
                chosenPlatform = plat;
                chosenDevice = devs.get(0);
                break outer;
            }
            if (chosenDevice == 0) {
                throw new RuntimeException("No OpenCL GPU device found -- refusing CPU fallback for a GPU feasibility test.");
            }
            device = chosenDevice;
            platformName = getPlatformInfo(chosenPlatform, CL_PLATFORM_NAME);
            deviceName = getDeviceInfoStr(device, CL_DEVICE_NAME);
            deviceVendor = getDeviceInfoStr(device, CL_DEVICE_VENDOR);
            long devType = getDeviceInfoLong(device, CL_DEVICE_TYPE);
            deviceIsGPU = (devType & CL_DEVICE_TYPE_GPU) != 0;

            System.out.println("OpenCL platform : " + platformName);
            System.out.println("OpenCL device   : " + deviceName + " (" + deviceVendor + ")");
            System.out.println("Device is GPU   : " + deviceIsGPU);
            System.out.println("Compute units   : " + getDeviceInfoLong(device, CL_DEVICE_MAX_COMPUTE_UNITS));
            System.out.println("Max clock (MHz) : " + getDeviceInfoLong(device, CL_DEVICE_MAX_CLOCK_FREQUENCY));
            System.out.println("Global mem (MB) : " + (getDeviceInfoLong(device, CL_DEVICE_GLOBAL_MEM_SIZE) / (1024*1024)));

            PointerBuffer ctxProps = stack.mallocPointer(3);
            ctxProps.put(CL_CONTEXT_PLATFORM).put(chosenPlatform).put(0).flip();
            context = clCreateContext(ctxProps, device, null, NULL, pi);
            checkCL(pi.get(0));
            // Enable profiling so we can isolate kernel time from transfer time.
            queue = clCreateCommandQueue(context, device, CL_QUEUE_PROFILING_ENABLE, pi);
            checkCL(pi.get(0));
        }
    }

    // ----------------------------------------------------------------------
    // Benchmark driver
    // ----------------------------------------------------------------------
    static class Result {
        Kernel kernel; int n;
        double cpu1Mean, cpu1Std, cpuAllMean, cpuAllStd;
        double gpuTotalMean, gpuTotalStd, gpuKernelMean, gpuXferMean;
    }

    static Result benchKernel(Kernel k, int n) {
        Result r = new Result();
        r.kernel = k; r.n = n;

        switch (k) {
            case INTEGRATE: benchIntegrate(n, r); break;
            case COLLISION: benchCollision(n, r); break;
            case PATHFIND:  benchPathfind(n, r); break;
        }
        return r;
    }

    static double mean(double[] a) { double s=0; for (double x:a) s+=x; return s/a.length; }
    static double std(double[] a, double m) { double s=0; for (double x:a) s+=(x-m)*(x-m); return Math.sqrt(s/a.length); }

    interface Run { double run(); }   // returns elapsed ms

    static double[] timeRuns(Run run) {
        for (int i = 0; i < WARMUP; i++) run.run();
        double[] t = new double[RUNS];
        for (int i = 0; i < RUNS; i++) t[i] = run.run();
        return t;
    }

    static Random seeded(int n) { return new Random(0xC0DE ^ n); }

    // ======================================================================
    // (a) INTEGRATION
    // ======================================================================
    static void benchIntegrate(int n, Result r) {
        float[] pos = new float[n*3], vel = new float[n*3];
        Random rnd = seeded(n);
        for (int i = 0; i < n*3; i++) { pos[i] = rnd.nextFloat()*256; vel[i] = (rnd.nextFloat()-0.5f)*4; }

        // CPU single-thread
        double[] c1 = timeRuns(() -> {
            float[] p = pos.clone(), v = vel.clone();
            long t0 = System.nanoTime();
            integrateRange(p, v, 0, n);
            return (System.nanoTime()-t0)/1e6;
        });
        r.cpu1Mean = mean(c1); r.cpu1Std = std(c1, r.cpu1Mean);

        // CPU all-cores
        double[] ca = timeRuns(() -> {
            float[] p = pos.clone(), v = vel.clone();
            long t0 = System.nanoTime();
            parallelFor(n, (lo, hi) -> integrateRange(p, v, lo, hi));
            return (System.nanoTime()-t0)/1e6;
        });
        r.cpuAllMean = mean(ca); r.cpuAllStd = std(ca, r.cpuAllMean);

        // GPU
        String src = """
            __kernel void integrate(__global float* pos, __global float* vel, float dt, float g){
                int i = get_global_id(0);
                int b = i*3;
                vel[b+1] += g*dt;
                pos[b+0] += vel[b+0]*dt;
                pos[b+1] += vel[b+1]*dt;
                pos[b+2] += vel[b+2]*dt;
            }""";
        long program = buildProgram(src);
        long kern = createKernel(program, "integrate");
        double[][] g = timeRuns2(() -> {
            try (MemoryStack stack = stackPush()) {
                IntBuffer ec = stack.mallocInt(1);
                long mPos = clCreateBuffer(context, CL_MEM_READ_WRITE, (long)n*3*4, ec); checkCL(ec.get(0));
                long mVel = clCreateBuffer(context, CL_MEM_READ_WRITE, (long)n*3*4, ec); checkCL(ec.get(0));
                long t0 = System.nanoTime();
                long[] evW = new long[2];
                evW[0] = enqueueWrite(mPos, pos);
                evW[1] = enqueueWrite(mVel, vel);
                clSetKernelArg1p(kern, 0, mPos);
                clSetKernelArg1p(kern, 1, mVel);
                clSetKernelArg1f(kern, 2, DT);
                clSetKernelArg1f(kern, 3, GRAVITY);
                long evK = enqueueKernel(kern, n);
                float[] out = new float[n*3];
                long evR = enqueueRead(mPos, out);
                clFinish(queue);
                cleanupPending();
                double totalMs = (System.nanoTime()-t0)/1e6;
                double kernMs = profMs(evK);
                double xferMs = profMs(evW[0]) + profMs(evW[1]) + profMs(evR);
                for (long e : evW) clReleaseEvent(e);
                clReleaseEvent(evK); clReleaseEvent(evR);
                clReleaseMemObject(mPos); clReleaseMemObject(mVel);
                return new double[]{totalMs, kernMs, xferMs};
            }
        });
        fillGpu(r, g);
        clReleaseKernel(kern); clReleaseProgram(program);
    }

    static void integrateRange(float[] pos, float[] vel, int lo, int hi) {
        for (int i = lo; i < hi; i++) {
            int b = i*3;
            vel[b+1] += GRAVITY*DT;
            pos[b]   += vel[b]*DT;
            pos[b+1] += vel[b+1]*DT;
            pos[b+2] += vel[b+2]*DT;
        }
    }

    // ======================================================================
    // (b) COLLISION broad-phase via uniform grid
    //   Each entity inspects its own cell + 26 neighbor cells (3D), counts
    //   AABB overlaps. We use a fixed-capacity grid (bucket of entity indices).
    // ======================================================================
    static final float WORLD = 512f;   // world span in blocks
    static final int BUCKET_CAP = 8;    // max entities tracked per cell
    // Grid resolution scales with N: we size cells so the grid holds ~1 entity/cell
    // (a compact/hashed uniform grid, as a real broad-phase would use). This keeps the
    // transferred acceleration structure O(N) instead of O(world^3) -- a fair test.
    static int gridFor(int n) { return Math.max(2, (int)Math.cbrt(Math.max(1, n))); }

    static void benchCollision(int n, Result r) {
        final int GRID = gridFor(n);
        final float CELL = WORLD / GRID;   // cell size so GRID^3 ~= N
        float[] pos = new float[n*3];
        Random rnd = seeded(n);
        for (int i = 0; i < n*3; i++) pos[i] = rnd.nextFloat()*WORLD;
        final float radius = 0.6f;

        // Build grid on CPU (shared cost; we time the pair-check phase which is the data-parallel part).
        int totalCells = GRID*GRID*GRID;
        int[] cellCount = new int[totalCells];
        int[] cellData = new int[totalCells*BUCKET_CAP];
        buildGrid(pos, n, cellCount, cellData, GRID, CELL);
        final int[] fCellCount = cellCount, fCellData = cellData;

        // CPU single-thread
        double[] c1 = timeRuns(() -> {
            int[] out = new int[n];
            long t0 = System.nanoTime();
            collisionRange(pos, n, fCellCount, fCellData, radius, out, 0, n, GRID, CELL);
            return (System.nanoTime()-t0)/1e6;
        });
        r.cpu1Mean = mean(c1); r.cpu1Std = std(c1, r.cpu1Mean);

        double[] ca = timeRuns(() -> {
            int[] out = new int[n];
            long t0 = System.nanoTime();
            parallelFor(n, (lo, hi) -> collisionRange(pos, n, fCellCount, fCellData, radius, out, lo, hi, GRID, CELL));
            return (System.nanoTime()-t0)/1e6;
        });
        r.cpuAllMean = mean(ca); r.cpuAllStd = std(ca, r.cpuAllMean);

        String src = """
            #define GRID %d
            #define CELL %ff
            #define BUCKET_CAP %d
            __kernel void collide(__global const float* pos, __global const int* cellCount,
                                  __global const int* cellData, int n, float radius, __global int* out){
                int i = get_global_id(0);
                if (i >= n) return;
                float px = pos[i*3+0], py = pos[i*3+1], pz = pos[i*3+2];
                int cx = (int)(px/CELL), cy = (int)(py/CELL), cz = (int)(pz/CELL);
                float d2 = (2.0f*radius)*(2.0f*radius);
                int hits = 0;
                for (int dx=-1; dx<=1; dx++) for (int dy=-1; dy<=1; dy++) for (int dz=-1; dz<=1; dz++){
                    int nx=cx+dx, ny=cy+dy, nz=cz+dz;
                    if (nx<0||ny<0||nz<0||nx>=GRID||ny>=GRID||nz>=GRID) continue;
                    int cell = (nx*GRID+ny)*GRID+nz;
                    int cnt = cellCount[cell]; if (cnt>BUCKET_CAP) cnt=BUCKET_CAP;
                    for (int b=0;b<cnt;b++){
                        int j = cellData[cell*BUCKET_CAP+b];
                        if (j==i) continue;
                        float ddx=px-pos[j*3+0], ddy=py-pos[j*3+1], ddz=pz-pos[j*3+2];
                        if (ddx*ddx+ddy*ddy+ddz*ddz < d2) hits++;
                    }
                }
                out[i]=hits;
            }""".formatted(GRID, CELL, BUCKET_CAP);
        long program = buildProgram(src);
        long kern = createKernel(program, "collide");
        double[][] g = timeRuns2(() -> {
            try (MemoryStack stack = stackPush()) {
                IntBuffer ec = stack.mallocInt(1);
                long mPos = clCreateBuffer(context, CL_MEM_READ_ONLY, (long)n*3*4, ec); checkCL(ec.get(0));
                long mCnt = clCreateBuffer(context, CL_MEM_READ_ONLY, (long)totalCells*4, ec); checkCL(ec.get(0));
                long mDat = clCreateBuffer(context, CL_MEM_READ_ONLY, (long)totalCells*BUCKET_CAP*4, ec); checkCL(ec.get(0));
                long mOut = clCreateBuffer(context, CL_MEM_WRITE_ONLY, (long)n*4, ec); checkCL(ec.get(0));
                long t0 = System.nanoTime();
                long e1 = enqueueWrite(mPos, pos);
                long e2 = enqueueWriteI(mCnt, fCellCount);
                long e3 = enqueueWriteI(mDat, fCellData);
                clSetKernelArg1p(kern, 0, mPos);
                clSetKernelArg1p(kern, 1, mCnt);
                clSetKernelArg1p(kern, 2, mDat);
                clSetKernelArg1i(kern, 3, n);
                clSetKernelArg1f(kern, 4, radius);
                clSetKernelArg1p(kern, 5, mOut);
                long evK = enqueueKernel(kern, n);
                int[] out = new int[n];
                long evR = enqueueReadI(mOut, out);
                clFinish(queue);
                cleanupPending();
                double totalMs = (System.nanoTime()-t0)/1e6;
                double kernMs = profMs(evK);
                double xferMs = profMs(e1)+profMs(e2)+profMs(e3)+profMs(evR);
                clReleaseEvent(e1); clReleaseEvent(e2); clReleaseEvent(e3); clReleaseEvent(evK); clReleaseEvent(evR);
                clReleaseMemObject(mPos); clReleaseMemObject(mCnt); clReleaseMemObject(mDat); clReleaseMemObject(mOut);
                return new double[]{totalMs, kernMs, xferMs};
            }
        });
        fillGpu(r, g);
        clReleaseKernel(kern); clReleaseProgram(program);
    }

    static void buildGrid(float[] pos, int n, int[] cellCount, int[] cellData, int GRID, float CELL) {
        Arrays.fill(cellCount, 0);
        for (int i = 0; i < n; i++) {
            int cx=(int)(pos[i*3]/CELL), cy=(int)(pos[i*3+1]/CELL), cz=(int)(pos[i*3+2]/CELL);
            if (cx<0||cy<0||cz<0||cx>=GRID||cy>=GRID||cz>=GRID) continue;
            int cell=(cx*GRID+cy)*GRID+cz;
            int c=cellCount[cell];
            if (c<BUCKET_CAP) cellData[cell*BUCKET_CAP+c]=i;
            cellCount[cell]=c+1;
        }
    }

    static void collisionRange(float[] pos, int n, int[] cellCount, int[] cellData, float radius, int[] out, int lo, int hi, int GRID, float CELL) {
        float d2 = (2*radius)*(2*radius);
        for (int i = lo; i < hi; i++) {
            float px=pos[i*3], py=pos[i*3+1], pz=pos[i*3+2];
            int cx=(int)(px/CELL), cy=(int)(py/CELL), cz=(int)(pz/CELL);
            int hits=0;
            for (int dx=-1;dx<=1;dx++) for (int dy=-1;dy<=1;dy++) for (int dz=-1;dz<=1;dz++){
                int nx=cx+dx, ny=cy+dy, nz=cz+dz;
                if (nx<0||ny<0||nz<0||nx>=GRID||ny>=GRID||nz>=GRID) continue;
                int cell=(nx*GRID+ny)*GRID+nz;
                int cnt=Math.min(cellCount[cell], BUCKET_CAP);
                for (int b=0;b<cnt;b++){
                    int j=cellData[cell*BUCKET_CAP+b];
                    if (j==i) continue;
                    float ddx=px-pos[j*3], ddy=py-pos[j*3+1], ddz=pz-pos[j*3+2];
                    if (ddx*ddx+ddy*ddy+ddz*ddz < d2) hits++;
                }
            }
            out[i]=hits;
        }
    }

    // ======================================================================
    // (c) PATHFIND -- batched A* heuristic cost over (2K+1)^2 neighborhood
    //   For each agent: scan a local cost field, accumulate a distance-weighted
    //   heuristic toward its goal. Heavy per-entity arithmetic.
    // ======================================================================
    static void benchPathfind(int n, Result r) {
        int side = 2*K+1;
        float[] agentX = new float[n], agentY = new float[n], goalX = new float[n], goalY = new float[n];
        // shared cost field tile per agent (synthetic terrain cost) -- generate per-agent neighborhood on the fly
        Random rnd = seeded(n);
        for (int i=0;i<n;i++){ agentX[i]=rnd.nextFloat()*1000; agentY[i]=rnd.nextFloat()*1000; goalX[i]=rnd.nextFloat()*1000; goalY[i]=rnd.nextFloat()*1000; }

        double[] c1 = timeRuns(() -> {
            float[] out = new float[n];
            long t0=System.nanoTime();
            pathfindRange(agentX,agentY,goalX,goalY,side,out,0,n);
            return (System.nanoTime()-t0)/1e6;
        });
        r.cpu1Mean=mean(c1); r.cpu1Std=std(c1,r.cpu1Mean);

        double[] ca = timeRuns(() -> {
            float[] out = new float[n];
            long t0=System.nanoTime();
            parallelFor(n, (lo,hi)->pathfindRange(agentX,agentY,goalX,goalY,side,out,lo,hi));
            return (System.nanoTime()-t0)/1e6;
        });
        r.cpuAllMean=mean(ca); r.cpuAllStd=std(ca,r.cpuAllMean);

        String src = """
            #define K %d
            __kernel void pathcost(__global const float* ax, __global const float* ay,
                                   __global const float* gx, __global const float* gy,
                                   int n, __global float* out){
                int i = get_global_id(0);
                if (i>=n) return;
                float px=ax[i], py=ay[i], tx=gx[i], ty=gy[i];
                float best = 1e30f;
                for (int dy=-K; dy<=K; dy++) for (int dx=-K; dx<=K; dx++){
                    float cx=px+dx, cy=py+dy;
                    // synthetic terrain cost (cheap-ish transcendentals to mimic field eval)
                    float terr = 1.0f + 0.5f*sin(cx*0.13f)*cos(cy*0.17f) + 0.25f*sin((cx+cy)*0.07f);
                    float h = sqrt((cx-tx)*(cx-tx)+(cy-ty)*(cy-ty));
                    float cost = h*terr;
                    if (cost<best) best=cost;
                }
                out[i]=best;
            }""".formatted(K);
        long program = buildProgram(src);
        long kern = createKernel(program, "pathcost");
        double[][] g = timeRuns2(() -> {
            try (MemoryStack stack = stackPush()){
                IntBuffer ec = stack.mallocInt(1);
                long mAx=clCreateBuffer(context,CL_MEM_READ_ONLY,(long)n*4,ec); checkCL(ec.get(0));
                long mAy=clCreateBuffer(context,CL_MEM_READ_ONLY,(long)n*4,ec); checkCL(ec.get(0));
                long mGx=clCreateBuffer(context,CL_MEM_READ_ONLY,(long)n*4,ec); checkCL(ec.get(0));
                long mGy=clCreateBuffer(context,CL_MEM_READ_ONLY,(long)n*4,ec); checkCL(ec.get(0));
                long mOut=clCreateBuffer(context,CL_MEM_WRITE_ONLY,(long)n*4,ec); checkCL(ec.get(0));
                long t0=System.nanoTime();
                long e1=enqueueWrite(mAx,agentX), e2=enqueueWrite(mAy,agentY), e3=enqueueWrite(mGx,goalX), e4=enqueueWrite(mGy,goalY);
                clSetKernelArg1p(kern,0,mAx); clSetKernelArg1p(kern,1,mAy);
                clSetKernelArg1p(kern,2,mGx); clSetKernelArg1p(kern,3,mGy);
                clSetKernelArg1i(kern,4,n); clSetKernelArg1p(kern,5,mOut);
                long evK=enqueueKernel(kern,n);
                float[] out=new float[n];
                long evR=enqueueRead(mOut,out);
                clFinish(queue);
                cleanupPending();
                double totalMs=(System.nanoTime()-t0)/1e6;
                double kernMs=profMs(evK);
                double xferMs=profMs(e1)+profMs(e2)+profMs(e3)+profMs(e4)+profMs(evR);
                clReleaseEvent(e1);clReleaseEvent(e2);clReleaseEvent(e3);clReleaseEvent(e4);clReleaseEvent(evK);clReleaseEvent(evR);
                clReleaseMemObject(mAx);clReleaseMemObject(mAy);clReleaseMemObject(mGx);clReleaseMemObject(mGy);clReleaseMemObject(mOut);
                return new double[]{totalMs,kernMs,xferMs};
            }
        });
        fillGpu(r,g);
        clReleaseKernel(kern); clReleaseProgram(program);
    }

    static void pathfindRange(float[] ax, float[] ay, float[] gx, float[] gy, int side, float[] out, int lo, int hi){
        for (int i=lo;i<hi;i++){
            float px=ax[i], py=ay[i], tx=gx[i], ty=gy[i];
            float best=Float.MAX_VALUE;
            for (int dy=-K; dy<=K; dy++) for (int dx=-K; dx<=K; dx++){
                float cx=px+dx, cy=py+dy;
                float terr=1.0f + 0.5f*(float)Math.sin(cx*0.13f)*(float)Math.cos(cy*0.17f) + 0.25f*(float)Math.sin((cx+cy)*0.07f);
                float h=(float)Math.sqrt((cx-tx)*(cx-tx)+(cy-ty)*(cy-ty));
                float cost=h*terr;
                if (cost<best) best=cost;
            }
            out[i]=best;
        }
    }

    // ----------------------------------------------------------------------
    // parallel helper
    // ----------------------------------------------------------------------
    interface RangeOp { void apply(int lo, int hi); }
    static void parallelFor(int n, RangeOp op) {
        int tasks = CORES;
        int chunk = (n + tasks - 1) / tasks;
        List<Future<?>> fs = new ArrayList<>(tasks);
        for (int t = 0; t < tasks; t++) {
            int lo = t*chunk, hi = Math.min(n, lo+chunk);
            if (lo>=hi) break;
            fs.add(pool.submit(() -> op.apply(lo, hi)));
        }
        for (Future<?> f : fs) { try { f.get(); } catch (Exception e) { throw new RuntimeException(e); } }
    }

    // ----------------------------------------------------------------------
    // GPU helpers
    // ----------------------------------------------------------------------
    interface Run2 { double[] run(); }
    static double[][] timeRuns2(Run2 run) {
        for (int i=0;i<WARMUP;i++) run.run();
        double[][] out = new double[RUNS][];
        for (int i=0;i<RUNS;i++) out[i]=run.run();
        return out;
    }
    static void fillGpu(Result r, double[][] g) {
        double[] tot=new double[g.length], ker=new double[g.length], xf=new double[g.length];
        for (int i=0;i<g.length;i++){ tot[i]=g[i][0]; ker[i]=g[i][1]; xf[i]=g[i][2]; }
        r.gpuTotalMean=mean(tot); r.gpuTotalStd=std(tot,r.gpuTotalMean);
        r.gpuKernelMean=mean(ker); r.gpuXferMean=mean(xf);
    }

    static long buildProgram(String src) {
        try (MemoryStack stack = stackPush()) {
            IntBuffer ec = stack.mallocInt(1);
            long prog = clCreateProgramWithSource(context, src, ec);
            checkCL(ec.get(0));
            int err = clBuildProgram(prog, device, "-cl-fast-relaxed-math", null, NULL);
            if (err != CL_SUCCESS) {
                System.err.println("Build failed: " + getBuildLog(prog));
                throw new RuntimeException("clBuildProgram err " + err);
            }
            return prog;
        }
    }
    static long createKernel(long prog, String name) {
        try (MemoryStack stack = stackPush()) {
            IntBuffer ec = stack.mallocInt(1);
            long k = clCreateKernel(prog, name, ec);
            checkCL(ec.get(0));
            return k;
        }
    }
    static long enqueueWrite(long mem, float[] data) {
        try (MemoryStack stack = stackPush()) {
            FloatBuffer fb = memAllocFloat(data.length);
            fb.put(data).flip();
            PointerBuffer ev = stack.mallocPointer(1);
            checkCL(clEnqueueWriteBuffer(queue, mem, false, 0, fb, null, ev));
            // NOTE: buffer must live until clFinish; rely on non-blocking + we free after finish via GC of direct buffer.
            pending.add(fb);
            return ev.get(0);
        }
    }
    static long enqueueWriteI(long mem, int[] data) {
        try (MemoryStack stack = stackPush()) {
            IntBuffer ib = memAllocInt(data.length);
            ib.put(data).flip();
            PointerBuffer ev = stack.mallocPointer(1);
            checkCL(clEnqueueWriteBuffer(queue, mem, false, 0, ib, null, ev));
            pendingI.add(ib);
            return ev.get(0);
        }
    }
    static long enqueueRead(long mem, float[] out) {
        try (MemoryStack stack = stackPush()) {
            FloatBuffer fb = memAllocFloat(out.length);
            PointerBuffer ev = stack.mallocPointer(1);
            checkCL(clEnqueueReadBuffer(queue, mem, false, 0, fb, null, ev));
            readbacksF.add(new Object[]{fb, out});
            return ev.get(0);
        }
    }
    static long enqueueReadI(long mem, int[] out) {
        try (MemoryStack stack = stackPush()) {
            IntBuffer ib = memAllocInt(out.length);
            PointerBuffer ev = stack.mallocPointer(1);
            checkCL(clEnqueueReadBuffer(queue, mem, false, 0, ib, null, ev));
            readbacksI.add(new Object[]{ib, out});
            return ev.get(0);
        }
    }
    // direct buffers kept alive until clFinish, freed after
    static final List<FloatBuffer> pending = new ArrayList<>();
    static final List<IntBuffer> pendingI = new ArrayList<>();
    static final List<Object[]> readbacksF = new ArrayList<>();
    static final List<Object[]> readbacksI = new ArrayList<>();

    static long enqueueKernel(long kern, int n) {
        try (MemoryStack stack = stackPush()) {
            PointerBuffer gws = stack.mallocPointer(1).put(0, n);
            PointerBuffer ev = stack.mallocPointer(1);
            checkCL(clEnqueueNDRangeKernel(queue, kern, 1, null, gws, null, null, ev));
            return ev.get(0);
        }
    }

    static double profMs(long event) {
        try (MemoryStack stack = stackPush()) {
            java.nio.LongBuffer start = stack.mallocLong(1);
            java.nio.LongBuffer end = stack.mallocLong(1);
            clGetEventProfilingInfo(event, CL_PROFILING_COMMAND_START, start, null);
            clGetEventProfilingInfo(event, CL_PROFILING_COMMAND_END, end, null);
            return (end.get(0) - start.get(0)) / 1e6; // ns -> ms
        }
    }

    // free direct buffers after each GPU run completes
    static {
        // hook drained manually after clFinish in each run via cleanupPending()
    }
    static void cleanupPending() {
        for (FloatBuffer b : pending) memFree(b);
        for (IntBuffer b : pendingI) memFree(b);
        for (Object[] o : readbacksF) memFree((FloatBuffer)o[0]);
        for (Object[] o : readbacksI) memFree((IntBuffer)o[0]);
        pending.clear(); pendingI.clear(); readbacksF.clear(); readbacksI.clear();
    }

    // ----------------------------------------------------------------------
    // CL info helpers
    // ----------------------------------------------------------------------
    static void checkCL(int err) { if (err != CL_SUCCESS) throw new RuntimeException("OpenCL error " + err); }

    static String getPlatformInfo(long platform, int param) {
        try (MemoryStack stack = stackPush()) {
            PointerBuffer sz = stack.mallocPointer(1);
            clGetPlatformInfo(platform, param, (ByteBuffer)null, sz);
            int bytes = (int) sz.get(0);
            ByteBuffer buf = stack.malloc(bytes);
            clGetPlatformInfo(platform, param, buf, null);
            return memUTF8(buf, bytes-1);
        }
    }
    static String getDeviceInfoStr(long dev, int param) {
        try (MemoryStack stack = stackPush()) {
            PointerBuffer sz = stack.mallocPointer(1);
            clGetDeviceInfo(dev, param, (ByteBuffer)null, sz);
            int bytes = (int) sz.get(0);
            ByteBuffer buf = stack.malloc(bytes);
            clGetDeviceInfo(dev, param, buf, null);
            return memUTF8(buf, bytes-1);
        }
    }
    static long getDeviceInfoLong(long dev, int param) {
        try (MemoryStack stack = stackPush()) {
            java.nio.LongBuffer val = stack.mallocLong(1);
            // some params are int (cl_uint); read as needed
            PointerBuffer sz = stack.mallocPointer(1);
            clGetDeviceInfo(dev, param, (ByteBuffer)null, sz);
            int bytes=(int)sz.get(0);
            if (bytes==4){ IntBuffer iv=stack.mallocInt(1); clGetDeviceInfo(dev,param,iv,null); return iv.get(0)&0xffffffffL; }
            clGetDeviceInfo(dev, param, val, null);
            return val.get(0);
        }
    }
    static String getBuildLog(long prog) {
        try (MemoryStack stack = stackPush()) {
            PointerBuffer sz = stack.mallocPointer(1);
            clGetProgramBuildInfo(prog, device, CL_PROGRAM_BUILD_LOG, (ByteBuffer)null, sz);
            int bytes=(int)sz.get(0);
            ByteBuffer buf = memAlloc(bytes);
            clGetProgramBuildInfo(prog, device, CL_PROGRAM_BUILD_LOG, buf, null);
            String s = memUTF8(buf, bytes-1);
            memFree(buf);
            return s;
        }
    }

    // ----------------------------------------------------------------------
    // summary + markdown
    // ----------------------------------------------------------------------
    static void printSummary(List<Result> results) {
        System.out.println("\n================ CROSSOVER SUMMARY ================");
        for (Kernel k : Kernel.values()) {
            Integer crossover = null;
            for (Result r : results) if (r.kernel==k && r.gpuTotalMean < r.cpuAllMean) { crossover = r.n; break; }
            System.out.printf("%-10s : GPU beats all-cores CPU at N >= %s%n", k,
                crossover==null ? "NEVER (within tested range)" : crossover.toString());
        }
    }

    static void emitMarkdown(List<Result> results) {
        // The Java program prints a machine-readable block; the wrapper script writes RESULTS.md.
        StringBuilder sb = new StringBuilder();
        sb.append("<<<RESULTS_CSV>>>\n");
        sb.append("kernel,N,cpu1_ms,cpu1_std,cpuAll_ms,cpuAll_std,gpuTotal_ms,gpuTotal_std,gpuKernel_ms,gpuXfer_ms\n");
        for (Result r : results) {
            sb.append(String.format(Locale.US, "%s,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f%n",
                r.kernel, r.n, r.cpu1Mean, r.cpu1Std, r.cpuAllMean, r.cpuAllStd,
                r.gpuTotalMean, r.gpuTotalStd, r.gpuKernelMean, r.gpuXferMean));
        }
        sb.append("<<<END_CSV>>>\n");
        sb.append("DEVICE,").append(deviceName).append(",GPU=").append(deviceIsGPU)
          .append(",PLATFORM=").append(platformName).append(",CORES=").append(CORES).append("\n");
        System.out.println(sb);
    }
}
