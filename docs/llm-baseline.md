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

## What the numbers say

- Prompt processing: the GPU is 1.9 to 2.4 times faster than the CPU.
- Token generation: the GPU is not faster than the CPU. The 8B model makes 5.8 tokens/s on the GPU and 6.6 on the CPU. The profile shows the reason: memory. Both the GPU and the CPU read memory at only about 32 GB/s on this system under Linux. The same machine reads 115 GB/s in macOS (12 threads). 4.6 GB of weights at 30 GB/s gives about 6.5 tokens/s, which matches both results. Dispatch overhead is under 10% of the token time. Details: `agx-linux-kit/docs/performance.md`, section "Memory bandwidth".
- Flash attention does not work yet: the native compiler refuses one instruction in the `flash_attn_f32_f16_aligned` shader ("AGX3 binary packer refused an instruction"). llama.cpp then stops. Use `-fa 0`.

## Problems found and fixed on the way

1. **Wrong Vulkan driver over SSH.** A shell outside the desktop session does not get the native Mesa variables, so the Vulkan loader picks Fedora's Mesa 26.2.5. That driver writes the older compute launch format (first word `0x00001212`). The kernel gate (`drivers/gpu/drm/asahi-m3/g15/gate.rs`) correctly refuses it with EINVAL: `G15: rejecting CDM record`. llama-bench then reported impossible speeds (2,800 to 3,200 tokens/s) because no GPU work ran. Fix: set `VK_DRIVER_FILES=/opt/mesa-m3/share/vulkan/icd.d/asahi_icd.aarch64.json`. `llm/stage0.sh` now does this, and marks GPU results as invalid if any submit fails.
2. **CPU numbers from a Vulkan build are wrong.** With Vulkan compiled in, llama.cpp sends large prompt batches to the GPU even with `-ngl 0`. The script now uses a separate CPU-only build.
3. The native driver passes a direct Vulkan compute test: 50 dispatches over 16,777,216 values, 0 wrong (`agx-linux-kit/tests/vk-compute.c`).

## Next steps

1. Find the instruction that the compiler refuses in the flash-attention shader. Report it with the upstream draft.
2. Find why memory runs at about 32 GB/s under Linux (probably a low memory performance state). Measure the same test in macOS for the reference. If the full bandwidth comes back, token generation could reach about 25 tokens/s for the 8B model.
3. Run the same models with Metal on macOS for the Linux vs macOS comparison (macOS stays offline; copy the models over the local link).
