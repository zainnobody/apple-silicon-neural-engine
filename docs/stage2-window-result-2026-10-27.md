# Stage 2 window result (2026-10-27, 11:53)

## What happened

| Time | Event | Source |
|---|---|---|
| 11:53 | Test boot with the ANE test DTB. ANE node okay. `ane-window-restore.service` put `boot.bin.stageE` back at 11:53:24. | Coordinator, journal of boot `899587a9` |
| 11:53:36 | `power-controller@498: sync_state() pending due to 308000000.ane` | Kernel log |
| 11:53:54 | First `ane-check.sh` run: `insmod` refused. SELinux label `user_home_t` on a module in `/home`. The coordinator copied the module to `/lib/modules/7.2.11-m3gpu+/ane-test/` (label `modules_object_t`, same hash). | Coordinator |
| 11:53:54.144 to 11:53:55.185 | Five cycles `ane_sys on` / `ane_sys released`, then `probe done: 5 cycle(s), peek=0x0`. No error line. | Kernel log |
| 11:53:55.185 | Last journal entry of that boot. | `journalctl --list-boots` |
| about 11:54:20 at the latest | The M3 reset. The next boot's PMP was ready at 11:54:53, and the boot takes at least about 30 s before that. The exact second is not recorded. | Journal of boot `afe03253` |
| next boot | `macsmc-reboot: PMU logged 1 boot error(s) and 0 panic(s)`. This line is in no other boot of the day. | Kernel log, boots -9 to 0 |
| 11:57 | Normal stageE boot on the network. The rollback worked. | Coordinator |

Phase 2 (`peek`) did not run. No engine register was read.

## What the evidence shows

1. **It was a hardware or firmware reset, not a kernel crash.** "Boot error" means the PMU saw the OS running (`boot_stage` 0x30) and then a reset without a clean shutdown (`drivers/power/reset/macsmc-reboot.c`). The panic count is 0. `kernel.panic` is 0 on this M3, so a kernel panic hangs and does not reset. The NMI hard-lockup watchdog is off, and `RuntimeWatchdogUSec=0`.
2. **The reset came after the power cycles, not during them.** All five power-on and power-off steps returned without a `pmgr-pwrstate` error. The domain was off after cycle 5.
3. **The `sync_state` path is not the cause.** When the ANE device binds, `of_genpd_sync_state()` (`drivers/pmdomain/core.c:3726`) clears `stay_on` and calls `genpd_power_off()` only for the genpds of that provider, here `ane_sys`. `ane_sys` was already off. No other domain has the ANE as a consumer (the DARTs are disabled). So this path writes nothing.

## Most likely cause: the PMP did not know about the ANE power-up

On T6030, Linux starts the PMP itself (`apple-pmp-report`, `starts_pmp`). Each SoC device that the PMP tracks has a PTD request bit and an acknowledge bit. A Linux consumer reaches its PMGR domain through a PMP report entry, a genpd that sets the request bit and waits for the ack. Our test powered `ane_sys` directly, with no request.

| Evidence | Source |
|---|---|
| The ADT PMGR flags of ANE_SYS (0xa2) include `notify_pmp`. | ADT PMGR device table, m1n1 `adt.py` flag names |
| The ADT ANE node maps 0x3_503c_0000, size 0x24000. That is the PMP report block (`pmp-report@3503c0000` in the live DT). So the macOS ANE driver talks to the PMP report block itself. | ADT, live DT |
| On T602x, Asahi has `pmp_report_ane_sys: report@b` with `power-domains = <&ps_ane_sys>`. | `t602x-die0.dtsi:110` |
| The T6030 PMP overlay has entries for DISP (7), DISPEXT0 (8), DISPEXT1 (9) and ANS (0x10), and none for the ANE. The running request is 0x10380. | `drivers/soc/apple/t6030-j516s-pmp.dtso`, boot log |
| The PMP tunables have an "ANE-TO-SMC" channel. So the PMP reports ANE data to the SMC. | Same overlay, `apple,tunable-ptd-range` |
| ADT `soc-device` table: ANE0 is soc-device ID 6. On T6030 the PTD bit is the ID minus 1, so the ANE bit is **5**. The table also gives DISP ID 8 (bit 7), DISPEXT0/1 IDs 9/10 (bits 8/9) and ANS ID 17 (bit 16), which match the running request. | ADT PMGR `soc-device`, `pmp-report.c:105` |

Confidence: medium, about 70 percent. Other causes that the data does not exclude:

- The virtual ADT parents of ANE_SYS (LW20, then LS2) or the ANE clocks need setup that macOS does through its PMGR windows. Then an ANE_SYS transition could leave the fabric in a bad state that a hardware watchdog catches later.
- Five fast cycles (one every 200 ms) are the trigger, not the first power-up.

## Next step (proposal, needs the coordinator and the user)

Give the ANE a PMP report entry, then repeat a smaller test.

1. **Report entry for the ANE.** Add `report@5` (label `pmp-ane`, `compatible = "apple,t6000-pmp-v2-report-entry"`, `#power-domain-cells = <0>`, not always-on, ack expected) under `pmp-report@3503c0000`, and link the ANE to it. Two ways:
   - a. In the kernel: the T6030 PMP overlay and the display gate (`t6030-j516s-pmp.dtso`, `t6030-pmp.dtso`, `t6030-display-gate.c`, built in). The gate already links the DCP and the GPU to PMP nodes with an `of_changeset`. It would add the entry and set the ANE node's `power-domains`. This needs a kernel rebuild and install, so the GPU session owns it.
   - b. In the test module only: at module init, apply a small overlay with `report@5` under the live `pmp-report` node, then change the ANE node's `power-domains` to `<ps_ane_sys, pmp-ane>` before the driver registers. No kernel rebuild, and the same test DTB works. It uses `of_overlay_fdt_apply()` and `of_changeset`, which are both exported.
2. **Order.** Set the request and wait for the ack first, then power `ane_sys` on. For power-off: `ane_sys` off first, then clear the request. This is the DCP order on T6030 (entry acknowledged before the consumer starts). The T602x parent link does the opposite on power-up. This is an assumption, so the module logs each step.
3. **Smaller test.** One cycle only. Wait 120 s with the ANE off, then read the PMU line again before any second cycle. If the ack does not come within 50 ms, `pmp-report` returns an error and `ane_sys` stays off. That is a safe stop.
4. **Same safety as before.** Phase 2 (`peek`) only after a clean phase 1 and 120 s with no reset.

Time for way b: about half a day of offline work, then one reboot window of about 10 minutes.

## Script changes after this window

- `ane-boot.sh` installs the module to `/lib/modules/7.2.11-m3gpu+/ane-test/` and runs `restorecon` (SELinux does not let `insmod` load a file from `/home`).
- `ane-check.sh` loads the module from that path, and refuses phase 1 unless a genpd named `pmp-ane` exists. So the unreported power-up cannot run again by mistake.
