#!/usr/bin/env python3
"""Build the ANE stage 2 test DTB from the INSTALLED t6030-j516s.dtb.

usage: make-ane-test-dtb.py <installed.dtb> <out.dtb> [dtc]

The installed DTB differs from the live kernel source, so this script
does not build from source. It decompiles the installed DTB, adds the
three ANE DARTs
(disabled) and the ANE node (okay) under /soc, and compiles the result.
The only PMGR change is a phandle on the existing ane_sys node.
It then decompiles the input and the output and fails if any line was
removed. The values are the same as in dts/t6030-ane.dtsi.
"""
import difflib
import re
import subprocess
import sys

PMGR = "power-management@350700000"
ANE_SYS = "power-controller@498"
AIC = "interrupt-controller@351000000"


def dtc_run(dtc, args, inp=None):
    r = subprocess.run([dtc, "-q"] + args, input=inp, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit(f"dtc {' '.join(args)} failed:\n{r.stderr}")
    return r.stdout


def node_span(txt, name):
    """Return (start, end) of the node block whose name is `name`."""
    m = re.search(r"^(\t+)(?:[\w-]+: )?" + re.escape(name) + r" \{\n", txt, re.M)
    if not m:
        raise SystemExit("node not found: " + name)
    ind = m.group(1)
    close = "\n" + ind + "};\n"
    return m.start(), txt.index(close, m.end()) + len(close), ind


def phandle_of(txt, name):
    s, e, _ = node_span(txt, name)
    m = re.search(r"^\s*phandle = <(0x[0-9a-f]+)>;", txt[s:e], re.M)
    return m.group(1) if m else None


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    src, out = sys.argv[1], sys.argv[2]
    dtc = sys.argv[3] if len(sys.argv) > 3 else "dtc"

    base = dtc_run(dtc, ["-I", "dtb", "-O", "dts", src])
    for addr in ("@308000000", "@309800000", "@309810000", "@309820000"):
        if addr + " {" in base:
            raise SystemExit("node already present: " + addr)
    s, e, _ = node_span(base, PMGR)
    if ANE_SYS + " {" not in base[s:e]:
        raise SystemExit("ane_sys is not under " + PMGR)

    txt = base
    nxt = max(int(x, 16) for x in re.findall(r"phandle = <(0x[0-9a-f]+)>;", txt)) + 1
    ph = {}
    for key in ("ane_sys", "dart0", "dart1", "dart2"):
        ph[key] = hex(nxt)
        nxt += 1

    aic = phandle_of(txt, AIC)
    if not aic:
        raise SystemExit("AIC has no phandle")

    # ps_ane_sys has no consumer in the installed tree, so dtc gave it no phandle.
    old = phandle_of(txt, ANE_SYS)
    if old:
        ph["ane_sys"] = old
    else:
        s, e, ind = node_span(txt, ANE_SYS)
        hdr = txt.index("{\n", s) + 2
        txt = txt[:hdr] + f"{ind}\tphandle = <{ph['ane_sys']}>;\n" + txt[hdr:]

    def dart(n, addr):
        return (
            f"\t\tiommu@3{addr:08x} {{\n"
            f'\t\t\tcompatible = "apple,t6030-dart", "apple,t8110-dart";\n'
            f"\t\t\treg = <0x03 {addr:#x} 0x00 0x4000>;\n"
            f"\t\t\t#iommu-cells = <0x01>;\n"
            f"\t\t\tinterrupt-parent = <{aic}>;\n"
            f"\t\t\tinterrupts = <0x00 0x241 0x04>;\n"
            f"\t\t\tpower-domains = <{ph['ane_sys']}>;\n"
            f'\t\t\tstatus = "disabled";\n'
            f"\t\t\tphandle = <{ph['dart' + str(n)]}>;\n"
            f"\t\t}};\n\n"
        )

    soc_nodes = (
        dart(0, 0x09800000)
        + dart(1, 0x09810000)
        + dart(2, 0x09820000)
        + "\t\tane@308000000 {\n"
        '\t\t\tcompatible = "apple,t6030-ane";\n'
        "\t\t\treg = <0x03 0x8000000 0x00 0x2000000>;\n"
        '\t\t\treg-names = "engine";\n'
        f"\t\t\tinterrupt-parent = <{aic}>;\n"
        "\t\t\tinterrupts = <0x00 0x240 0x04>;\n"
        '\t\t\tinterrupt-names = "ane";\n'
        f"\t\t\tpower-domains = <{ph['ane_sys']}>;\n"
        '\t\t\tstatus = "okay";\n'
        "\t\t};\n"
    )
    m = re.search(r"^\tsoc \{\n", txt, re.M)
    end = txt.index("\n\t};\n", m.end())
    txt = txt[: end + 1] + "\n" + soc_nodes + txt[end + 1 :]

    open(out + ".dts", "w").write(txt)
    dtc_run(dtc, ["-I", "dts", "-O", "dtb", "-o", out, out + ".dts"])

    after = dtc_run(dtc, ["-I", "dtb", "-O", "dts", out])
    diff = list(difflib.unified_diff(base.splitlines(), after.splitlines(), lineterm="", n=0))
    added = [l for l in diff if l.startswith("+") and not l.startswith("+++")]
    removed = [l for l in diff if l.startswith("-") and not l.startswith("---")]
    open(out + ".diff", "w").write("\n".join(diff) + "\n")
    print(f"added {len(added)} lines, removed {len(removed)} lines; diff in {out}.diff")
    if removed:
        raise SystemExit("FAIL: lines were removed")


if __name__ == "__main__":
    main()
