# Stage 4 input: an h15g program compiled on the M5 host Mac (2026-10-27)

Result: the ANE compiler on this host Mac (M5, macOS 26.7.1) compiles a program for `h15g`, the M3 Pro ANE. A macOS boot on the M3 is not needed to make Stage 4 programs.

## What runs

- `anec_try.c` is our own harness. It loads `ANECompiler.framework` with `dlopen` and calls the exported C function `ANECCompile(inputs, options, callback)`. The options key `TargetArchitecture` selects the target. This is a private, undocumented API, and the signature is inferred, so it can change with a macOS update.
- `model/model.mil` is a hand-written MIL program: one fp16 1x1 conv (a 16 by 16 matmul), input `[1,16,1,16]`. `model/weights/weight.bin` holds the weights (identity times 0.5, 640 bytes, sha256 `9ba352de...`).

```bash
clang -o anec_try anec_try.c -framework CoreFoundation
```

```bash
NK1=NetworkSourceFileName NK2=NetworkSourcePath ./anec_try <dir with model.mil and weights/> model.mil h15g model.hwx
```

Output: `ANECCompile returned 0` in about 20 ms, and a 65536-byte file. No sudo, no entitlement and no install were needed. Nothing blocked a step.

## Evidence that the output is an h15 program

- The header is `cefaefbe 80000000 06000000 02000000`: magic 0xbeefface, cpusubtype 6.
- The cpusubtype follows the target: h13g 4, h14g 5, h15g 6, h16g 7, h17g 9. Apple's own shipped hwx files show the same mapping.
- The five targets give five different files.
- The target list in the compiler after `TargetArchitecture` is h14g, h13g, h14g.n301, h15g, h16g, h17g, h17g.n301a.
- Our M3 ioreg dump names the M3 Pro ANE architecture `h15g` (`docs/research-2026-10-27.md`). So `h15g`, not `h15c` or `h15p`, is the right target.

## Where the outputs are

The `.hwx` files are compiler output from Apple's compiler. They stay private: `private-dumps/ane-hwx-2026-10-27/` with `SHA256SUMS` (h15g sha256 `243c26c94a969afb6129689599ad3d9469141588c543653885fe209e374507bd`).

## Not proven

- The program has not run on an ANE. There is no h15 hardware on this Mac.
- Numerical results are not checked.
- A Linux runtime that loads the hwx and submits it to the ANE driver does not exist yet for T6030. That needs a booted ANE firmware (Stage 3).
