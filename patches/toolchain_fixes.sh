#!/bin/bash
# Unconditional 4.14/violet toolchain fixes (no KSU dependency).
# patches.sh runs this from REPO_ROOT, so cd into the kernel tree ourselves.
KERNEL_DIR=${KERNEL_DIR:?KERNEL_DIR must be set}
cd "$KERNEL_DIR"

# --- 4.14 toolchain fixes (this script runs inside KERNEL_DIR) -----------
# (a) Makefile forces -no-integrated-as into *both* KBUILD_CFLAGS and
#     KBUILD_AFLAGS; on a runner whose /usr/bin/as is x86 this breaks vdso
#     with "unrecognized option '-EL'". Use clang's integrated assembler.
# (b) GCC 13 defaults to -fno-common; legacy dtc then fails with multiple
#     definition of `yylloc`. Put -fcommon in HOSTCFLAGS (not
#     HOST_EXTRACFLAGS, whose command-line value would suppress
#     scripts/selinux/genheaders/Makefile's own "+= -I..." and lose
#     classmap.h).
if [ -f Makefile ]; then
python3 -c '
import io
p = "Makefile"
s = io.open(p, encoding="utf-8", errors="surrogateescape").read()
o = s
s = s.replace("-std=gnu89 $(HOST_LFS_CFLAGS)", "-std=gnu89 -fcommon $(HOST_LFS_CFLAGS)", 1)
if s != o:
    io.open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
    print("[+] Makefile: HOSTCFLAGS -fcommon (GNU as kept)")
else:
    print("[!] Makefile: patterns not found (already patched?)")
'
fi

# --- 5. 4.14 vdso: LLVM integrated assembler vs GNU-as named macro args --
# gettimeofday.S defines ".macro clock_gettime_return, shift=0" and calls it
# as "clock_gettime_return, shift=1". GNU as accepts named/default macro
# arguments; LLVM MC does not ("too many positional arguments"). Split into
# two parameterless macros so either assembler accepts it.
if [ -f arch/arm64/kernel/vdso/gettimeofday.S ]; then
python3 -c '
import io
p = "arch/arm64/kernel/vdso/gettimeofday.S"
s = io.open(p, encoding="utf-8", errors="surrogateescape").read()
old = "\t.macro clock_gettime_return, shift=0\n\t.if \\shift == 1\n\tlsr\tx11, x11, x12\n\t.endif\n\tstp\tx10, x11, [x1, #TSPEC_TV_SEC]\n\tmov\tx0, xzr\n\tret\n\t.endm"
new = "\t.macro clock_gettime_return\n\tstp\tx10, x11, [x1, #TSPEC_TV_SEC]\n\tmov\tx0, xzr\n\tret\n\t.endm\n\n\t.macro clock_gettime_return_shift\n\tlsr\tx11, x11, x12\n\tstp\tx10, x11, [x1, #TSPEC_TV_SEC]\n\tmov\tx0, xzr\n\tret\n\t.endm"
if old in s:
    s = s.replace(old, new, 1)
    s = s.replace("\tclock_gettime_return, shift=1", "\tclock_gettime_return_shift")
    io.open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
    print("[+] vdso: split clock_gettime_return macro (LLVM integrated-as compatible)")
else:
    print("[!] vdso: macro pattern not found (already patched?)")
'
fi

# --- 6. linker: make LD=ld.lld visible to *all* sub-makes ------------------
# Passing LD=ld.lld on the make command line only applies to the top-level
# make; vDSO's sub-make still resolves LD to the host x86 ld.bfd and fails
# with "unrecognised emulation mode: aarch64linux". Set it in the Makefile.
if [ -f Makefile ]; then
python3 -c '
import io
p = "Makefile"
s = io.open(p, encoding="utf-8", errors="surrogateescape").read()
o = s
if "LD\t\t= ld.lld" not in s:
    s = s.replace("LD\t\t= ld.lld\n", "LD\t\t= $(CROSS_COMPILE)ld\n", 1)
if s != o:
    io.open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
    print("[+] Makefile: LD restored to GNU ld for vmlinux final link")
else:
    print("[!] Makefile: LD pattern not found / already patched")
'
fi

# --- 7. clang driver must use lld for *every* link ------------------------
# vDSO is linked with $(CC), not $(LD), so LD=ld.lld in Makefile is ignored:
# clang picks the host x86 ld.bfd and fails with "unrecognised emulation
# mode: aarch64linux". Force lld globally via CLANG_FLAGS, explicitly in
# vdso's cmd_vdsold, and expose AOSP clang's ld.lld in PATH as a fallback.
if ! command -v ld.lld >/dev/null 2>&1; then
    for c in "${CLANG_PATH:-}/ld.lld" "${WORKSPACE:-}/clang/bin/ld.lld"; do
        if [ -x "$c" ]; then
            ln -sf "$c" /usr/local/bin/ld.lld 2>/dev/null \
                || sudo ln -sf "$c" /usr/local/bin/ld.lld 2>/dev/null || true
            break
        fi
    done
fi
if [ -f Makefile ]; then
python3 -c '
import io
p = "Makefile"
s = io.open(p, encoding="utf-8", errors="surrogateescape").read()
o = s
s = s.replace("+= -no-integrated-as -fuse-ld=lld", "+= -no-integrated-as", 1)
s = s.replace("KBUILD_CFLAGS\t+= $(CLANG_FLAGS)\n", "KBUILD_CFLAGS\t+= $(CLANG_FLAGS) -integrated-as\n", 1)
if s != o:
    io.open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
    print("[+] Makefile: CFLAGS=integrated-as, AFLAGS=GNU as")
else:
    print("[!] Makefile: CLANG_FLAGS already patched")
'
fi
python3 -c '
import io, glob
n = 0
for p in glob.glob("arch/arm64/kernel/vdso*/Makefile"):
    s = io.open(p, encoding="utf-8", errors="surrogateescape").read()
    if "-fuse-ld=lld" in s:
        continue
    o = s
    s = s.replace("cmd_vdsold = $(CC) ", "cmd_vdsold = $(CC) -fuse-ld=lld ", 1)
    if s != o:
        io.open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
        n += 1
print("[+] vdso cmd_vdsold patched:", n)
'

# --- 8. expose AOSP binutils under the GNU triple clang expects ----------
# CLANG_TRIPLE=aarch64-linux-gnu- is mandatory (AOSP clang errors out on an
# Android --target), but -no-integrated-as makes clang look for
# aarch64-linux-gnu-as while the AOSP GCC 4.9 package only ships
# aarch64-linux-android-*. Provide aliases so external assembly works.
for d in "${WORKSPACE:-}/gcc-64/bin"; do
    [ -d "$d" ] || continue
    for t in "$d"/aarch64-linux-android-*; do
        [ -x "$t" ] || continue
        n=$(basename "$t")
        suffix="${n#aarch64-linux-android-}"
        # clang --prefix=$(GCC_TOOLCHAIN_DIR) resolves the external assembler
        # *inside this directory*, not via PATH, so the alias must live here.
        ln -sf "$n" "$d/aarch64-linux-gnu-$suffix" 2>/dev/null || true
        dst="/usr/local/bin/aarch64-linux-gnu-$suffix"
        ln -sf "$t" "$dst" 2>/dev/null || sudo ln -sf "$t" "$dst" 2>/dev/null || true
    done
    echo "[+] binutils aliases for aarch64-linux-gnu-* created"
    break
done
