#!/usr/bin/env bash
# ANE stage 2 reboot window, part 2: run as root in the ANE test boot.
#   sudo ~/window/ane-check.sh [--no-peek]
# Phase 1: 5 genpd power cycles of ane_sys (cycles=5 hold_ms=200), no engine access.
# Since the 11:53 window: phase 1 needs a PMP report entry for the ANE (genpd
# "pmp-ane"). Without it the PMP gets no request, and the M3 reset after the
# cycles (docs/stage2-window-result-2026-10-27.md).
# Phase 2: only if phase 1 passes: 1 cycle with peek=7, three engine READS
#          (CPU_CONTROL, CPU_STATUS, RVBAR). No engine or PMGR writes anywhere.
# Writes ~/window/ane-check-<time>.log and ends with ANE_CHECK PASS or FAIL.
set -uo pipefail

U=user
H=/home/$U
KREL=7.2.11-m3gpu+
# SELinux: insmod cannot load a module from /home (user_home_t). ane-boot.sh installs it here.
MOD=/lib/modules/$KREL/ane-test/ane_t6030_probe.ko
MOD_SHA=302876ce87f6c78397ce62f15fae23501700aecee9414aff325562d47d0ab8e5
STAGEE_SHA=f3197272d588f4b0a037c5f81f0cfb2c36dfc6c7398a4205910ed8b9cbaa0725
GD=/sys/kernel/debug/pm_genpd
DEV=308000000.ane
LOG=$H/window/ane-check-$(date +%Y%m%d-%H%M%S).log
PEEK=1; [ "${1:-}" = "--no-peek" ] && PEEK=0

[ "$(id -u)" = 0 ] || { echo "Run with sudo" >&2; exit 1; }
mkdir -p "$H/window"; touch "$LOG"; chown $U: "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "== ane-check.sh $(date '+%F %T')"

pre_fail=0
ok()  { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; pre_fail=1; }
state() { cat "$GD/ane_sys/current_state" 2>/dev/null || grep -E '^ane_sys ' "$GD/pm_genpd_summary"; }
mark() { dmesg | wc -l; }
since() { dmesg | tail -n +"$(( $1 + 1 ))"; }
ERR='SError|Internal error|Oops|BUG:|WARNING:|Unable to handle|timed? ?out|ane_t6030.*(fail|error)|pmgr.*(fail|error)|genpd.*(fail|error)'

echo "== Boot state"
[ "$(uname -r)" = "$KREL" ] && ok "kernel $KREL" || bad "kernel is $(uname -r)"
st="$(tr -d '\0' 2>/dev/null < /proc/device-tree/soc/ane@308000000/status)"
[ "$st" = okay ] && ok "ANE node present, status okay (test DTB is active)" || bad "ANE node status: '${st:-missing}'"
for d in 309800000 309810000 309820000; do
	s="$(tr -d '\0' 2>/dev/null < /proc/device-tree/soc/iommu@$d/status)"
	[ "$s" = disabled ] && ok "DART $d disabled" || bad "DART $d status '$s'"
done
cat /var/log/m3gpu/ane-window.log 2>/dev/null | tail -2
[ "$(sha256sum /boot/efi/m1n1/boot.bin | cut -d' ' -f1)" = "$STAGEE_SHA" ] \
	&& ok "boot.bin is back to stageE: the next reboot is the normal boot" \
	|| echo "WARN: boot.bin is NOT stageE. Before the next reboot run: sudo $H/window/ane-boot.sh --undo"
[ "$(sha256sum "$MOD" | cut -d' ' -f1)" = "$MOD_SHA" ] && ok "probe module hash" || bad "probe module hash differs"
lsmod | grep -q '^ane_t6030_probe' && { echo "note: module was loaded; unloading"; rmmod ane_t6030_probe; }
early="$(dmesg | grep -iE 'ane|pmgr|genpd' | grep -iE "$ERR" || true)"
[ -z "$early" ] && ok "no ANE, PMGR or genpd errors since boot" || { echo "WARN: earlier boot messages:"; echo "$early"; }
echo "ane_sys before: $(state)"
[ -d "$GD/pmp-ane" ] && ok "PMP report entry pmp-ane exists" \
	|| bad "no PMP report entry pmp-ane: an unreported ANE power-up reset the M3 at 11:53; not loading"
dmesg | grep "PMU logged" || true
sync

if [ "$pre_fail" != 0 ]; then
	echo "== Not the ANE test boot or a check failed: no module load"
	echo "ANE_CHECK FAIL (pre-checks)"; sync; exit 1
fi

echo "== Phase 1: 5 power cycles (no engine access)"
m=$(mark)
insmod "$MOD" cycles=5 hold_ms=200; rc=$?
sleep 1
out="$(since "$m")"; echo "$out"
on=$(echo "$out" | grep -c "$DEV: cycle [0-9]*: ane_sys on")
off=$(echo "$out" | grep -c "$DEV: cycle [0-9]*: ane_sys released")
done1=$(echo "$out" | grep -c "$DEV: probe done: 5 cycle")
err1="$(echo "$out" | grep -iE "$ERR" || true)"
after1="$(state)"; echo "ane_sys after: $after1"
rmmod ane_t6030_probe 2>/dev/null
P1=FAIL
[ $rc = 0 ] && [ "$on" = 5 ] && [ "$off" = 5 ] && [ "$done1" = 1 ] && [ -z "$err1" ] && echo "$after1" | grep -q off && P1=PASS
echo "PHASE1 $P1 (insmod rc=$rc, on=$on, released=$off, done=$done1, errors=$( [ -z "$err1" ] && echo none || echo yes))"
sync

P2=SKIPPED; RVBAR=""
if [ "$P1" = PASS ] && [ "$PEEK" = 1 ]; then
	echo "== Phase 2: peek=7, three engine reads (a freeze here means: hold power 10 s, power on)"
	sync; sleep 1
	m=$(mark)
	insmod "$MOD" cycles=1 peek=7; rc=$?
	sleep 1
	out="$(since "$m")"; echo "$out"
	ctl="$(echo "$out" | sed -n 's/.*CPU_CONTROL = \(0x[0-9a-f]*\).*/\1/p')"
	sts="$(echo "$out" | sed -n 's/.*CPU_STATUS = \(0x[0-9a-f]*\).*/\1/p')"
	RVBAR="$(echo "$out" | sed -n 's/.*RVBAR = \(0x[0-9a-f]*\).*/\1/p')"
	err2="$(echo "$out" | grep -iE "$ERR" || true)"
	after2="$(state)"; echo "ane_sys after: $after2"
	rmmod ane_t6030_probe 2>/dev/null
	P2=FAIL
	if [ $rc = 0 ] && [ -n "$ctl" ] && [ -n "$sts" ] && [ -n "$RVBAR" ] && [ -z "$err2" ]; then
		if [ "$ctl" = 0xffffffff ] || [ "$sts" = 0xffffffff ] || [ "$RVBAR" = 0xffffffffffffffff ]; then
			P2="FAIL (a read returned all ones: block not readable with ane_sys alone)"
		else
			P2=PASS
		fi
	fi
	echo "PHASE2 $P2 (CPU_CONTROL=$ctl CPU_STATUS=$sts RVBAR=$RVBAR)"
	if [ -n "$RVBAR" ]; then
		case "$RVBAR" in
			*10000000001) echo "RVBAR: latched at IOVA 0x100_0000_0000: evidence that iBoot preloaded the ANE firmware on this Linux boot (Q2)" ;;
			*[13579bdf]) echo "RVBAR: latched (bit 0 = 1) at another address" ;;
			*) echo "RVBAR: not latched (bit 0 = 0): no proof either way for Q2" ;;
		esac
	fi
	sync
fi

echo "== Verdict"
echo "PHASE1 (power cycles): $P1"
echo "PHASE2 (register reads): $P2"
if [ "$P1" = PASS ] && [[ "$P2" == PASS || "$P2" == SKIPPED ]]; then
	echo "ANE_CHECK PASS"
else
	echo "ANE_CHECK FAIL"
fi
echo "log: $LOG"
sync
