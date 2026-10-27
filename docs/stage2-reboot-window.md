# ANE reboot window runbook (about 15 minutes)

Status 2026-10-27 12:30: ran at 11:53. Phase 1 power cycles completed, then the M3 reset (PMU boot error). Cause and next step: `stage2-window-result-2026-10-27.md`. Do not run phase 1 again without a PMP report entry for the ANE; `ane-check.sh` now refuses it.

Original status: prepared, not run. Run it only after the user says go in the coordinator session. It is the compressed form of `stage2-test-plan.md` (steps B0 to B13 and F1 to F7). Read that file for the reasons and the full rollback.

## Already done (no root, nothing installed)

| Item | Where | Check |
|---|---|---|
| Test DTB folder, 46 DTBs, only J516S changed | `~/ane-stage2/dtbs-ane/` on the M3 | J516S: 45 lines added, 0 removed. sha256 `d3bd370c96378e7a990b75b0085fb1fc15e1456493f602356fc237820eeaac8c`. The 45 other DTBs are byte-equal to `/boot/dtb-7.2.11-m3gpu+/apple/`. |
| Installed J516S DTB (source of the test DTB) | `/boot/dtb-7.2.11-m3gpu+/apple/t6030-j516s.dtb` | sha256 `18baac96...` on 2026-10-27 08:16 |
| Probe module | `~/ane-stage2/probe/ane_t6030_probe.ko` | vermagic `7.2.11-m3gpu+`, sha256 `302876ce87f6c78397ce62f15fae23501700aecee9414aff325562d47d0ab8e5` |
| m1n1 | `/usr/local/lib/m3gpu/m1n1-aca1258.bin` | Same file as in the Touch ID plan |

## Gates (check before minute 0)

1. The user says go in the coordinator session. The coordinator pauses the GPU and LLM sessions.
2. AC power on and battery above 50 percent. On 2026-10-27 08:17 the battery was at 41 percent on AC.
3. Snapshot: `sudo snapper create -d "before ANE stage 2"`.
4. The user knows the boot picker (hold the power button at power on) and has the macOS password for F5.

## Window

Commands with `sudo` are for the user to type in a terminal on the M3. Claude runs the others over SSH.

| Min | Who | Command | Pass | Else |
|---|---|---|---|---|
| 0 | User | `sudo m3gpu-boot status` | `boot.bin` = `boot.bin.stageE`, `boot.bin.stock` present. Write both hashes down. | Stop. |
| 0 | Claude | `sha256sum /boot/dtb-7.2.11-m3gpu+/apple/t6030-j516s.dtb ~/ane-stage2/dtbs-ane/t6030-j516s.dtb` | `18baac96...` and `d3bd370c...` | Stop. Rebuild with `make-ane-test-dtb.py`. |
| 1 | User | `sudo ~/m3gpu/scripts/make-bootbin.sh ane /usr/local/lib/m3gpu/m1n1-aca1258.bin ~/ane-stage2/dtbs-ane chosen.asahi,t6030-gpu=1 chosen.asahi,t6030-dcp=1 chosen.asahi,t6030-dcpext=1` | A sha256 line. File not smaller than `boot.bin.stageE`. | `sudo rm /boot/efi/m1n1/boot.bin.ane`. Stop. |
| 2 | Claude | Compare `boot.bin.ane` with `boot.bin.stageE` (only the J516S DTB region differs). Run `~/m3gpu/scripts/pre-reboot-check.sh`. | Pass | Delete `boot.bin.ane`. Stop. |
| 3 | User | `sudo ~/m3gpu/scripts/use-bootbin.sh ane` | Hash equals `boot.bin.ane` | `sudo m3gpu-boot use-stageE` |
| 3 | User | `sudo reboot` | Linux back on the network in about 2 minutes | F5 in `stage2-test-plan.md` |
| 6 | Claude | `~/m3gpu/scripts/health-check.sh`; `cat /proc/device-tree/soc/ane@308000000/status`; `dmesg | grep -i -E "pmgr|genpd|ane"` | Status `okay`, no new errors, GPU and display as before | Go to the rollback row |
| 7 | User | `sudo cat /sys/kernel/debug/pm_genpd/ane_sys/current_state` | Record it | None |
| 8 | User | `sudo insmod ~/ane-stage2/probe/ane_t6030_probe.ko cycles=5 hold_ms=200` | `dmesg` shows 5 on/released pairs and `probe done` | Freeze: hold power 10 s, power on, rollback row |
| 9 | User | `sudo cat /sys/kernel/debug/pm_genpd/ane_sys/current_state`; `sudo rmmod ane_t6030_probe` | `ane_sys` off | Record |
| 10 | User, separate go | `sudo insmod ~/ane-stage2/probe/ane_t6030_probe.ko peek=7`; `dmesg | tail`; `sudo rmmod ane_t6030_probe` | Three reads, values not all ones. Record `RVBAR`. | Freeze or SError: hold power 10 s, power on, rollback row |
| 12 | User | Rollback: `sudo m3gpu-boot use-stageE`, then `sudo reboot` | Normal boot, `boot.bin` = stageE hash | F5 |
| 15 | Claude | `~/m3gpu/scripts/health-check.sh` | Pass | |

The test DTB is inert after `rmmod`. If the user wants to save the second reboot, keep `boot.bin.ane` and switch back at the next planned reboot.

## No firmware handshake in this window

Track B (`docs/stage3-protocol-check.md`) compared the H14 driver with the public H16 bring-up code. Verdict: PARTLY. The first leg (release the ASC CPU, wait for READY `0x08042006`) is the same on H14 and H16, and the T6030 data points to the H14 register layout. But a handshake on this boot is not possible safely:

- The handshake needs the iBoot firmware copy in RAM, protected by `no-map` reserved memory at known physical addresses. The Linux boot has no such region today, and the addresses are not known. Without the reservation, Linux may already use that RAM, and a released ANE CPU could run garbage or corrupt kernel memory.
- The SCRATCH block location on T6030 is not proven (about 65 percent the H14 offset).
- Track B estimates a 20 to 30 percent chance that one reboot shows READY, even with the reservation.

So minute 10 does reads only. The `RVBAR` value tells if iBoot latched a firmware entry on the Linux boot. The draft first-leg module is kept as `patches/drafts/h15-boot-first-leg.patch` for a later window.

## What the next window needs for a handshake

1. m1n1 must read the ANE `segment-ranges` from the ADT on the Linux boot and add `no-map` reserved-memory nodes for them, as it does for other coprocessors. That is an m1n1 change and needs the user's go. Estimate: 1 to 2 days of work, then one reboot.
2. Stage 2b DT: enable the three ANE DARTs and add `iommus` to the ANE node.
3. Then one window runs the first-leg module: power on, map the preload, release the CPU, wait for READY, stop.

## Scripts for the approved window (2026-10-27 11:50)

The user approved the window in the coordinator session at 11:45. The coordinator runs the reboots. The scripts are in `window/` here and in `~/window/` on the M3.

| Step | Command (on the M3) | Time |
|---|---|---|
| 1 | `sudo ~/window/ane-boot.sh` | About 1 minute. Checks, snapper snapshot, `boot.bin.ane`, one-time restore unit, switch. Ends with `READY`. Any failed check stops it with no change. `--dry-run` passed at 11:50. |
| 2 | `sudo reboot` | About 2 to 3 minutes. Early in this boot, `ane-window-restore.service` copies `boot.bin.stageE` back and removes itself. |
| 3 | `sudo ~/window/ane-check.sh` | About 1 minute. Phase 1: 5 power cycles. Phase 2: `peek=7` reads, only if phase 1 passes. Log `~/window/ane-check-<time>.log`, last line `ANE_CHECK PASS` or `FAIL`. |

No second reboot is needed for the ANE: the next reboot of the window is already a normal stageE boot. `--undo` before step 2 puts stageE back and removes the unit.

If the test boot does not come up:

1. Wait 3 minutes for the network. Then hold the power button for about 10 seconds and power on again.
2. In the GRUB menu (it shows), pick the stock `7.1.13` entry. The DTB still comes from `boot.bin.ane`, but if Linux reaches userspace, the restore unit puts stageE back. Reboot once more into the default.
3. If m1n1 or GRUB does not appear: hold the power button at power on, open the boot picker, start macOS. In Terminal: `diskutil list`, find the 500 MB EFI partition of the internal disk (do not guess), `sudo diskutil mount <it>`, `cp /Volumes/EFI/m1n1/boot.bin.stageE /Volumes/EFI/m1n1/boot.bin`, `shasum -a 256 /Volumes/EFI/m1n1/boot.bin` must start with `f3197272`, `diskutil unmount /Volumes/EFI`, restart into Linux. The user types the macOS password. In Linux the restore unit then sees a non-ANE `boot.bin`, logs it and removes itself.
