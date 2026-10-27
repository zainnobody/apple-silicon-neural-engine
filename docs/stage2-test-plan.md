# Stage 2 test plan: ANE power on and off on the M3 (T6030)

Status 2026-10-27: plan only. Nothing in this plan has run. Every step that installs, loads or reboots needs the user's own go.

Goal (README stage 2 gate): `ane_t6030_probe` binds to the new ANE node, powers `ane_sys` on and off through genpd, and the machine does not hang.

Data and design: `stage2-t6030-node.md`.

## What changes

| Item | Change | Effect at boot |
|---|---|---|
| J516S DTB | 45 added lines, 0 removed: `ane@308000000` (okay), 3 ANE DARTs (disabled), a phandle on the existing `ane_sys` domain | No built-in driver matches `apple,t6030-ane`. Disabled DARTs create no device. The only new effect: `ane_sys` now has a consumer, so genpd can keep it on from boot until a driver binds, if iBoot left it on (genpd `stay_on`). |
| Module | `~/ane-stage2/probe/ane_t6030_probe.ko`, loaded by hand with `insmod`, never installed | Powers `ane_sys` on, holds it, powers it off. No engine or PMGR writes. |
| Kernel, m1n1, boot entries | None | None |

## Gates (all must be true before B2)

1. The user says go in the session that owns reboots. The coordinator pauses the other M3 sessions first, mainly GPU and LLM tests.
2. A snapper snapshot of the Linux root exists.
3. The M3 is on AC power with more than 50 percent battery.
4. The user knows how to reach the boot picker (hold the power button at power on) and has the macOS password ready for step F5.
5. `m3gpu-boot status` shows the known `boot.bin` (today `boot.bin.stageE`) and a present `boot.bin.stock`. Write both hashes down.
6. The ESP has at least 40 MB free.

This DTB change can share one boot-file window with the Touch ID SEP DTB and the camera temporal-filter DTB. Combine them only if the combined DTB still shows added lines only, and each part matches its own plan. The ANE part is inert at boot, so it adds little risk to a shared window. If a combined boot fails, roll back all parts together.

## Steps

| Step | Who | What | Stop if |
|---|---|---|---|
| B0 | Claude | `m3gpu-boot status`. Check gate 5 hashes. Check that `/boot/dtb-7.2.11-m3gpu+/apple/t6030-j516s.dtb` still has sha256 `18baac96...`. | Any hash differs. Ask first. |
| B1 | Claude, no root | Copy `tools/make-ane-test-dtb.py` to `~/ane-stage2/`. Run it on the installed J516S DTB with `~/m3gpu/build-linux/scripts/dtc/dtc`. Put the result into a new folder `~/ane-stage2/dtbs-ane/` together with copies of all other `t6*` and `t81*` DTBs from `/boot/dtb-7.2.11-m3gpu+/apple/`. | The script reports any removed line, or the added count is not 45. |
| B1b | Claude, no root | Rebuild `~/ane-stage2/probe` with `nice -n 19 make -j1`. Check `modinfo -F vermagic` = `7.2.11-m3gpu+ SMP preempt mod_unload aarch64`. | Warnings, errors or another vermagic. |
| B2 | User types the sudo password | `sudo ~/m3gpu/scripts/make-bootbin.sh ane <m1n1-aca1258.bin from /usr/local/lib/m3gpu> ~/ane-stage2/dtbs-ane chosen.asahi,t6030-gpu=1 chosen.asahi,t6030-dcp=1 chosen.asahi,t6030-dcpext=1`. It writes only `boot.bin.ane`. The three options are the stage E options. | No sha256 line in the output, or the file is smaller than `boot.bin.stageE`. Delete `boot.bin.ane`. |
| B3 | Claude | Compare `boot.bin.ane` with `boot.bin.stageE`. Only the J516S DTB region may differ. Record both hashes. | More than the DTB differs. |
| B4 | Claude | Run `pre-reboot-check.sh` and `health-check.sh`. Report. | Any check fails. |
| B5 | User types the sudo password | `sudo ~/m3gpu/scripts/use-bootbin.sh ane`. | The hash after the copy differs from `boot.bin.ane`. Run F3. |
| B6 | User says go | One reboot into the current default kernel (`7.2.11-m3gpu+`). | See F4 and F5. |
| B7 | Claude, read-only | `/proc/device-tree/soc/ane@308000000` exists with status okay. The three `iommu@3098x0000` nodes are disabled. `uname -r` is unchanged. GPU, display, Wi-Fi and audio work as before. `dmesg` has no new `pmgr`, `genpd` or `ane` errors. | Missing node or new errors: F4. |
| B8 | User types the sudo password (read only) | `sudo grep -i ane /sys/kernel/debug/pm_genpd/pm_genpd_summary` and `sudo cat /sys/kernel/debug/pm_genpd/ane_sys/current_state`. Record the state before the module loads. | None. This only records. |
| B9 | User types the sudo password, user says go | `sudo insmod ~/ane-stage2/probe/ane_t6030_probe.ko`. Defaults: 1 cycle, 100 ms, peek off. Then `dmesg | tail -20` and repeat B8. | The machine freezes: F7. |
| B10 | User types the sudo password | `sudo rmmod ane_t6030_probe`, then `sudo insmod ... cycles=5 hold_ms=200`. Repeat B8. | Any `power on failed` or `power off failed` line, or a `pmgr-pwrstate` timeout. Stop and record. |
| B11 | Separate go from the user | `sudo rmmod ane_t6030_probe`, then `sudo insmod ... peek=1`. This reads one engine register (ASC `CPU_CONTROL`, engine +0x140_0044) while `ane_sys` is on. | The machine freezes: F7. A value of `0xffffffff` or an SError in `dmesg`: stop, do not repeat. |
| B12 | User types the sudo password | `sudo rmmod ane_t6030_probe`. Repeat B8: `ane_sys` must read off. | None. |
| B13 | User decides | Keep the test DTB for stage 2b, or roll back with `m3gpu-boot use-stageE` and one reboot. | None. |

### Pass criteria

- B9: `dmesg` shows `cycle 1: ane_sys on`, `cycle 1: ane_sys released`, `probe done: 1 cycle(s), peek=0`. B8 after B9 shows `ane_sys` off.
- B10: five clean cycles, no timeout, `ane_sys` off at the end.
- No hang, no SError, no new kernel warning.
- B11 (optional): a value that is not `0xffffffff`. RUN (bit 4) is expected to be 0, because the ANE CPU starts in reset after a power cycle. A RUN of 1 would mean firmware runs (see question Q2).

## Rollback

| Case | State | Action |
|---|---|---|
| F1: B1 or B1b fails | Nothing on the ESP | Delete `~/ane-stage2/dtbs-ane`. Nothing else. |
| F2: B2 or B3 fails | `boot.bin.ane` exists, `boot.bin` untouched | `sudo rm /boot/efi/m1n1/boot.bin.ane` |
| F3: after B5, before the reboot | `boot.bin` is the ANE file | `m3gpu-boot use-stageE` (no password). Check the hash against gate 5. |
| F4: Linux boots, something is wrong | `boot.bin` is the ANE file | `m3gpu-boot use-stageE`, then reboot. |
| F5: m1n1 stops, no network after 3 minutes, screen shows m1n1 text or stays black | Bad DTB or payload. The ESP still holds `boot.bin.stageE`, `.stock`, `.old`. | Same as Touch ID plan F5: force off, boot macOS from the boot picker, mount the ESP with `diskutil`, copy `m1n1/boot.bin.stageE` over `m1n1/boot.bin`, check the hash, unmount, boot Linux. The user types the macOS password. |
| F6: module load fails without a hang | Module not bound | `sudo rmmod ane_t6030_probe` if loaded. Record `dmesg`. No other action. |
| F7: the machine freezes during B9 to B11 | ANE or PMGR access stalled the SoC | Hold the power button about 10 seconds. Power on. The module is not installed, so it does not load again. Then decide between F4 and keeping the DTB. |

The stock boot entry and `boot.bin.stock` stay untouched in every step.

## Not in this stage

- No DART, no DMA, no mailbox, no firmware start. Those are stage 2b and stage 3.
- No change to `ane_t6021` or the M1 `ane` driver.
- No kernel rebuild. The module builds out of tree against `~/m3gpu/build-linux`.
