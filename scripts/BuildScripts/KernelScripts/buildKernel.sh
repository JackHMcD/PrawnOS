#!/bin/bash

set -x
set -e

# build Linux-libre, with ath9k_htc firmware and initramfs built in


# This file is part of PrawnOS (https://www.prawnos.com)
# Copyright (c) 2018-2020 Hal Emmerich <hal@halemmerich.com>

# PrawnOS is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2
# as published by the Free Software Foundation.

# PrawnOS is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

# You should have received a copy of the GNU General Public License
# along with PrawnOS.  If not, see <https://www.gnu.org/licenses/>.


PRAWNOS_ROOT=$(git rev-parse --show-toplevel)
source ${PRAWNOS_ROOT}/scripts/BuildScripts/BuildCommon.sh

if [ -z "$1" ]; then
    echo "No kernel version supplied"
    exit 1
elif [ -z "$2" ]; then
    echo "No resources directory"
    exit 1
elif [ -z "$3" ]; then
    echo "No build directory supplied"
    exit 1
elif [ -z "$4" ]; then
    echo "No PrawnOS initramfs supplied"
    exit 1
elif [ -z "$5" ]; then
    echo "No PrawnOS target arch supplied"
    exit 1
elif [ -z "$6" ]; then
    echo "No PrawnOS kernel config supplied"
    exit 1
fi

KVER=$1
RESOURCES=$2
BUILD_DIR=$3
INITRAMFS=$4
TARGET=$5
KERNEL_CONFIG=$6

#this is the same as the kernel partition size
MAX_KERNEL_SIZE=$(expr 65536 \* 512)

cd $BUILD_DIR

### Uncomment to have the build clean the kernel every time
# make mrproper

#this arch nonsense is obnoxious.
# armhf is just "arm" to the kernel and vbutil,
# arm64 is what the kernel uses, but aarch64 is what vbutil uses
if [ "$TARGET" == "$PRAWNOS_ARMHF" ]; then
    CROSS_COMPILER=arm-none-eabi-
    # kernel doesn't differentiate between arm and armhf
    KERNEL_ARCH=arm
    VBUTIL_ARCH=$KERNEL_ARCH
    IMAGE=zImage
    BOOTLOADER=coreboot
elif [ "$TARGET" == "$PRAWNOS_ARM64" ]; then
    CROSS_COMPILER=aarch64-linux-gnu-
    KERNEL_ARCH=$ARCH_ARM64
    VBUTIL_ARCH=aarch64
    IMAGE=Image
    BOOTLOADER=coreboot
elif [ "$TARGET" == "${PRAWNOS_ARM64_RK3588_SERVER}" ]; then
    CROSS_COMPILER=aarch64-linux-gnu-
    KERNEL_ARCH=$ARCH_ARM64
    IMAGE=Image
    BOOTLOADER=uboot
elif [ "$TARGET" == "${PRAWNOS_ARM64_RK3588}" ]; then
    CROSS_COMPILER=aarch64-linux-gnu-
    KERNEL_ARCH=$ARCH_ARM64
    IMAGE=Image
    BOOTLOADER=uboot
else
    echo "Cannot build kernel: no valid target arch specified"
    exit 1
fi

#copy in the config
cp "$KERNEL_CONFIG" .config

if [ "$BOOTLOADER" == "coreboot" ]; then

    #copy in the resources, initramfs
    cp $INITRAMFS .
    cp $RESOURCES/kernel.its .
    
# wifi firmware blob:
# FIXME: brcm is only armhf, arm64 is unsupported for now:
if [ "$TARGET" == "$ARCH_ARMHF" ]; then
    mkdir -p brcm
    cp $RESOURCES/brcmfmac4354-sdio.bin brcm/
    cp $RESOURCES/brcmfmac4354-sdio.txt brcm/
    cp $RESOURCES/brcmfmac4354-sdio.txt 'brcm/brcmfmac4354-sdio.google,veyron-minnie-rev4.txt'
else
    echo "FIXME: no extra firmware (e.g., wifi) known for this target!"
    sleep 10
fi

    make -j $(($(nproc) +1))  CROSS_COMPILE=$CROSS_COMPILER ARCH=$KERNEL_ARCH $IMAGE
    make -j $(($(nproc) +1))  CROSS_COMPILE=$CROSS_COMPILER ARCH=$KERNEL_ARCH DTC_FLAGS="-@" dtbs
    mkimage -D "-I dts -O dtb -p 2048" -f kernel.its vmlinux.uimg
    dd if=/dev/zero of=bootloader.bin bs=512 count=1
    vbutil_kernel --pack vmlinux.kpart \
                  --version 1 \
                  --vmlinuz vmlinux.uimg \
                  --arch $VBUTIL_ARCH \
                  --keyblock /usr/share/vboot/devkeys/kernel.keyblock \
                  --signprivate /usr/share/vboot/devkeys/kernel_data_key.vbprivk \
                  --config $RESOURCES/cmdline \
                  --bootloader bootloader.bin

    RESULT=$?
    if [ ! $RESULT -eq 0 ]; then
        rm -f vmlinux.kpart
    fi

    KERNEL_SIZE=$(stat -c %s "vmlinux.kpart")
    if [ "$KERNEL_SIZE" -gt "$MAX_KERNEL_SIZE" ]; then
        mv vmlinux.kpart oversized_vmlinux.kpart
        echo "kernel larger than max kernel size!"
        exit 1
    fi

elif [ "$BOOTLOADER" == "uboot" ]; then
    make -j $(($(nproc) +1))  CROSS_COMPILE=$CROSS_COMPILER ARCH=$KERNEL_ARCH $IMAGE
    make -j $(($(nproc) +1))  CROSS_COMPILE=$CROSS_COMPILER ARCH=$KERNEL_ARCH rockchip/rk3588-firefly-itx-3588j.dtb
    make -j $(($(nproc) +1))  CROSS_COMPILE=$CROSS_COMPILER ARCH=$KERNEL_ARCH rockchip/rk3588-firefly-itx-3588j-dual-mipi101-M101014-BE45-A1.dtb

    # vmlinux.kpart is the build complete flag to stay consistent with the other platforms
    # though it is unused for uboot
    # dtb is /arch/arm64/boot/dts/rockchip/rk3588-firefly-itx-3588j.dtb
    # Actual kernel image is arch/arm64/boot/Image
    touch vmlinux.kpart
else
    echo "no valid target bootloader"
    exit 1
fi


