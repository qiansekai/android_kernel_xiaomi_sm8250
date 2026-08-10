#!/bin/bash

# Some logics of this script are copied from [scripts/build_kernel]. Thanks to UtsavBalar1231.

# Ensure the script exits on error
set -e

TOOLCHAIN_PATH=$HOME/zyc-clang/bin
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
TARGET_DEVICE=$1

if [ -z "$1" ]; then
    echo "Error: No argument provided, please specific a target device." 
    echo "If you need KernelSU, please add [ksu] as the second arg."
    echo "Examples:"
    echo "Build for lmi(K30 Pro/POCO F2 Pro) without KernelSU:"
    echo "    bash build.sh lmi"
    echo "Build for umi(Mi10) with KernelSU:"
    echo "    bash build.sh umi ksu"
    exit 1
fi



if [ ! -d $TOOLCHAIN_PATH ]; then
    echo "TOOLCHAIN_PATH [$TOOLCHAIN_PATH] does not exist."
    echo "Please ensure the toolchain is there, or change TOOLCHAIN_PATH in the script to your toolchain path."
    exit 1
fi

echo "TOOLCHAIN_PATH: [$TOOLCHAIN_PATH]"
export PATH="$TOOLCHAIN_PATH:$PATH"

if ! command -v aarch64-linux-gnu-ld >/dev/null 2>&1; then
    echo "[aarch64-linux-gnu-ld] does not exist, please check your environment."
    exit 1
fi

if ! command -v arm-linux-gnueabi-ld >/dev/null 2>&1; then
    echo "[arm-linux-gnueabi-ld] does not exist, please check your environment."
    exit 1
fi

if ! command -v clang >/dev/null 2>&1; then
    echo "[clang] does not exist, please check your environment."
    exit 1
fi


# Enable ccache for speed up compiling 
export CCACHE_DIR="$HOME/.cache/ccache_mikernel" 
export CC="clang"
export CXX="clang++"
export PATH="/usr/lib/ccache:$PATH"
export CCACHE_COMPILERCHECK=content
export CCACHE_SLOPPINESS=time_macros,include_file_mtime,include_file_ctime
echo "CCACHE_DIR: [$CCACHE_DIR]"


MAKE_ARGS="ARCH=arm64 \
           SUBARCH=arm64 \
           O=out \
           CC=clang \
           HOSTCC=clang \
           CLANG_TRIPLE=aarch64-linux-gnu- \
           CROSS_COMPILE=aarch64-linux-gnu- \
           CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
           CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
           LD=ld.lld \
           AR=llvm-ar \
           NM=llvm-nm \
           OBJCOPY=llvm-objcopy \
           OBJDUMP=llvm-objdump \
           STRIP=llvm-strip \
           KSU_MANAGER_PACKAGE=isekai.joucho"


if [ "$1" == "j1" ]; then
    make $MAKE_ARGS -j1
    exit
fi

if [ "$1" == "continue" ]; then
    make $MAKE_ARGS -j$(nproc)
    exit
fi

if [ ! -f "arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]; then
    echo "No target device [${TARGET_DEVICE}] found."
    echo "Avaliable defconfigs, please choose one target from below down:"
    ls arch/arm64/configs/*_defconfig
    exit 1
fi


# Check clang is existing.
echo "[clang --version]:"
clang --version




# ---------- CN mirror / local cache (daily builds need no proxy) ----------
# GITHUB_PROXY default: ghfast.top prefix for github.com & raw.githubusercontent.com
# FORCE_NET=1  always re-fetch KernelSU / Baseband-guard / AnyKernel3
# AK3_CACHE_DIR  persistent AnyKernel3 cache (default: $HOME/android_kernel_xiaomi_sm8250/.cache/anykernel3)
if [ -z "${GITHUB_PROXY+x}" ]; then
    GITHUB_PROXY="https://ghfast.top/"
fi
FORCE_NET="${FORCE_NET:-0}"
AK3_CACHE_DIR="${AK3_CACHE_DIR:-$HOME/android_kernel_xiaomi_sm8250/.cache/anykernel3}"

github_url() {
    local u="$1"
    case "$u" in
        https://github.com/*|https://raw.githubusercontent.com/*)
            printf '%s%s\n' "$GITHUB_PROXY" "$u"
            ;;
        *)
            printf '%s\n' "$u"
            ;;
    esac
}

# Session-only git insteadOf (does NOT touch ~/.gitconfig)
_setup_git_mirror() {
    if [ -n "${_GIT_MIRROR_CFG:-}" ] && [ -f "${_GIT_MIRROR_CFG}" ]; then
        return 0
    fi
    _GIT_MIRROR_CFG="$(mktemp /tmp/gitmirror.XXXXXX)"
    git config -f "$_GIT_MIRROR_CFG" url."${GITHUB_PROXY}https://github.com/".insteadOf "https://github.com/"
    git config -f "$_GIT_MIRROR_CFG" url."${GITHUB_PROXY}https://raw.githubusercontent.com/".insteadOf "https://raw.githubusercontent.com/"
    export GIT_CONFIG_GLOBAL="$_GIT_MIRROR_CFG"
    echo "[net] git mirror config: $GITHUB_PROXY (session only)"
}

curl_gh() {
    local url="$1"; shift || true
    local mirrored
    mirrored="$(github_url "$url")"
    if [ "$mirrored" != "$url" ]; then
        echo "[net] curl $mirrored"
        if curl -fLSs --connect-timeout 20 --max-time 300 "$@" "$mirrored"; then
            return 0
        fi
        echo "[net] mirror failed, try direct: $url" >&2
    fi
    curl -fLSs --connect-timeout 20 --max-time 300 "$@" "$url"
}

git_clone_gh() {
    local url="$1"; shift
    _setup_git_mirror
    local mirrored
    mirrored="$(github_url "$url")"
    echo "[net] git clone $mirrored $*"
    if git clone "$mirrored" "$@"; then
        return 0
    fi
    echo "[net] mirror clone failed, try direct: $url" >&2
    git clone "$url" "$@"
}

# --------------------------------------------------------------------------

KSU_ZIP_STR=NoKernelSU
if [ "$2" == "ksu" ]; then
    KSU_ENABLE=1
    KSU_ZIP_STR=ReSukiSU-SuSFS
else
    KSU_ENABLE=0
fi


echo "TARGET_DEVICE: $TARGET_DEVICE"

if [ $KSU_ENABLE -eq 1 ]; then
    echo "KSU is enabled"
    if [ "$FORCE_NET" = "1" ] || [ ! -d KernelSU/kernel ]; then
        echo "[net] KernelSU setup via bundled script (pinned 537a2005)"
        bash scripts/ksu_setup.sh 537a2005
    else
        echo "[cache] reuse existing KernelSU/ (FORCE_NET=1 to refresh)"
    fi
    # Patch: remove v2 APK signature check, verify by package name only
    sed -i 's/    return check_v2_signature(path, signature_index);$/    return true;/' KernelSU/kernel/manager/apk_sign.c
    echo "[+] Manager signature check removed."
    # Patch: add default dontaudit rules to suppress AVC log leaks
    sed -i "s|    // Allow all binder transactions|    // Default dontaudit rules to suppress common AVC log leaks\n    ksu_dontaudit(db, \"untrusted_app\", \"lsposed_file\", \"file\", ALL);\n    ksu_dontaudit(db, \"untrusted_app\", \"magisk_file\", \"file\", ALL);\n    ksu_dontaudit(db, \"untrusted_app\", \"su_file\", \"file\", ALL);\n\n    // Allow all binder transactions|" KernelSU/kernel/selinux/rules.c
    echo "[+] Default dontaudit rules added."
    # Patch: cache lsposed_file SID for AVC audit suppression
    python3 scripts/patch_selinux_sid.py
    echo "[+] lsposed_file SID cached for AVC suppression."
else
    echo "KSU is disabled"
fi

echo "Integrating Baseband-guard..."
if [ "$FORCE_NET" = "1" ] || [ ! -d drivers/baseband_guard ]; then
    echo "[net] Baseband-guard setup via bundled script (pinned cef0daa)"
    _setup_git_mirror
    bash scripts/bbg_setup.sh cef0daa
else
    echo "[cache] reuse existing drivers/baseband_guard/ (FORCE_NET=1 to refresh)"
fi
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig

echo "Cleaning..."

rm -rf out/

# AnyKernel3: persistent cache → copy into anykernel/ (no daily GitHub clone)
need_ak3=0
if [ "$FORCE_NET" = "1" ]; then
    need_ak3=1
elif [ ! -f "$AK3_CACHE_DIR/anykernel.sh" ]; then
    need_ak3=1
fi
if [ "$need_ak3" = "1" ]; then
    echo "[net] clone AnyKernel3 into $AK3_CACHE_DIR"
    rm -rf "$AK3_CACHE_DIR"
    mkdir -p "$(dirname "$AK3_CACHE_DIR")"
    git_clone_gh "https://github.com/AstideLabs/AnyKernel3" -b master --single-branch --depth=1 "$AK3_CACHE_DIR"
else
    echo "[cache] reuse AnyKernel3 at $AK3_CACHE_DIR"
fi
rm -rf anykernel
cp -a "$AK3_CACHE_DIR" anykernel
rm -rf anykernel/.git

# SKIP_AOSP # ------------- Building for AOSP -------------
# SKIP_AOSP 
# SKIP_AOSP echo "Building for AOSP......"
# SKIP_AOSP make $MAKE_ARGS ${TARGET_DEVICE}_defconfig
# SKIP_AOSP 
# SKIP_AOSP if [ $KSU_ENABLE -eq 1 ]; then
# SKIP_AOSP     scripts/config --file out/.config \
# SKIP_AOSP     -e KSU \
# SKIP_AOSP     -e THREAD_INFO_IN_TASK \
# SKIP_AOSP     -e KSU_SUSFS \
# SKIP_AOSP     -e KSU_SUSFS_SUS_PATH \
# SKIP_AOSP     -e KSU_SUSFS_SUS_MOUNT \
# SKIP_AOSP     -e KSU_SUSFS_SUS_KSTAT \
# SKIP_AOSP     -e KSU_SUSFS_SPOOF_UNAME \
# SKIP_AOSP     -e KSU_SUSFS_ENABLE_LOG \
# SKIP_AOSP     -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
# SKIP_AOSP     -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
# SKIP_AOSP     -e KSU_SUSFS_OPEN_REDIRECT \
# SKIP_AOSP     -e KSU_SUSFS_SUS_MAP \
# SKIP_AOSP     -e KSU_MULTI_MANAGER_SUPPORT \
# SKIP_AOSP     -e KPM
# SKIP_AOSP else
# SKIP_AOSP     scripts/config --file out/.config -d KSU
# SKIP_AOSP fi
# SKIP_AOSP 
# SKIP_AOSP scripts/config --file out/.config \
# SKIP_AOSP     -e BBG
# SKIP_AOSP 
# SKIP_AOSP scripts/config --file out/.config \
# SKIP_AOSP     -e XIAOMI_MIUI
# SKIP_AOSP 
# SKIP_AOSP yes "" | make $MAKE_ARGS -j$(nproc)
# SKIP_AOSP 
# SKIP_AOSP if [ -f "out/arch/arm64/boot/Image" ]; then
# SKIP_AOSP     echo "The file [out/arch/arm64/boot/Image] exists. AOSP Build successfully."
# SKIP_AOSP else
# SKIP_AOSP     echo "The file [out/arch/arm64/boot/Image] does not exist. Seems AOSP build failed."
# SKIP_AOSP     exit 1
# SKIP_AOSP fi
# SKIP_AOSP 
# SKIP_AOSP echo "Generating [out/arch/arm64/boot/dtb]......"
# SKIP_AOSP find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb
# SKIP_AOSP 
# SKIP_AOSP rm -rf anykernel/kernels/
# SKIP_AOSP 
# SKIP_AOSP mkdir -p anykernel/kernels/aosp/
# SKIP_AOSP 
# SKIP_AOSP # Patch for SukiSU KPM support.
# SKIP_AOSP if [ $KSU_ENABLE -eq 1 ]; then
# SKIP_AOSP     cd out/arch/arm64/boot/
# SKIP_AOSP     if [ ! -f patch_linux ]; then
# SKIP_AOSP         echo "Downloading patch_linux..."
# SKIP_AOSP         curl -LSsO --connect-timeout 300 "https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.13.0/patch_linux"
# SKIP_AOSP     else
# SKIP_AOSP         echo "patch_linux already exists, skip download"
# SKIP_AOSP     fi
# SKIP_AOSP     chmod +x patch_linux
# SKIP_AOSP     ./patch_linux
# SKIP_AOSP     rm Image
# SKIP_AOSP     mv oImage Image
# SKIP_AOSP     python3 $HOME/android_kernel_xiaomi_sm8250/scripts/fix_banner.py Image
# SKIP_AOSP     echo "[+] Compiler banner replaced."
# SKIP_AOSP     cd -
# SKIP_AOSP fi
# SKIP_AOSP 
# SKIP_AOSP cp out/arch/arm64/boot/Image anykernel/kernels/aosp/
# SKIP_AOSP cp out/arch/arm64/boot/dtb anykernel/kernels/aosp/
# SKIP_AOSP cp out/arch/arm64/boot/dtbo.img anykernel/kernels/aosp/
# SKIP_AOSP 
# SKIP_AOSP cd anykernel
# SKIP_AOSP 
# SKIP_AOSP ZIP_FILENAME=APTKernel_AOSP_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +%Y%m%d_%H%M%S)_anykernel3_${GIT_COMMIT_ID}.zip
# SKIP_AOSP 
# SKIP_AOSP zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip
# SKIP_AOSP 
# SKIP_AOSP mv $ZIP_FILENAME ../
# SKIP_AOSP 
# SKIP_AOSP cd ..
# SKIP_AOSP 
# SKIP_AOSP 
# SKIP_AOSP echo "Build for AOSP finished."
# SKIP_AOSP 
# SKIP_AOSP # ------------- End of Building for AOSP -------------
# SKIP_AOSP #  If you don't need AOSP you can comment out the above block [Building for AOSP]


# ------------- Building for MIUI -------------


echo "Clearning [out/] and build for MIUI....."
rm -rf out/

dts_source=arch/arm64/boot/dts/vendor/qcom

# Backup dts
cp -a ${dts_source} .dts.bak

# Correct panel dimensions on MIUI builds
sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j1s*
sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j2*
sed -i 's/<155>/<1544>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
sed -i 's/<155>/<1545>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j1s*
sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j2*

# Enable back mi smartfps while disabling qsync min refresh-rate
sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${dts_source}/dsi-panel*

# Enable back refresh rates supported on MIUI
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi
sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi


# Enable back brightness control from dtsi
sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi


make $MAKE_ARGS ${TARGET_DEVICE}_defconfig

if [ $KSU_ENABLE -eq 1 ]; then
    scripts/config --file out/.config \
    -e KSU \
    -e THREAD_INFO_IN_TASK \
    -e KSU_SUSFS \
    -e KSU_SUSFS_SUS_PATH \
    -e KSU_SUSFS_SUS_MOUNT \
    -e KSU_SUSFS_SUS_KSTAT \
    -e KSU_SUSFS_SPOOF_UNAME \
    -e KSU_SUSFS_ENABLE_LOG \
    -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    -e KSU_SUSFS_OPEN_REDIRECT \
    -e KSU_SUSFS_SUS_MAP \
    -e KSU_MULTI_MANAGER_SUPPORT \
    # Patch: cache lsposed_file SID for AVC audit suppression
    python3 scripts/patch_selinux_sid.py
    echo "[+] lsposed_file SID cached for AVC suppression."
else
    scripts/config --file out/.config -d KSU
fi

scripts/config --file out/.config \
    -e BBG

scripts/config --file out/.config \
    --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
    -e PERF_CRITICAL_RT_TASK	\
    -e SF_BINDER		\
    -e OVERLAY_FS		\
    -e MIGT \
    -e MIGT_ENERGY_MODEL \
    -e MIHW \
    -e PACKAGE_RUNTIME_INFO \
    -e BINDER_OPT \
    -e KPERFEVENTS \
    -e MILLET \
    -e PERF_HUMANTASK \
    -d LTO_CLANG \
    -e LTO_NONE \
    -e SF_BINDER \
    -e XIAOMI_MIUI \
    -d MI_MEMORY_SYSFS \
    -e TASK_DELAY_ACCT \
    -e MIUI_ZRAM_MEMORY_TRACKING \
    -e MI_FRAGMENTION \
    -e PERF_HELPER \
    -e BOOTUP_RECLAIM \
    -e MI_RECLAIM \
    -e RTMM \
    -d REKERNEL \
    -d REKERNEL_NETWORK

yes "" | make $MAKE_ARGS -j$(nproc)

if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "The file [out/arch/arm64/boot/Image] exists. MIUI Build successfully."
    # Patch: cache lsposed_file SID for AVC audit suppression
    python3 scripts/patch_selinux_sid.py
    echo "[+] lsposed_file SID cached for AVC suppression."
else
    echo "The file [out/arch/arm64/boot/Image] does not exist. Seems MIUI build failed."
    exit 1
fi

echo "Generating [out/arch/arm64/boot/dtb]......"
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb


# Restore modified dts
rm -rf ${dts_source}
mv .dts.bak ${dts_source}

rm -rf anykernel/kernels/
mkdir -p anykernel/kernels/miui/

# KPM removed upstream (ReSukiSU 774defdfc+); skip patch_linux.
# Still rewrite compiler banner strings to stock MIUI values.
if [ $KSU_ENABLE -eq 1 ]; then
    cd out/arch/arm64/boot/
    python3 $HOME/android_kernel_xiaomi_sm8250/scripts/fix_banner.py Image
    echo "[+] Compiler banner replaced (no KPM)."
    cd -
fi

cp out/arch/arm64/boot/Image anykernel/kernels/miui/
cp out/arch/arm64/boot/dtb anykernel/kernels/miui/
cp out/arch/arm64/boot/dtbo.img anykernel/kernels/miui/

echo "Build for MIUI finished."

# ------------- End of Building for MIUI -------------
#  If you don't need MIUI you can comment out the above block [Building for MIUI]


cd anykernel 

ZIP_FILENAME=APTKernel_MIUI_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip

zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip

mv $ZIP_FILENAME ../

cd ..

echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
