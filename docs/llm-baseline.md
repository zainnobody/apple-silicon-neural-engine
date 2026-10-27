# Stage 0: LLM baseline on the M3 Pro (2026-10-26)

Machine: MacBook Pro 16-inch M3 Pro (J516s), 16 GB, Fedora Asahi Remix 44, kernel 7.2.11-m3gpu+ (SiliconForest, native GPU), Mesa 26.2.5 (SiliconForest 7515336).
llama.cpp: 63b4b303 (build 11910). Tool: `llama-bench -p 512 -n 128 -r 3`. Models: bartowski GGUF, Q4_K_M.

## CPU results (valid)

CPU-only build (`-DGGML_VULKAN=OFF`), 6 threads.

| Model | Size | pp512 (tokens/s) | tg128 (tokens/s) |
|---|---|---|---|
| Llama 3.2 3B Instruct Q4_K_M | 1.87 GiB | 163.41 ± 1.08 | 15.30 ± 0.05 |
| Llama 3.1 8B Instruct Q4_K_M | 4.58 GiB | 68.19 ± 0.20 | 6.72 ± 0.01 |

## GPU results (not valid)

The Vulkan build reported 2,815 to 3,209 tokens/s for tg128. These numbers are not real. Every GPU job failed, so the GPU did no work.

- llama.cpp log: `DRM_IOCTL_ASAHI_SUBMIT failed: Invalid argument` (5,595 times for one model).
- Kernel log: `asahi: G15: rejecting CDM record at 0x...: 00001212 00000000 00000000 00000000`, then `IOCTL: submit failed! (err: EINVAL)`.
- The CPU rows of the Vulkan build also had wrong pp512 values (15,000 to 18,700), because llama.cpp sends large prompt batches to the GPU even with `-ngl 0`.

## Cause

The kernel has an admission gate for compute (CDM) command streams: `drivers/gpu/drm/asahi-m3/g15/gate.rs`, function `cdm`. It accepts only these first words: barriers, TERMINATE `0x40000000`, LINK `0x2000xxxx`, direct launch `0x00080000` exactly, and the two indirect launch forms. Any other record is refused with EINVAL before the GPU sees it.

The Mesa Vulkan driver emits a direct launch record with first word `0x00001212`. The block type (bits 31:29) is 0, which is a launch in Mesa's own decoder (`src/asahi/lib/agx3_cdm_decode_core.c`). The kernel gate expects a different word0 value for a direct launch. The pinned kernel and the pinned Mesa disagree on the compute launch encoding.

## Effect

- Vulkan compute does not run on this stack. Graphics (OpenGL, GLES, Vulkan rendering, the desktop) is not affected.
- The GPU stays healthy: `gles-readback` passed after the failed run, and the kernel log has no GPU fault or firmware halt.
- Local LLMs on the GPU need this fixed first. The CPU path works now.

## Next steps

1. Check if a newer SiliconForest kernel or Mesa commit aligns the gate and the launch encoding.
2. If not: find what `0x00001212` encodes (mode and payload fields in word 0), then extend the gate for that form with the same program and size checks as `0x00080000`. Test with a small Vulkan compute test before llama.cpp.
3. Add this to the upstream report draft for SiliconForest, after the user approves.
4. Do not remove the gate. It protects the GPU from bad command streams.
