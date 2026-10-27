# Stage 2: T6030 ANE device-tree node (2026-10-27)

Offline work. Nothing was loaded, installed or rebooted on the M3. The M3 was used read-only, plus two small builds in `~/ane-stage2/` at `nice -n 19`.

Sources:

- macOS ADT dump: `private-dumps/macos-final-2026-10-27/adt-full-2026-10-27.txt` (private, git-ignored). Nodes `ane@F8000000` (line 8059), `dart-ane@F9800000`, `pmgr@40700000` (line 4229), `carveout-memory-map` (line 426).
- Kernel tree on the M3: `~/m3gpu/src/linux` at `0e1f46661376` (SiliconForest). Files: `arch/arm64/boot/dts/apple/t6030*.dtsi`, `t602x-die0.dtsi`, `t602x-pmgr.dtsi`, `drivers/accel/ane/`, `drivers/pmdomain/apple/pmgr-pwrstate.c`.
- m1n1 tree on the M3: `~/m3gpu/src/m1n1` at `aca1258`: `src/pmgr.c`, `proxyclient/m1n1/adt.py` (PMGR table layout).
- Installed DTB on the M3: `/boot/dtb-7.2.11-m3gpu+/apple/t6030-j516s.dtb`, sha256 `18baac96...` (same hash as in the Touch ID plan).

## 1. Addresses

The ADT `reg` values are relative to `arm-io`. The first `arm-io` range maps child 0x0 to parent 0x2_1000_0000 (size 0x1_9000_0000). The ADT `IODeviceMemory` list gives the same absolute values, so the conversion is checked twice.

### ANE (`ane@F8000000`, compatible `ane,t8020`)

| # | ADT reg (relative) | Absolute | Size | What it is | In the Linux node |
|---|---|---|---|---|---|
| 1 | 0x00_f800_0000 | 0x3_0800_0000 | 0x200_0000 (32 MB) | ANE engine window | Yes, `engine` |
| 2 | 0x01_4070_0000 | 0x3_5070_0000 | 0x1_8000 (96 KB) | PMGR window (ADT PMGR reg 27; the Linux `pmgr` node starts here) | No |
| 3 | 0x01_4072_4000 | 0x3_5072_4000 | 0x4000 (16 KB) | PMGR window (ADT PMGR reg 28) | No |
| 4 | 0x01_403c_0000 | 0x3_503c_0000 | 0x2_4000 (144 KB) | PMGR window (ADT PMGR reg 40) | No |
| 5 | 0x00_0100_0000 | 0x2_1100_0000 | 0xf7_4000 (15.5 MB) | PMGR window (ADT PMGR reg 45) | No |
| 6 | 0x01_542c_8000 | 0x3_642c_8000 | 0x4000 (16 KB) | PMGR window (ADT PMGR reg 36, next to `pmgr_mini`) | No |

Windows 2 to 6 are all PMGR register windows. macOS gives its ANE driver direct PMGR access. Linux does not: genpd owns PMGR, and the README rule forbids raw PMGR writes.

Engine layout check against T602x: on T602x the ANE DART is at engine +0x180_0000 and the ASC mailbox at engine +0x140_8000. On T6030 the ANE DART is at 0x3_0980_0000, which is also engine +0x180_0000. This supports, but does not prove, the same internal layout.

### Interrupts

| ADT | Linux | Owner |
|---|---|---|
| 0x240 | `<AIC_IRQ 576 IRQ_TYPE_LEVEL_HIGH>` | ANE |
| 0x241 | `<AIC_IRQ 577 IRQ_TYPE_LEVEL_HIGH>` | ANE DART |

Check: the ADT `wdt@542B0000` has interrupt 0x1e0. The installed DTB has `interrupts = <0x00 0x1e0 0x04>` for the same watchdog. So ADT numbers equal AIC numbers on T6030 (AIC3, 3 cells).

### DART (`dart-ane@F9800000`)

| Property | Value |
|---|---|
| Compatible | `dart,t8110` (Linux: `apple,t6030-dart`, `apple,t8110-dart`) |
| `dart-id` | 0x1d |
| `sid-count` | 16; `sid` = 0 and 15; `bypass-15` present |
| `page-size` | 0x4000 (16 KB). The raw bytes are `00400000`, little-endian. The earlier note said 0x400000; that was a misread. |
| `vm-base`, `vm-size` | 0x100_0000_0000, 0x300_0000_0000 |
| `dart-options` | 0x25 |
| Instances (`instance`) | DART 0 "LLT" 0x3_0980_0000, DART 1 "BRD" 0x3_0981_0000, DART 2 "BWR" 0x3_0982_0000, DAPF 0 "LLT" 0x3_0980_4000. All 0x4000. |
| Also present | `dart-tunables-instance-0..2`, `dapf-instance-0`, `error-reflector`. m1n1 applies none of these for the ANE today. |

## 2. Power and clocks

### The PMGR device table

The ADT PMGR `devices` property has 361 entries of 48 bytes. The layout is the one in m1n1 `adt.py` (`PMGRDevices`): flags at byte 0, parents at 4, `psidx` at 10, `psreg` at 11, id at 26, name at 32. The power-state address is `PMGR reg[ps-regs[psreg].reg] + ps-regs[psreg].offset + psidx * 8`. m1n1 `src/pmgr.c` defines `PMGR_FLAG_VIRTUAL 0x10`: a virtual entry has no power-state register.

| ID | Name | Flags | Parent | Power-state register |
|---|---|---|---|---|
| 0x1a4 | ANE-SYS-V | 0x10 (virtual) | 0x82 ANE_SYS | None |
| 0x82 | ANE_SYS | 0xa2 | 0x80 LW20 | PMGR +0x498 = 0x3_5070_0498 |
| 0xb3 | ANE_MPM | 0x10 (virtual) | 0x82 | None |
| 0xb4 | ANE_CPU | 0x34 (virtual) | 0x82 | None |
| 0xb5 | ANE_TD | 0x10 (virtual) | 0x82 | None |
| 0xb6 | ANE_BASE | 0x10 (virtual) | 0xb5 | None |
| 0x80 | LW20 | 0x30 (virtual) | 0x7f LS2 | None |

Result:

- ADT `power-gates` 0x1a4 and `clock-gates` 0x1a4 point to ANE-SYS-V. It is virtual. Its only real ancestor is ANE_SYS.
- ANE_SYS at PMGR +0x498 is the existing Linux domain `ps_ane_sys` (`t6030-pmgr.dtsi`, label `ane_sys`). It exists in the live DT on the M3 and in the installed DTB. It has no parent and no consumer there.
- The T6030 ANE has no separate MPM, TD, BASE, SET or CPU power states in PMGR. T602x has eight ANE domains (`ps_ane_sys_mpm` ... `ps_ane_cpu`); T6030 has one. The sub-blocks are probably switched inside the ANE or through the PMGR windows that macOS maps for the ANE driver. This is not checked.
- The first draft of this stage added domains at PMGR +0xc000..+0xc018 (the `psidx`/`psreg` values of the virtual entries). That was wrong: those entries are virtual and `ps-regs[13]` has mask 0. The draft was corrected before any commit. Do not add them.
- All 13 entries with flags 0x10 are absent from the Linux DT. This matches the rule.

### Clock IDs

ADT `clock-ids` = 0x14c, 0x14b, 0x14a. These are not PMGR device IDs: in the device table 0x14a..0x14c are MTP_CPU, MTP_SCM_FABRIC and MTP_SPI0, and the ANS node uses 0x150, which is "CPU-BUSY". They are also not indexes into the PMGR `clocks` table (58 entries). The namespace stays open (question Q1). The T602x Linux node has no clocks either, so Stage 2 does not need them.

Related ADT data: the PMGR `perf-domains` table has an "ANE" entry (index 8); the PMGR has `ane-dpe` = 1. DVFS of the ANE is a later topic.

## 3. Firmware facts (for Stage 3)

- ANE node: `pre-loaded` = 1, `segment-names` = `__TEXT;__DATA`, no `firmware-name`.
- `segment-ranges` (2 entries of 32 bytes: phys, firmware IOVA, remap, size):
  - `__TEXT`: phys 0x100_008c_c000, IOVA 0x0, remap 0x100_0000_0000, size 0xc_0000.
  - `__DATA`: phys 0x100_014f_c000, IOVA 0xc_0000, remap 0x100_000c_0000, size 0x10_c000.
- In the macOS boot, `__DATA` is exactly carve-out `region-id-53` (0x100_014f_c000, 0x10_c000). `__TEXT` sits inside `region-id-26`, right after `region-id-49` (the Linux `dcp-text` region starts at the same address).
- `boot-object-manifests` and `secure-boot-hashes` both have an `anef` entry. So iBoot loads an ANE firmware object for macOS.
- The T602x Linux node maps a 16 MB firmware alias at IOVA 0x100_0000_0000 (`ane_alias_iova`). The T6030 `remap` value is the same base. This supports the same design for Stage 3.
- On the running Linux boot, `/proc/device-tree/reserved-memory` has no region of size 0xc_0000 or 0x10_c000. The four `asc-firmware@...` regions have other sizes. So it is not known if iBoot preloads `anef` for the Asahi boot (question Q2).

## 4. Existing driver against what T6030 needs

| Item | `ane` (T8103, T6000) | `ane_t6021` (T602x, T8112) | T6030 need |
|---|---|---|---|
| Compatible | `apple,t8103-ane`, `apple,t6000-ane` | `apple,t6020/1/2-ane`, `apple,t8112-ane` | `apple,t6030-ane` (new) |
| Firmware | None (host drives the engine) | `request_firmware()`, SHA-256 check, boots the ASC CPU (RVBAR, RUN) | Pre-loaded by iBoot (`pre-loaded` = 1), if iBoot also does it for Asahi (Q2) |
| Power | Several domains | 8 domains raised in order, `ps_ane_cpu` also used as reset | 1 domain: `ps_ane_sys` |
| reg | Engine plus DART regions | `engine`, `pmgr`, `set` (raw PMGR reads in probe) | `engine` only |
| Interrupts | Several | 1 (`ane`), mailbox node uses the same line | 1 (`ane`, 576) |
| DART | `apple,t8103-dart` only (`ane_dart.c` checks it) | 3 DARTs, t8110 type | 3 DARTs plus 1 DAPF, t8110 type |
| Kconfig in the running kernel | `CONFIG_DRM_ACCEL_ANE` is not set | Same | A separate module avoids a kernel rebuild |

The `ane_t6021` probe reads the PMGR window directly (`ps_cpu_off`) to check that the CPU domain is on. On T6030 there is no ANE CPU power-state register, so that check cannot be ported. A T6030 boot path must use other evidence, for example the ASC `CPU_CONTROL` and `CPU_STATUS` words.

## 5. Deliverables

| File | What |
|---|---|
| `dts/t6030-ane.dtsi` | Source-form node: ANE (disabled), 3 DARTs (disabled), `power-domains = <&ps_ane_sys>` |
| `patches/0001-arm64-dts-apple-t6030-Add-ANE-node-and-ANE-DARTs-dra.patch` | Adds the fragment to the kernel tree and includes it from `t6030.dtsi` |
| `patches/0002-accel-ane-Add-a-probe-only-power-test-driver-for-T60.patch` | Adds `ane_t6030_probe.c`, a Kconfig entry and a Makefile line |
| `probe/` | The same driver as a standalone out-of-tree module (`make` on the M3) |
| `tools/make-ane-test-dtb.py` | Builds the test DTB from the installed DTB and fails if any line is removed |
| `docs/stage2-test-plan.md` | Test plan, gates and rollback |

## 6. Checks done (2026-10-27)

| Check | Result |
|---|---|
| `git apply --check` of both patches on `~/m3gpu/src/linux` | Pass. The tree was not changed. |
| Module build out of tree, `nice -n 19`, one job, in `~/ane-stage2/probe` | Pass, no warnings, 1.2 s. `vermagic` = `7.2.11-m3gpu+ SMP preempt mod_unload aarch64`. sha256 `302876ce...` after the `peek` bit-mask change. Not loaded. |
| Source DTS `t6030-j516s.dts` with the include, kernel dtc (`build-linux/scripts/dtc/dtc`) | Pass. The ANE node has one power domain. Stock dtc 1.8.1 cannot compile the source tree (the GPU node has float values). |
| Test DTB from the installed DTB (`make-ane-test-dtb.py`, dtc 1.8.1 on the Mac) | 45 lines added, 0 removed. `ane@308000000` is okay, the DARTs are disabled, `ane_sys` gets phandle 0xfb. |
| Live DT on the M3 | `power-controller@498` label `ane_sys` exists. No `ane` node. |
| `/sys/kernel/debug/pm_genpd` | Needs root. Not read. |

## 7. Open questions

| # | Question | Why it matters | How to answer |
|---|---|---|---|
| Q1 | What namespace do the ANE `clock-ids` 0x14a..0x14c use? | Possible clock or DVFS needs in Stage 3 | Compare with other nodes' IDs above 0x100 in m1n1 or in the ADT `nco` and `perf-domains` data |
| Q2 | Does iBoot preload `anef` when it boots m1n1 (the Asahi boot)? | If not, Linux must load the firmware itself, as `ane_t6021` does | First evidence: `RVBAR` in step B11. Proof: read the ADT `ane` node from m1n1 on a Linux boot (`segment-ranges`, carve-outs), or the m1n1 log |
| Q3 | Is ANE_SYS enough to make the engine window readable? | Decides if engine reads (`peek`) are safe | Run the plan up to step B9 first. Run `peek=7` only with a separate go (step B11). |
| Q4 | ANE_SYS has the virtual parent LW20 and the PMGR flag `notify_pmp`. Does Linux need to tell PMP when ANE_SYS changes? Very likely yes: after 5 unreported power cycles the M3 reset (window 2026-10-27 11:53). The ANE PTD bit is 5. See `stage2-window-result-2026-10-27.md`. | A power-on can time out, or the PMP can disagree. The kernel already switches `ane_sys` today (unused-domain power-off at boot) without known problems. | Watch `pmgr-pwrstate` messages in step B9 |
| Q5 | Which power domain does the ANE DART need? | Needed for stage 2b (DMA) | The ADT gives none. Test with `ps_ane_sys` in stage 2b. |
| Q6 | DART tunables and DAPF for the ANE are in the ADT but nothing applies them on Linux | Needed before any DMA | Port the m1n1 DAPF and tunable setup for `/arm-io/dart-ane` in stage 2b |
| Q7 | The ADT has no ANE mailbox node. Is the mailbox at engine +0x140_8000, as on T602x? | Stage 3 transport | Check after Q3 with one read of the mailbox control word |
| Q8 | The installed DTB differs from the kernel source (1163 diff lines per the Touch ID plan). | Patch 0001 is for the source tree. The test uses the installed DTB route. | The GPU session owns the source-to-installed sync |
