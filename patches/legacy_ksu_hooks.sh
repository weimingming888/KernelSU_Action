#!/bin/bash
# Patches author: weishu <twsxtd@gmail.com>
# Shell authon: xiaoleGun <1592501605@qq.com>
#               bdqllW <bdqllT@gmail.com>
# Tested kernel versions: 5.4, 4.19, 4.14, 4.9
# 20240123

patch_files=(
    fs/exec.c
    fs/open.c
    fs/read_write.c
    fs/stat.c
    drivers/input/input.c
)

for i in "${patch_files[@]}"; do

    if grep -q "ksu" "$i"; then
        echo "Warning: $i contains KernelSU"
        continue
    fi

    case $i in

    # fs/ changes
    ## exec.c
    fs/exec.c)
        sed -i '/static int do_execveat_common/i\#ifdef CONFIG_KSU\nextern bool ksu_execveat_hook __read_mostly;\nextern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n			void *envp, int *flags);\nextern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,\n				 void *argv, void *envp, int *flags);\n#endif' fs/exec.c
        if grep -q "return __do_execve_file(fd, filename, argv, envp, flags, NULL);" fs/exec.c; then
            sed -i '/return __do_execve_file(fd, filename, argv, envp, flags, NULL);/i\	#ifdef CONFIG_KSU\n	if (unlikely(ksu_execveat_hook))\n		ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n	else\n		ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);\n	#endif' fs/exec.c
        else
            sed -i '/if (IS_ERR(filename))/i\	#ifdef CONFIG_KSU\n	if (unlikely(ksu_execveat_hook))\n		ksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n	else\n		ksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);\n	#endif' fs/exec.c
        fi
        ;;

    ## open.c
    fs/open.c)
        if grep -q "long do_faccessat(int dfd, const char __user \*filename, int mode)" fs/open.c; then
            sed -i '/long do_faccessat(int dfd, const char __user \*filename, int mode)/i\#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n			 int *flags);\n#endif' fs/open.c
        else
            sed -i '/SYSCALL_DEFINE3(faccessat, int, dfd, const char __user \*, filename, int, mode)/i\#ifdef CONFIG_KSU\nextern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n			 int *flags);\n#endif' fs/open.c
        fi
        sed -i '/if (mode & ~S_IRWXO)/i\	#ifdef CONFIG_KSU\n	ksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n	#endif\n' fs/open.c
        ;;

    ## read_write.c
    fs/read_write.c)
        sed -i '/ssize_t vfs_read(struct file/i\#ifdef CONFIG_KSU\nextern bool ksu_vfs_read_hook __read_mostly;\nextern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,\n		size_t *count_ptr, loff_t **pos);\n#endif' fs/read_write.c
        sed -i '/ssize_t vfs_read(struct file/,/ssize_t ret;/{/ssize_t ret;/a\
        #ifdef CONFIG_KSU\
        if (unlikely(ksu_vfs_read_hook))\
            ksu_handle_vfs_read(&file, &buf, &count, &pos);\
        #endif
        }' fs/read_write.c
        ;;

    ## stat.c
    fs/stat.c)
        if grep -q "int vfs_statx(int dfd, const char __user \*filename, int flags," fs/stat.c; then
            sed -i '/int vfs_statx(int dfd, const char __user \*filename, int flags,/i\#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif' fs/stat.c
            sed -i '/unsigned int lookup_flags = LOOKUP_FOLLOW | LOOKUP_AUTOMOUNT;/a\\n	#ifdef CONFIG_KSU\n	ksu_handle_stat(&dfd, &filename, &flags);\n	#endif' fs/stat.c
        else
            sed -i '/int vfs_fstatat(int dfd, const char __user \*filename, struct kstat \*stat,/i\#ifdef CONFIG_KSU\nextern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n#endif\n' fs/stat.c
            sed -i '/if ((flag & ~(AT_SYMLINK_NOFOLLOW | AT_NO_AUTOMOUNT |/i\	#ifdef CONFIG_KSU\n	ksu_handle_stat(&dfd, &filename, &flag);\n	#endif\n' fs/stat.c
        fi
        ;;

    # drivers/input changes
    ## input.c
    drivers/input/input.c)
        sed -i '/static void input_handle_event/i\#ifdef CONFIG_KSU\nextern bool ksu_input_hook __read_mostly;\nextern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\n#endif\n' drivers/input/input.c
        sed -i '/int disposition = input_get_disposition(dev, type, code, &value);/a\	#ifdef CONFIG_KSU\n	if (unlikely(ksu_input_hook))\n		ksu_handle_input_handle_event(&type, &code, &value);\n	#endif' drivers/input/input.c
        ;;
    esac

done

# ---------------------------------------------------------------------------
# KernelSU-Next (legacy) gates its Kbuild on the literal string
# "ksu_handle_sys_reboot" appearing in kernel/reboot.c. The 0.9.x-era hooks
# above never touched reboot.c, so the build aborts with "No hooks were
# defined". Insert the real supercall before the CAP_SYS_BOOT check (KSU magic
# values intentionally fail that check, so the hook must run first).
# ---------------------------------------------------------------------------
if ! grep -q "ksu_handle_sys_reboot" kernel/reboot.c; then
    python3 -c '
import io
p = "kernel/reboot.c"
s = io.open(p, encoding="utf-8", errors="surrogateescape").read()
a = "\t/* We only trust the superuser with rebooting the system. */\n"
h = "#ifdef CONFIG_KSU\n\textern int ksu_handle_sys_reboot(int magic1, int magic2, unsigned int cmd, void __user **arg);\n\tksu_handle_sys_reboot(magic1, magic2, cmd, &arg);\n#endif\n\n"
if "ksu_handle_sys_reboot" not in s and a in s:
    io.open(p, "w", encoding="utf-8", errors="surrogateescape").write(s.replace(a, h + a, 1))
    print("[+] injected ksu_handle_sys_reboot hook into kernel/reboot.c")
else:
    print("[!] reboot.c: hook already present or anchor not found")
'
fi

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
s = s.replace("+= -no-integrated-as", "+= -integrated-as", 1)
s = s.replace("-std=gnu89 $(HOST_LFS_CFLAGS)", "-std=gnu89 -fcommon $(HOST_LFS_CFLAGS)", 1)
if s != o:
    io.open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
    print("[+] Makefile: -integrated-as + HOSTCFLAGS -fcommon")
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
    s = s.replace("LD\t\t= $(CROSS_COMPILE)ld\n", "LD\t\t= ld.lld\n", 1)
if s != o:
    io.open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
    print("[+] Makefile: LD=ld.lld (vDSO sub-make compatible)")
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
s = s.replace("+= -integrated-as", "+= -integrated-as -fuse-ld=lld", 1)
if s != o:
    io.open(p, "w", encoding="utf-8", errors="surrogateescape").write(s)
    print("[+] Makefile: CLANG_FLAGS -fuse-ld=lld")
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
