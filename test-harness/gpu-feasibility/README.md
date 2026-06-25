# gpu-feasibility -- entity-GPU feasibility probe (#15)

Standalone OpenCL-vs-CPU microbenchmark answering: **can entity-style data-parallel compute
beat a multithreaded CPU on the RTX 4060 at realistic Minecraft entity counts?**

This is a feasibility *probe*, deliberately decoupled from the server: it does **not** build
paperweight, does **not** run `applyAllPatches`, and does **not** touch any patched sources. It
just compiles one Java file against the LWJGL 3.3.6 OpenCL bindings and runs it.

## Run

```bash
./run.sh
```

`run.sh` locates the LWJGL 3.3.6 jars (`lwjgl`, `lwjgl-opencl`, natives-windows) in the Gradle
module cache, compiles `src/EntityGpuFeasibility.java`, and runs it against the real GPU.
The program **refuses to run on a CPU OpenCL fallback** -- if no GPU device is present it aborts,
so a reported "GPU" number is always a real GPU number.

## What it measures

Three representative entity kernels (cheap integration, moderate grid collision, heavy batched
pathfinding-style cost eval), each implemented in OpenCL, single-thread Java, and all-cores Java,
benchmarked at N = 100 / 1k / 10k / 50k / 100k with warmup + multiple measured runs.

See **[RESULTS.md](RESULTS.md)** for numbers, crossover points, and the recommendation.

## Files

- `src/EntityGpuFeasibility.java` -- the benchmark (kernels + CPU baselines + OpenCL host code).
- `run.sh` -- compile + run wrapper.
- `RESULTS.md` -- methodology, raw results, crossover analysis, recommendation.
