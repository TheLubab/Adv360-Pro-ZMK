#!/usr/bin/env bash
# Guided Linux UF2 flashing. Never builds or downloads firmware.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
firmware_dir=${1:-"$script_dir/../firmware"}
owned_mount=''

privileged() {
    if ((EUID == 0)); then
        "$@"
    else
        sudo -- "$@"
    fi
}

cleanup_mount() {
    [[ -n $owned_mount ]] || return 0
    if findmnt --mountpoint "$owned_mount" >/dev/null 2>&1; then
        if ! privileged umount -- "$owned_mount"; then
            printf 'Could not unmount %s; leaving it in place.\n' "$owned_mount" >&2
            return 1
        fi
    fi
    rmdir -- "$owned_mount"
    owned_mount=''
}

trap 'cleanup_mount' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
    cat <<'HELP'
Usage: bash bin/flash.sh [firmware-directory]

Flash existing Advantage360 Pro .uf2 files on Linux, one half at a time.
Extract the GitHub firmware artifact first, then pass its directory.
Without an argument, files are read from this repository's firmware/.

You choose the side and file, connect that half, enter bootloader mode,
and confirm before copying. If needed, the script mounts ADV360PRO with
udisksctl or sudo mount (including on NixOS). It never builds or downloads.
HELP
}

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
    usage
    exit 0
fi
[[ $# -le 1 ]] || { usage >&2; exit 1; }
[[ $(uname -s) == Linux ]] || { echo 'This script supports Linux only.' >&2; exit 1; }
[[ -t 0 ]] || { echo 'Run this script in an interactive terminal.' >&2; exit 1; }
[[ -d $firmware_dir ]] || { echo "Firmware directory not found: $firmware_dir" >&2; exit 1; }
for command in find lsblk awk cp od tr sync findmnt mktemp rmdir id; do
    command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done

choose_file() {
    local side=$1 file name choice magic
    local -a files=()
    while IFS= read -r -d '' file; do
        name=${file##*/}
        if [[ ${name,,} =~ (^|[-_])$side([-_.]|$) ]]; then
            files+=("$file")
        fi
    done < <(find "$firmware_dir" -type f -iname '*.uf2' -print0)
    if ((${#files[@]} == 0)); then
        echo "No $side firmware found in $firmware_dir." >&2
        echo "Expected a filename such as left.uf2 or TIMESTAMP-$side.uf2." >&2
        return 1
    fi
    printf '\nFirmware for %s:\n' "$side"
    for choice in "${!files[@]}"; do
        printf '  %d) %s\n' "$((choice + 1))" "${files[$choice]}"
    done
    while true; do
        read -r -p 'Choose a file number (q to cancel): ' choice
        [[ $choice != q ]] || return 1
        if [[ $choice =~ ^[1-9][0-9]*$ && ${#choice} -le 6 ]] && ((10#$choice <= ${#files[@]})); then
            selected_file=${files[$((10#$choice - 1))]}
            break
        fi
        echo 'Enter one of the file numbers.'
    done
    # UF2's first two magic words, represented in on-disk byte order.
    magic=$(od -An -tx1 -N8 -- "$selected_file" | tr -d ' \n')
    [[ $magic == 5546320a57515d9e ]] || { echo 'This file does not have a UF2 header.' >&2; return 1; }
}

flash_side() {
    local side=$1 answer device mountpoint status elapsed
    local selected_file
    local -a devices=()
    choose_file "$side" || return 0
    printf '\nConnect ONLY the %s half by USB and enter bootloader mode.\n' "$side"
    echo 'Both halves use the ADV360PRO label; the script cannot identify the side.'
    echo "With this repository's keymap installed:"
    echo '  Hold Mod: the top inner key on the RIGHT half, beside the number row.'
    if [[ $side == left ]]; then
        echo '  Tap the upper LEFT inner hotkey (the QWERTY switch / original hotkey 1).'
    else
        echo '  Tap the upper RIGHT inner hotkey (beside Y / original hotkey 3).'
    fi
    echo 'Then release both keys. Alternatively, double-press the reset button'
    echo 'on the underside of the selected half.'
    read -r -p 'Press Enter when ready, or q to cancel: ' answer
    [[ $answer != q ]] || return 0
    mapfile -t devices < <(lsblk -lnpo NAME,LABEL | awk '$2 == "ADV360PRO" {print $1}')
    if ((${#devices[@]} != 1)); then
        printf 'Expected exactly one ADV360PRO drive; found %d. Nothing copied.\n' "${#devices[@]}" >&2
        return 1
    fi
    device=${devices[0]}
    mountpoint=$(lsblk -dnro MOUNTPOINT "$device")
    if [[ -z $mountpoint ]]; then
        if command -v udisksctl >/dev/null; then
            udisksctl mount --block-device "$device"
            mountpoint=$(lsblk -dnro MOUNTPOINT "$device")
        else
            command -v mount >/dev/null || { echo 'Missing command: mount' >&2; return 1; }
            if ((EUID != 0)); then
                command -v sudo >/dev/null || { echo 'Mounting requires sudo on this system.' >&2; return 1; }
            fi
            owned_mount=$(mktemp -d /tmp/adv360-flash.XXXXXXXX)
            echo 'Mounting the bootloader drive; sudo may ask for your password.'
            privileged mount -t vfat -o "rw,nosuid,nodev,noexec,uid=$(id -u),gid=$(id -g),umask=077" -- "$device" "$owned_mount"
            mountpoint=$owned_mount
        fi
    fi
    [[ -n $mountpoint && -d $mountpoint ]] || { echo 'Could not find the mounted drive.' >&2; return 1; }
    printf '\nSide: %s\nFile: %s\nDrive: %s (%s)\n' "$side" "$selected_file" "$device" "$mountpoint"
    read -r -p "Type '$side' to copy, or anything else to cancel: " answer
    [[ $answer == "$side" ]] || { echo 'Cancelled; nothing copied.'; cleanup_mount; return 0; }
    # Copy once. Never retry automatically: a disconnect may mean flashing started.
    if ! cp -- "$selected_file" "$mountpoint/firmware.uf2"; then
        echo 'Copy reported an error. Check the keyboard before retrying; it may have disconnected during flashing.' >&2
        return 1
    fi
    # Flush writes if the device has not already rebooted.
    if [[ -d $mountpoint ]]; then
        sync -f "$mountpoint" 2>/dev/null || echo "Flush could not finish; the keyboard may already have disconnected."
    fi
    echo 'Copy completed. Waiting up to 30 seconds for the bootloader drive to disconnect...'
    for ((elapsed=0; elapsed<30; elapsed++)); do
        status=$(lsblk -dnro LABEL "$device" 2>/dev/null || true)
        if [[ $status != ADV360PRO ]]; then
            echo 'Bootloader drive disconnected. Check that this half restarted normally.'
            cleanup_mount
            return 0
        fi
        sleep 1
    done
    echo 'The drive is still present. Verify flashing completed before unplugging; the script cannot confirm success.' >&2
    return 1
}

while true; do
    printf '\nFlash which half?\n  1) Left\n  2) Right\n  3) Both, one at a time\n  q) Quit\n'
    read -r -p '> ' choice
    case $choice in
        1) flash_side left ;;
        2) flash_side right ;;
        3) flash_side left; flash_side right ;;
        q|Q) exit 0 ;;
        *) echo 'Choose 1, 2, 3, or q.' ;;
    esac
done
