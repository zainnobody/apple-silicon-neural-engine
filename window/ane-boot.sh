#!/usr/bin/env bash
# ANE stage 2 reboot window, part 1: checks, then a ONE-TIME boot with the
# ANE test DTB. Run as root on the M3:  sudo ~/window/ane-boot.sh [--dry-run|--undo]
#
# m1n1 reads boot.bin on every boot, so a "one-time" DTB needs help. This
# script makes boot.bin.ane, makes it boot.bin, and installs a oneshot unit
# (ane-window-restore.service). Early in the next boot that unit copies
# boot.bin.stageE back and removes itself. So: reboot 1 = ANE test DTB,
# any later reboot = the normal stageE boot.
#
# --dry-run  all checks plus a build of the candidate boot.bin in /tmp; no writes to /boot or /etc
# --undo     before the reboot: boot.bin back to stageE, remove the restore unit
set -euo pipefail

MODE="${1:-run}"
U=user
H=/home/$U
ESP=/boot/efi/m1n1
KREL=7.2.11-m3gpu+
M1N1=/usr/local/lib/m3gpu/m1n1-aca1258.bin
M1N1_SHA=3118c16f20ee32dba8c8eee14e00fd37c31ab6ab200d12c7cad6c1e60500a710
INST=/boot/dtb-$KREL/apple
INST_DTB_SHA=18baac96873fabed31c1eca3a2495dd2ea534067120dddf71d373f1345acd47c
TDIR=$H/ane-stage2/dtbs-ane
TEST_DTB_SHA=d3bd370c96378e7a990b75b0085fb1fc15e1456493f602356fc237820eeaac8c
MOD=$H/ane-stage2/probe/ane_t6030_probe.ko
MOD_SHA=302876ce87f6c78397ce62f15fae23501700aecee9414aff325562d47d0ab8e5
STAGEE_SHA=f3197272d588f4b0a037c5f81f0cfb2c36dfc6c7398a4205910ed8b9cbaa0725
# shellcheck disable=SC2054  # the commas are part of each option
OPTS=(chosen.asahi,t6030-gpu=1 chosen.asahi,t6030-dcp=1 chosen.asahi,t6030-dcpext=1)
UNIT=/etc/systemd/system/ane-window-restore.service
RESTORE=/usr/local/sbin/ane-window-restore
LOG=$H/window/ane-boot-$(date +%Y%m%d-%H%M%S).log

[ "$(id -u)" = 0 ] || { echo "Run with sudo" >&2; exit 1; }
mkdir -p "$H/window"
touch "$LOG"; chown $U: "$LOG"
exec > >(tee -a "$LOG") 2>&1
echo "== ane-boot.sh $MODE $(date '+%F %T')"

sha() { sha256sum "$1" | cut -d' ' -f1; }
fail=0
ok()  { echo "ok:   $*"; }
bad() { echo "FAIL: $*"; fail=1; }

if [ "$MODE" = "--undo" ]; then
	systemctl disable ane-window-restore.service 2>/dev/null || true
	rm -f "$UNIT" "$RESTORE"; systemctl daemon-reload
	cp -f "$ESP/boot.bin.stageE" "$ESP/boot.bin.new"; sync
	mv -f "$ESP/boot.bin.new" "$ESP/boot.bin"; sync
	[ "$(sha "$ESP/boot.bin")" = "$STAGEE_SHA" ] && echo "UNDONE: boot.bin is stageE, restore unit removed" || { echo "UNDO FAILED: boot.bin is not stageE"; exit 1; }
	exit 0
fi

echo "== Checks"
[ "$(uname -r)" = "$KREL" ] && ok "kernel $KREL" || bad "kernel is $(uname -r)"
ac="$(cat /sys/class/power_supply/macsmc-ac/online)"; cap="$(cat /sys/class/power_supply/macsmc-battery/capacity)"
[ "$ac" = 1 ] && [ "$cap" -ge 50 ] && ok "AC on, battery $cap %" || bad "AC=$ac battery=$cap % (need AC and >= 50 %)"
[ "$(sha "$ESP/boot.bin")" = "$STAGEE_SHA" ] && ok "boot.bin is stageE" || bad "boot.bin is not stageE: $(sha "$ESP/boot.bin")"
[ "$(sha "$ESP/boot.bin.stageE")" = "$STAGEE_SHA" ] && ok "boot.bin.stageE present and intact" || bad "boot.bin.stageE missing or changed"
[ -f "$ESP/boot.bin.stock" ] && ok "boot.bin.stock present" || bad "boot.bin.stock missing"
[ "$(sha "$M1N1")" = "$M1N1_SHA" ] && ok "m1n1 aca1258" || bad "m1n1 hash differs"
[ "$(sha "$INST/t6030-j516s.dtb")" = "$INST_DTB_SHA" ] && ok "installed J516S DTB unchanged" || bad "installed J516S DTB changed"
[ "$(sha "$TDIR/apple/t6030-j516s.dtb" 2>/dev/null || sha "$TDIR/t6030-j516s.dtb")" = "$TEST_DTB_SHA" ] && ok "test J516S DTB" || bad "test J516S DTB hash differs"
n=0; for f in "$INST"/t6*.dtb "$INST"/t81*.dtb; do b=$(basename "$f"); [ "$b" = t6030-j516s.dtb ] && continue
	t="$TDIR/apple/$b"; [ -f "$t" ] || t="$TDIR/$b"; cmp -s "$f" "$t" || { bad "test folder differs: $b"; }; n=$((n+1)); done
ok "$n other DTBs compared"
[ "$(sha "$MOD")" = "$MOD_SHA" ] && ok "probe module $MOD_SHA" || bad "probe module hash differs"
[ "$(modinfo -F vermagic "$MOD" | cut -d' ' -f1)" = "$KREL" ] && ok "module vermagic" || bad "module vermagic"
[ ! -e /proc/device-tree/soc/ane@308000000 ] && ok "running DT has no ANE node (normal boot)" || bad "running DT already has the ANE node"
lsmod | grep -q '^ane_t6030_probe' && bad "probe module is loaded" || ok "probe module not loaded"
env="$(grub2-editenv list)"
echo "$env" | grep -q "^saved_entry=.*-$KREL\$" && ok "GRUB default $KREL" || bad "GRUB default: $(echo "$env" | grep saved_entry)"
echo "$env" | grep -q '^next_entry=.' && bad "a GRUB one-time entry is set" || ok "no GRUB one-time entry"
free=$(df -Pm /boot/efi | awk 'NR==2{print $4}'); [ "$free" -ge 40 ] && ok "ESP free $free MB" || bad "ESP free $free MB"
[ ! -e "$UNIT" ] && ok "no old restore unit" || bad "$UNIT already exists"
busy="$(pgrep -fa 'llama-|test-backend|soak|stress|make .*m3gpu|dnf|rpm ' | grep -v pgrep || true)"
[ -z "$busy" ] && ok "no build, benchmark or package job" || { bad "jobs run:"; echo "$busy"; }

# The DTB folder layout make-bootbin.sh expects: <dir>/apple/*.dtb
if [ ! -d "$TDIR/apple" ]; then
	[ "$MODE" = "--dry-run" ] && echo "note: $TDIR has no apple/ subfolder; the real run moves the DTBs into it" \
		|| { mkdir "$TDIR/apple"; mv "$TDIR"/*.dtb "$TDIR/apple/"; chown -R $U: "$TDIR"; ok "moved test DTBs into $TDIR/apple"; }
fi

# Build the candidate exactly as make-bootbin.sh does, and compare it with stageE part by part.
CAND="$(mktemp /tmp/boot.bin.ane.XXXX)"
DSRC="$TDIR/apple"; [ -d "$DSRC" ] || DSRC="$TDIR"
{ cat "$M1N1" "$DSRC"/t6*.dtb "$DSRC"/t81*.dtb; gzip -c /usr/share/uboot/apple_m1/u-boot-nodtb.bin
  grep -E '^(chosen\.[^=]+|display|mitigations)=' /etc/m1n1.conf || true; printf '%s\n' "${OPTS[@]}"; } > "$CAND"
python3 -I - "$ESP/boot.bin.stageE" "$CAND" "$M1N1" <<'EOF' || fail=1
import struct, sys
a, b = (open(p, 'rb').read() for p in sys.argv[1:3])
m = len(open(sys.argv[3], 'rb').read())
def split(d):
    parts, o = [d[:m]], m
    while d[o:o+4] == b'\xd0\x0d\xfe\xed':
        n = struct.unpack('>I', d[o+4:o+8])[0]; parts.append(d[o:o+n]); o += n
    parts.append(d[o:]); return parts
pa, pb = split(a), split(b)
if len(pa) != len(pb):
    print(f"FAIL: part count {len(pa)} vs {len(pb)}"); sys.exit(1)
diff = [i for i in range(len(pa)) if pa[i] != pb[i]]
print(f"compare: {len(pa)-2} DTBs; differing parts: {diff}")
if len(diff) != 1 or diff[0] in (0, len(pa) - 1):
    print("FAIL: more than one DTB, or m1n1/tail differs"); sys.exit(1)
print("ok:   only one DTB differs from stageE (m1n1, U-Boot and options equal)")
EOF

echo "== Result of checks: $([ $fail = 0 ] && echo PASS || echo FAIL)"
if [ "$fail" != 0 ]; then rm -f "$CAND"; echo "STOP: nothing was changed"; exit 1; fi
if [ "$MODE" = "--dry-run" ]; then rm -f "$CAND"; echo "DRY RUN OK: nothing was changed"; exit 0; fi

echo "== Snapshot"
snapper create -d "before ANE stage 2 window" --print-number

echo "== boot.bin.ane"
cp -f "$CAND" "$ESP/boot.bin.ane.new"; sync; mv -f "$ESP/boot.bin.ane.new" "$ESP/boot.bin.ane"; sync; rm -f "$CAND"
ANE_SHA="$(sha "$ESP/boot.bin.ane")"; echo "boot.bin.ane $ANE_SHA"

echo "== One-time restore unit"
cat > "$RESTORE" <<EOF
#!/bin/sh
# Installed by ~/window/ane-boot.sh. Runs once, early in the ANE test boot.
L=/var/log/m3gpu/ane-window.log; mkdir -p /var/log/m3gpu
s=\$(sha256sum $ESP/boot.bin | cut -d' ' -f1)
if [ "\$s" = "$ANE_SHA" ]; then
	cp -f $ESP/boot.bin.stageE $ESP/boot.bin.new && sync && mv -f $ESP/boot.bin.new $ESP/boot.bin && sync
	echo "\$(date '+%F %T') ANE test boot: boot.bin restored to stageE \$(sha256sum $ESP/boot.bin | cut -d' ' -f1)" >> \$L
else
	echo "\$(date '+%F %T') boot.bin was not the ANE file (\$s); left as it is" >> \$L
fi
systemctl disable ane-window-restore.service
rm -f $UNIT $RESTORE
EOF
chmod 755 "$RESTORE"
cat > "$UNIT" <<EOF
[Unit]
Description=One-time restore of boot.bin to stageE after the ANE test boot
DefaultDependencies=no
After=local-fs.target boot-efi.mount
RequiresMountsFor=/boot/efi /var/log
Before=sysinit.target

[Service]
Type=oneshot
ExecStart=$RESTORE

[Install]
WantedBy=sysinit.target
EOF
systemctl daemon-reload
systemctl enable ane-window-restore.service

echo "== Switch"
cp -f "$ESP/boot.bin.ane" "$ESP/boot.bin.new"; sync; mv -f "$ESP/boot.bin.new" "$ESP/boot.bin"; sync
[ "$(sha "$ESP/boot.bin")" = "$ANE_SHA" ] || { echo "FAIL: boot.bin copy hash differs; running --undo"; "$0" --undo; exit 1; }
chown $U: "$LOG"
echo "READY: the next boot uses the ANE test DTB once. The restore unit puts stageE back early in that boot."
echo "Undo before the reboot: sudo $0 --undo"
