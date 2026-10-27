# Stage 0: LLM baseline on the M3 Pro (2026-10-26)

Machine: MacBook Pro 16-inch M3 Pro (J516s), 18 GB, Fedora Asahi Remix 44, kernel 7.2.11-m3gpu+ (SiliconForest, native GPU), native Mesa 26.3.0-devel (SiliconForest 7515336) in `/opt/mesa-m3`.
llama.cpp: 63b4b303 (build 11910). Tool: `llama-bench -p 512 -n 128 -r 3`. Models: bartowski GGUF, Q4_K_M. Runs started over SSH, no desktop load.

## Results

GPU: Vulkan build, `-ngl 99 -fa 0`, native Mesa selected with `VK_DRIVER_FILES`. CPU: separate build without Vulkan, 6 threads.

| Model | Backend | pp512 (tokens/s) | tg128 (tokens/s) |
|---|---|---|---|
| Llama 3.2 3B Q4_K_M (1.87 GiB) | GPU (Vulkan) | 303.46 ± 0.69 | 13.49 ± 0.85 |
| Llama 3.2 3B Q4_K_M | CPU | 127.14 ± 5.39 | 13.68 ± 0.11 |
| Llama 3.1 8B Q4_K_M (4.58 GiB) | GPU (Vulkan) | 124.97 ± 3.06 | 5.76 ± 0.21 |
| Llama 3.1 8B Q4_K_M | CPU | 66.58 ± 0.41 | 6.59 ± 0.25 |

An earlier CPU-only run (16:30) gave 163.41 / 15.30 (3B) and 68.19 / 6.72 (8B). The later CPU run was after GPU runs, with the machine warmer.

Correctness: the same prompt at temperature 0 gives the same 40 tokens on the GPU and on the CPU (`llm/stage0.sh check`, CHECK_SAME). The kernel log has no GPU fault, firmware halt or refused submit during the runs.

## After the memory floor fix (2026-10-26 20:43)

Same tools and models. Kernel 7.2.11-m3gpu+ with `agx-linux-kit/patches/t6030-pmp-memory-floor.patch`. Memory now reads at 123 GB/s (CPU, P cores) and 130 GB/s (GPU), up from about 32 GB/s.

| Model | Backend | pp512 (tokens/s) | tg128 (tokens/s) | tg128 before |
|---|---|---|---|---|
| Llama 3.2 3B Q4_K_M | GPU (Vulkan) | 356.30 | 48.06 | 13.49 |
| Llama 3.2 3B Q4_K_M | CPU | 169.02 | 55.74 | 13.68 |
| Llama 3.1 8B Q4_K_M | GPU (Vulkan) | 149.89 | 22.66 | 5.76 |
| Llama 3.1 8B Q4_K_M | CPU | 70.59 | 25.07 | 6.59 |

Token generation is now 3.5 to 4 times faster. GPU and CPU text still match (CHECK_SAME). The kernel log has no GPU fault, firmware halt or refused submit. The CPU is still a little faster than the GPU for token generation. The next limit for the GPU is the shader code, not the memory.

### Flash attention (2026-10-26 21:30)

The compiler fault is fixed with `agx-linux-kit/patches/mesa-agx3-fmul-narrow-wait.patch` (Mesa build folder only, not yet installed in `/opt/mesa-m3`).

| Model | fa | pp512 | tg128 |
|---|---|---|---|
| Llama 3.2 3B Q4_K_M | 0 | 357.44 | 47.83 |
| Llama 3.2 3B Q4_K_M | 1 | 357.06 | 47.44 |
| Llama 3.1 8B Q4_K_M | 0 | 150.08 | 22.87 |
| Llama 3.1 8B Q4_K_M | 1 | 150.07 | 22.78 |

At these lengths flash attention gives no speed change. It can help with long contexts, which use less memory with it. `test-backend-ops -o FLASH_ATTN_EXT`: 5368 of 5368 pass on the GPU. With `-fa on`, both models give the same text as the CPU (`-c 2048`; the 8B CPU run without a context limit was stopped by the out-of-memory killer at 13.8 GB).

The sections below describe the state before the fix.

## What the numbers say

- Prompt processing: the GPU is 1.9 to 2.4 times faster than the CPU.
- Token generation: the GPU is not faster than the CPU. The 8B model makes 5.8 tokens/s on the GPU and 6.6 on the CPU. The profile shows the reason: memory. Both the GPU and the CPU read memory at only about 32 GB/s on this system under Linux. The same machine reads 115 GB/s in macOS (12 threads). 4.6 GB of weights at 30 GB/s gives about 6.5 tokens/s, which matches both results. Dispatch overhead is under 10% of the token time. Details: `agx-linux-kit/docs/performance.md`, section "Memory bandwidth".
- Flash attention does not work yet: the native compiler refuses one instruction in the `flash_attn_f32_f16_aligned` shader ("AGX3 binary packer refused an instruction"). llama.cpp then stops. Use `-fa 0`.

## Problems found and fixed on the way

1. **Wrong Vulkan driver over SSH.** A shell outside the desktop session does not get the native Mesa variables, so the Vulkan loader picks Fedora's Mesa 26.2.5. That driver writes the older compute launch format (first word `0x00001212`). The kernel gate (`drivers/gpu/drm/asahi-m3/g15/gate.rs`) correctly refuses it with EINVAL: `G15: rejecting CDM record`. llama-bench then reported impossible speeds (2,800 to 3,200 tokens/s) because no GPU work ran. Fix: set `VK_DRIVER_FILES=/opt/mesa-m3/share/vulkan/icd.d/asahi_icd.aarch64.json`. `llm/stage0.sh` now does this, and marks GPU results as invalid if any submit fails.
2. **CPU numbers from a Vulkan build are wrong.** With Vulkan compiled in, llama.cpp sends large prompt batches to the GPU even with `-ngl 0`. The script now uses a separate CPU-only build.
3. The native driver passes a direct Vulkan compute test: 50 dispatches over 16,777,216 values, 0 wrong (`agx-linux-kit/tests/vk-compute.c`).

## Next steps

1. Done: the refused instruction was an f32 multiply with a half result and a wide wait. Fixed by `agx-linux-kit/patches/mesa-agx3-fmul-narrow-wait.patch`.
2. Done: memory ran at about 32 GB/s because no driver requested the PMP memory floor. With the patch, the 8B model makes 22.7 (GPU) and 25.1 (CPU) tokens/s.
3. Run the same models with Metal on macOS for the Linux vs macOS comparison (macOS stays offline; copy the models over the local link).

## G2: prompt and generation speed against macOS (2026-10-27)

Reference: published llama.cpp Metal results for the M3 Pro (18-core GPU), Llama 2 7B Q4_0: pp512 341.67, tg128 30.74 tokens/s. That model has 6.7 B parameters and a 3.56 GB file. Linux numbers below are for Llama 3.1 8B (8.0 B parameters, Q4_0 file 4.66 GB). Kernel 7.2.11-m3gpu+ with the memory floor, Mesa `/opt/mesa-m3` with the flash attention fix, llama.cpp `63b4b303b`, on the charger, 0 GPU faults except where noted.

### What the Vulkan backend sees

`ggml_vulkan: 0 = Apple M3 Pro (G15S B1) (Honeykrisp) | uma: 1 | fp16: 1 | bf16: 0 | warp size: 32 | shared memory: 32768 | int dot: 0 | matrix cores: none`

- No `VK_KHR_cooperative_matrix` (Mesa does not offer it on AGX), so llama.cpp uses its scalar and vector `mul_mm` shaders for prompt matrix multiplies. Metal's llama.cpp uses `simdgroup_matrix` for the same work.
- `VK_KHR_shader_integer_dot_product` is present, but not accelerated (`integerDotProduct8BitUnsignedAccelerated = false`), so llama.cpp does not use the integer dot path (`int dot: 0`).
- fp16 and int8 arithmetic, 16-bit and 8-bit storage, and subgroup size control are present; the subgroup size is fixed at 32; shared memory is 32 KB.
- For Honeykrisp, llama.cpp allows only the medium matmul tile and rolls the BK loop (`ggml-vulkan.cpp`, a choice made for M1 and M2).

### Profile of one pp512 run (8B Q4_K_M, `GGML_VK_PERF_LOGGER=1`)

Almost all GPU time is in `MUL_MAT`: the FFN matrices (14336 x 512 x 4096) take 27 ms per call, the attention matrices 8 ms. The matrix multiplies run at 2.1 to 2.2 TFLOPS. macOS at 341 tokens/s on 6.7 B parameters needs about 4.6 TFLOPS. So the gap is matrix-multiply speed, about 2 times.

### Measurements (`llama-bench -p 512 -n 128 -r 3 -ngl 99 -b 2048`, tokens/s)

| 8B model | ub 128: pp512 / tg128 | ub 256 | ub 512 |
|---|---|---|---|
| Q4_K_M, fa 0 | 133.2 / 22.75 | 145.3 / 22.65 | 149.9 / 22.75 |
| Q4_K_M, fa 1 | 132.6 / 22.65 | 144.7 / 22.45 | 150.2 / 22.68 |
| Q4_0 (requantized from Q4_K_M), fa 0 | 149.7 / 26.65 | 164.3 / 26.19 | 169.6 / 26.10 |
| Q4_0, fa 1 | 149.1 / 26.50 | 163.6 / 26.14 | 169.8 / 26.31 |

Test switches in a local llama.cpp copy (`llm/llama-vk-honeykrisp-test-switches.patch`, gated by environment variables, default unchanged), Q4_0, fa 1, ub 512, pp512:

| Setting | pp512 |
|---|---|
| Default (medium tile, BK loop rolled) | 169.8 |
| `GGML_VK_HK_TILES=l` (large tile) | 172.6 |
| `GGML_VK_HK_TILES=lm` | 172.5 |
| `GGML_VK_HK_NOROLL=1` | 166.4 |
| `GGML_VK_HK_NOROLL=1 GGML_VK_HK_TILES=l` | 138.7 |
| `GGML_VK_HK_TILES=s` (small tile only) | GPU fault: a shader writes to an unmapped address far outside the heap (`0x42d06738940`), repeatable; the kernel recovers and llama.cpp stops with `DeviceLost`. Not a valid setting; useful to cause a real GPU fault on purpose. |

The newest llama.cpp (`e86f5fd1e`, 27 commits later) has one Vulkan change, a CI fix for llvmpipe, so it was not rebuilt.

### Result against the targets

- **Token generation: at parity per byte.** 8B Q4_0 makes 26.65 tokens/s x 4.66 GB = 124 GB/s of weights read per second. macOS makes 30.74 x 3.56 GB = 109 GB/s. For the 3.56 GB Llama 2 7B file, Linux would make about 35 tokens/s. The 28 tokens/s target on an 8B Q4_0 would need 130 GB/s, 97 % of the measured GPU read peak (133.8 GB/s), so it is near the limit of this model size, not a software gap.
- **Prompt processing: about 59 % of macOS.** 169.8 against about 286 (341.67 scaled from 6.7 B to 8.0 B parameters). Batch sizes, flash attention and tile choice change it by less than 2 %.

### What is missing (G2c estimate)

The prompt gap is the matrix-multiply shader. Two ways to close it:

1. **`VK_KHR_cooperative_matrix` in Mesa Honeykrisp.** The AGX compiler has no matrix opcodes, and Metal's `simdgroup_matrix` runs on the same shader cores (8x8 fragments spread over the 32 lanes, SIMD shuffles and FMA). Mesa has cooperative-matrix lowerings only for hardware matrix units (radv, anv, nvk) and a flexible-size splitter (`nir_lower_cooperative_matrix.c`). The work: a new NIR pass that maps cmat load, store, muladd, conversions and element access to subgroup shuffles and FMA with a fixed 8x8 or 16x16 layout; exposing the feature with the supported sizes; then llama.cpp's coopmat shaders (`coopmat1`) run without changes. Estimate: 3 to 6 weeks for a working, tested version, with risk in register pressure and in the AGX compiler's shuffle cost. Expected gain: unknown until measured; Metal reaches about 72 % of the GPU's FP16 peak with this method, Linux now about 34 %.
2. **A llama.cpp matmul shader tuned for AGX** without cooperative matrix (register tiling with subgroup shuffles instead of shared memory). Smaller (1 to 2 weeks), stays in llama.cpp, no Mesa change, but it has to be maintained against upstream.

Neither is done yet.

### Box 1: medium tile tuned for the M3 (2026-10-27)

`GGML_VK_HK_MWARP="BLOCK,BM,BN,BK,WM,WN,WMITER,TM,TN,TK,WARP"` (in `llm/llama-vk-honeykrisp-test-switches.patch`) replaces the medium `mul_mm` tile on Honeykrisp; the quantized path keeps BK at 32 or more (its loaders read whole 32-element blocks; BK 16 failed 5 MUL_MAT tests). No new shader: the tile is a set of specialization constants of the existing `mul_mm.comp`.

Sweep, 8B Q4_0 pp512 (fa 1, ub 512, 2 runs each), default `128,64,64,32,32,32,2,4,2,1,32` = 169.9:

| Tile | pp512 |
|---|---|
| `128,64,64,32,32,32,2,4,4,1,32` | 169.5 |
| `128,64,64,32,32,32,1,8,4,1,32` | 166.5 |
| `128,64,128,32,32,64,2,4,4,1,32` | 196.2 |
| `128,128,64,32,64,32,2,4,4,1,32` | 202.0 |
| `128,128,64,16,64,32,2,4,4,1,32` | 203.5 (BK 16 is not valid for the quantized path) |
| `128,128,64,16,64,32,4,2,4,1,32` | 203.6 |
| `128,128,64,16,64,32,2,8,2,1,32` | 199.8 |
| `256,128,128,32,64,32,2,4,4,1,32` | 202.4 |
| `256,256,64,16,64,32,2,4,4,1,32` | 190.4 |
| `128,128,128,16,64,64,2,4,4,1,32` | 160.2 |
| `128,128,128,16,64,64,2,8,4,1,32` | 182.1 |
| `128,128,64,8,64,32,2,4,4,1,32` | 175.0 |

The gain comes from an 8 x 8 output tile per thread (64 accumulators) with BM 128, BN 64: fewer shared-memory loads per FMA. Larger tiles per thread or per workgroup are slower (register pressure, occupancy).

Chosen: `GGML_VK_HK_MWARP=128,128,64,16,64,32,2,4,4,1,32` (quantized path BK 32). Results, 3 runs each, 0 GPU faults:

| Check | Default tile | New tile |
|---|---|---|
| `test-backend-ops -o MUL_MAT` (f32, f16, q4_0, q4_1, q5_0, q5_1, q8_0, q4_K, q5_K, q6_K, mxfp4) | 1275 / 1275 pass | 1275 / 1275 pass |
| 8B Q4_0 pp512 / tg128 | 169.8 / 26.3 | **201.9** / 26.2 |
| 8B Q4_K_M pp512 | 150.2 | **169.4** |
| 40-token text, 8B Q4_K_M | `3fed9a1f` | `3fed9a1f` (same) |

Found on the way: the full `test-backend-ops -o MUL_MAT` stops with both tiles, because Mesa cannot compile `mul_mat_vec_q3_k_f32_f32` (`hk: vkCreateComputePipelines ... VK_ERROR_UNKNOWN`). Q3_K models will fail on this GPU until that is fixed.
