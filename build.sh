#!/bin/bash
# Local ZMK build script using podman
# Usage: ./build.sh [left|right|both|update|flash-left|flash-right|flash]

set -e
cd "$(dirname "$0")"

BUILD_DIR="$(pwd)/build"
CONFIG_DIR="$(pwd)/config"
BOARD="nice_nano/nrf52840/zmk"
ZMK_CONTAINER="docker.io/zmkfirmware/zmk-dev-arm:stable"

init_workspace() {
    mkdir -p "${BUILD_DIR}"
    if [ ! -d "${BUILD_DIR}/.west" ]; then
        echo "Initializing west workspace (first run, this may take a while)..."
        podman run --rm \
            -v "${BUILD_DIR}:/workspace:Z" \
            -w /workspace \
            "${ZMK_CONTAINER}" \
            bash -c "west init -m https://github.com/zmkfirmware/zmk.git --mr main --mf app/west.yml && west update"
        # west names the manifest dir zmk.git from the URL; rename to zmk
        if [ -d "${BUILD_DIR}/zmk.git" ]; then
            mv "${BUILD_DIR}/zmk.git" "${BUILD_DIR}/zmk"
            sed -i 's/zmk\.git/zmk/' "${BUILD_DIR}/.west/config"
        fi
    fi
}

build_side() {
    local side=$1
    local shield="corne_${side} nice_view_adapter nice_view"

    init_workspace

    echo "Building ${side}..."
    podman run --rm \
        -v "${BUILD_DIR}:/workspace:Z" \
        -v "${CONFIG_DIR}:/config:ro,Z" \
        -w /workspace \
        "${ZMK_CONTAINER}" \
        bash -c "west zephyr-export 2>/dev/null; west build -s zmk/app -b ${BOARD} -d build/${side} -- -DSHIELD=\"${shield}\" -DZMK_CONFIG=/config"

    cp "${BUILD_DIR}/build/${side}/zephyr/zmk.uf2" "./corne_${side}.uf2"
    echo "Built: corne_${side}.uf2"
}

find_bootloader() {
    # Check common mount points for nice_nano bootloader
    for path in /media/$USER/NICENANO /run/media/$USER/NICENANO /mnt/NICENANO; do
        if [ -d "$path" ] && mountpoint -q "$path" 2>/dev/null; then
            echo "$path"
            return 0
        fi
    done

    # Check for unmounted NICENANO device and mount it
    local device=$(lsblk -o NAME,LABEL -rn 2>/dev/null | grep NICENANO | awk '{print "/dev/"$1}')
    if [ -n "$device" ]; then
        local mount_output=$(udisksctl mount -b "$device" 2>&1)
        if echo "$mount_output" | grep -q "Mounted"; then
            # Extract mount path from output like "Mounted /dev/sda at /media/user/NICENANO"
            echo "$mount_output" | sed 's/.*at //'
            return 0
        fi
    fi

    return 1
}

update_workspace() {
    if [ ! -d "${BUILD_DIR}/.west" ]; then
        echo "Workspace not initialized. Run build first."
        exit 1
    fi

    echo "Updating ZMK and dependencies..."
    podman run --rm \
        -v "${BUILD_DIR}:/workspace:Z" \
        -w /workspace \
        "${ZMK_CONTAINER}" \
        bash -c "git -C zmk pull origin main && west update"

    echo "Update complete. Rebuild with: $0 both"
}

flash_side() {
    local side=$1
    local uf2="./corne_${side}.uf2"

    if [ ! -f "$uf2" ]; then
        echo "Error: $uf2 not found. Build first with: $0 $side"
        exit 1
    fi

    echo "Put ${side} half in bootloader mode (double-tap reset)..."
    echo "Waiting for NICENANO drive to appear..."

    # Wait up to 30 seconds for bootloader
    for i in {1..30}; do
        if bootloader=$(find_bootloader); then
            echo "Found bootloader at: $bootloader"
            echo "Flashing ${side}..."
            cp "$uf2" "$bootloader/"
            sync
            echo "Flashed: corne_${side}.uf2"
            echo "Keyboard will reboot automatically."
            return 0
        fi
        sleep 1
        printf "."
    done

    echo ""
    echo "Timeout: Bootloader drive not found."
    echo "Make sure to double-tap reset on the ${side} half."
    exit 1
}

case "${1:-both}" in
    left)        build_side left ;;
    right)       build_side right ;;
    both)        build_side left; build_side right ;;
    update)      update_workspace ;;
    flash-left)  flash_side left ;;
    flash-right) flash_side right ;;
    flash)       flash_side left; echo ""; flash_side right ;;
    *)           echo "Usage: $0 [left|right|both|update|flash-left|flash-right|flash]"; exit 1 ;;
esac
