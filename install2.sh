#!/usr/bin/env bash
set -e

# Re-written with inspiration from
# https://github.com/kentyl/archinstaller/blob/master/install
# and
# https://github.com/mdaffin/arch-pkgs/blob/master/installer/install-arch

###
### Configuration
###

INS_BAK_DIR='/installation'
INS_DISK="${INS_DISK:-/dev/$(lsblk | awk '/ disk /{print $1}' | sort -u | head -1)}"
INS_DOC="${INS_BAK_DIR}/README.md"
INS_EFI_SIZE='+550MiB'
INS_TIME_ZONE="${INS_TIME_ZONE:-America/Chicago}"
INS_SWAP_KEY=/etc/swap.key
INS_SWAP_SIZE="$(free -g | awk '/^Mem:/ { printf "+%1.fGiB", $2+1 }')"
INS_EFI_PART="${INS_DISK}1"
INS_SWAP_PART="${INS_DISK}2"
INS_ROOT_PART="${INS_DISK}3"

# You'll get prompted for the password if it's not set.
# It's most secure to use that way or pass it into the script environment.
#INS_ENC_PASS="foo"

###
### Function definitions
###

function stderr {
    echo -ne "${@}" 1>&2
}

function error {
    stderr "Error: ${*}"
    return 1
}

function test_network {
    local TEST_ADDR="${1:-1.1.1.1}"
    if ! ping -c1 "${TEST_ADDR}" 1>/dev/null
    then
        echo "Network not connected, assuming 802.1x auth needed"
        ip link
        read -p "Interface: " interface
        read -p "Username: " user_name
        read -s -p "Password: " user_pass
        if (systemctl status NetworkManager | grep -q 'Active: active (running)')
        then
            setup_nmcli_8021x "${interface}" "${user_name}" "${user_pass}"
        else
            setup_dhcpcd_8021x "${interface}" "${user_name}" "${user_pass}"
        fi
    fi
    if ! ping -c1 archlinux.org 1>/dev/null
    then
        error "Sorry, couldn't get networking working.\nPlease set it up manually and try again."
    fi
}

function setup_dhcpcd_8021x {
    local interface=${1}
    local user_name=${2}
    local user_pass=${3}
    cat <<EOF > "/etc/wpa_supplicant/wpa_supplicant-wired-${interface}.conf"
ctrl_interface=/var/run/wpa_supplicant
ap_scan=0
network={
  eap=PEAP
  key_mgmt=IEEE8021X
  phase2="autheap=MSCHAPV2"
  identity="${user_name}"
  password="${user_pass}"
}
EOF
    systemctl start "dhcpcd@${interface}.service"
}

function setup_nmcli_8021x {
    local interface=${1}
    local user_name=${2}
    local user_pass=${3}
    nmcli connection add save yes \
        +connection.id "${interface}-802-1x" \
        +connection.type 802-3-ethernet \
        +connection.interface-name "${interface}" \
        +ipv4.method auto \
        +802-1x.eap peap \
        +802-1x.phase1-peapver 0 \
        +802-1x.phase2-auth mschapv2 \
        +802-1x.system-ca-certs no \
        +802-1x.identity "${user_name}" \
        +802-1x.password "${user_pass}"
    nmcli connection up "${interface}-802-1x"
}

function setup_nmfile_8021x {
    local interface=${1}
    local user_name=${2}
    local user_pass=${3}
    local sys_conns=${4:-/etc/NetworkManager/system-connections}
    cat <<EOF > "${sys_conns}/${interface}-802-1x"
[connection]
id=${interface}-802-1x
uuid=$(uuidgen)
type=ethernet
interface-name=${interface}
permissions=
timestamp=$(date +%s)

[ethernet]
mac-address-blacklist=

[802-1x]
eap=peap;
identity=${user_name}
password=${user_pass}
phase1-peapver=0
phase2-auth=mschapv2
system-ca-certs=false

[ipv4]
dns-search=
method=auto

[ipv6]
addr-gen-mode=stable-privacy
dns-search=
method=auto
EOF
    chmod 600 "${sys_conns}/${interface}-802-1x"
}

function assert_efi_boot {
    if [ ! -d /sys/firmware/efi/efivars ]; then
        error 'Only EFI boot supported, no EFI vars found'
    fi
}

function assert_valid_disk {
    local DISK="${1}"
    local OUTPUT

    if ! OUTPUT="$(sfdisk --list "${DISK}" 2>/dev/null)"; then
        error "Disk ${DISK} missing"
    fi
    if echo "${OUTPUT}" | grep Start 1>/dev/null; then
        error "Disk ${DISK} is not empty (it has a partition table)"
    fi
}

function wipe_disk_with_random_data {
    local DISK="${1}"

    cryptsetup open --type plain "${DISK}" container --key-file /dev/random
    stderr "Erasing disk ${DISK} with random data: (fill until no more space left)\n\n"
    # "|| true" as disk will be filled until max and then failure
    dd if=/dev/zero of=/dev/mapper/container bs=250M status=progress || true
    stderr "\n\n"
    cryptsetup close container
    partprobe "${DISK}"
}

function create_partitions {
    local DISK="${1}"
    local EFI_SIZE="${2}"
    local SWAP_SIZE="${3}"

    # See https://www.freedesktop.org/wiki/Specifications/DiscoverablePartitionsSpec/
    # And https://linux.die.net/man/8/sgdisk for more information on typecodes
    sgdisk \
        --clear \
        --new 1::"${EFI_SIZE}" \
            --change-name 1:EFI \
            --typecode 1:c12a7328-f81f-11d2-ba4b-00a0c93ec93b \
        --new 2::"${SWAP_SIZE}" \
            --change-name 2:cryptswp \
            --typecode 2:0657fd6d-a4ab-43c4-84e5-0933c84b4f4f \
        --new 3:: \
            --change-name 3:cryptsys \
            --typecode 3:4f68bce3-e8cd-4db1-96e7-fbcaf984b709 \
        "${DISK}" 1>/dev/null
    partprobe "${DISK}"
}

function set_time_through_ntp {
    local TIME_ZONE="${1}"
    local NTP_SERVER="${2:-time.rackspace.com}"
    local TIMESYNCD="${3:-/etc/systemd/timesyncd.conf}"
    if ! timedatectl set-timezone "${TIME_ZONE}" 2>/dev/null; then
        error "Invalid time zone ${TIME_ZONE}"
    fi
    timedatectl set-ntp false
    stderr "Setting time server to ${NTP_SERVER}\n"
    sed -i '/\[Time\]/q' "${TIMESYNCD}"
    (echo "NTP=${NTP_SERVER}";
    echo "FallbackNTP=" {0..3}.arch.pool.ntp.org | sed 's/= /=/';
    echo "PollIntervalMinSec=16") >> "${TIMESYNCD}"
    stderr "Syncronizing time"
    timedatectl set-ntp true
    SLEEPWAIT=0
    while (timedatectl status | grep -q "synchronized: no"); do
        sleep 1
        stderr '.'
        ((SLEEPWAIT++))
        if [[ ${SLEEPWAIT} -gt 35 ]]
        then
            stderr "\nCould not sync time. Carrying on anyways.\n"
            break
        fi
    done
    sed -i "/PollIntervalMinSec/d" "${TIMESYNCD}"
    stderr 'DONE!\n'
}

function format_fat32 {
    local PARTITION="${1}"

    stderr "Formatting ${PARTITION} with FAT32: "
    mkfs.vfat -F32 "${PARTITION}" 1>/dev/null
    stderr 'DONE!\n'
}

function cryptsetup_slash {
    local PASSWORD="${1}"
    local PARTITION="${2}"
    local CONTAINER_NAME="${3:-cryptsys}"
    
    # "--key-file -"" is used to take the password
    # from stdin, it won't actually use a file
    stderr "Formatting ${PARTITION} to hold LUKS container for /: "
    echo "${PASSWORD}" | cryptsetup luksFormat "${PARTITION}" --align-payload=8192 --key-size 512 --cipher aes-xts-plain64 --key-file -
    stderr 'DONE!\n'
    stderr "Opening LUKS container as ${CONTAINER_NAME}: "
    echo "${PASSWORD}" | cryptsetup open "${PARTITION}" "${CONTAINER_NAME}" --key-file -
    stderr 'DONE!\n'
    echo "${CONTAINER_NAME}"
}

function format_btrfs {
    local PARTITION="${1}"
    local LABEL="${2:-system}"
    mkfs.btrfs --label "${LABEL}" "${PARTITION}" 1>/dev/null
}

function create_btrfs_subvolume {
    local FILESYSTEM="${1}"
    local SUBVOLUME="${2}"
    btrfs subvolume create "${FILESYSTEM}/${SUBVOLUME}" 1>/dev/null
}

function mount_chroot {
    local ROOT_PARTITION="${1}"
    local EFI_PARTITION="${2}"
    local DEFAULT_OPTS="defaults,x-mount.mkdir"
    local BTRFS_OPTS="${DEFAULT_OPTS},compress=lzo,ssd,noatime"

    stderr "Mounting chroot partitions: "
    mount -t btrfs -o "${BTRFS_OPTS}" "${ROOT_PARTITION}" /mnt
    create_btrfs_subvolume /mnt @
    create_btrfs_subvolume /mnt @home
    create_btrfs_subvolume /mnt @snapshots
    create_btrfs_subvolume /mnt @home@snapshots
    umount -R /mnt
    mount -t btrfs -o "subvol=@,${BTRFS_OPTS}" "${ROOT_PARTITION}" /mnt
    mount -t btrfs -o "subvol=@home,${BTRFS_OPTS}" "${ROOT_PARTITION}" /mnt/home
    mount -t btrfs -o "subvol=@snapshots,${BTRFS_OPTS}" "${ROOT_PARTITION}" /mnt/.snapshots
    mount -t btrfs -o "subvol=@home@snapshots,${BTRFS_OPTS}" "${ROOT_PARTITION}" /mnt/home/.snapshots
    mount -t vfat -o "${DEFAULT_OPTS}" "${EFI_PARTITION}" /mnt/boot
    stderr 'DONE!\n'
}

function create_swap_key {
    local SWAP_KEY="${1}"

    stderr "Creating key file ${SWAP_KEY} which will be used by swap container: "
    mkdir -p "$(dirname "${SWAP_KEY}")"
    dd bs=512 count=1 if=/dev/random of="${SWAP_KEY}" status=none
    stderr 'DONE!\n'
}

function cryptsetup_swap {
    local PARTITION="${1}"
    local SWAP_KEY="${2}"
    local CONTAINER_NAME="${3:-cryptswp}"
    
    stderr "Formatting ${PARTITION} to hold LUKS container for swap: "
    cryptsetup luksFormat --batch-mode "${PARTITION}" "${SWAP_KEY}"
    stderr 'DONE!\n'
    stderr "Opening LUKS container as ${CONTAINER_NAME}: "
    cryptsetup open --key-file="${SWAP_KEY}" "${PARTITION}" "${CONTAINER_NAME}"
    stderr 'DONE!\n'
    echo "${CONTAINER_NAME}"
}

function set_as_swap {
    local PARTITION="${1}"

    stderr "Preparing ${PARTITION} to be used as swap: "
    mkswap --label SWAP "${PARTITION}" 1>/dev/null
    swapon "${PARTITION}" 1>/dev/null
    stderr 'DONE!\n'
}

function backup_partition_table {
    local DISK="${1}"
    local BACKUP_DIR="${2}"
    local BACKUP_BASENAME
    BACKUP_BASENAME="sgdisk-$(basename "${DISK}").bin"

    mkdir -p "${BACKUP_DIR}"

    stderr "Backing up partition table: "

    sgdisk -b="${BACKUP_DIR}/${BACKUP_BASENAME}" "${DISK}" 1>/dev/null

    stderr 'DONE!\n'

    echo "${BACKUP_BASENAME}"
}

function backup_luks_header {
    local PARTITION="${1}"
    local BACKUP_DIR="${2}"
    local BACKUP_BASENAME
    BACKUP_BASENAME="luksHeaderBackup-$(basename "${PARTITION}").img"

    mkdir -p "${BACKUP_DIR}"

    stderr "Backing up LUKS header: "

    cryptsetup luksHeaderBackup "${PARTITION}" --header-backup-file "${BACKUP_DIR}/${BACKUP_BASENAME}"

    stderr 'DONE!\n'

    echo "${BACKUP_BASENAME}"
}

function update_mirrorlist {
    mv /etc/pacman.d/mirrorlist{,.backup}
    rankmirrors -n 5 /etc/pacman.d/mirrorlist.backup > /etc/pacman.d/mirrorlist.ranked
    head -6 /etc/pacman.d/mirrorlist.ranked > /etc/pacman.d/mirrorlist
    echo "Server = https://mirror.rackspace.com/archlinux/\$repo/os/\$arch" >> /etc/pacman.d/mirrorlist
    tail -5 /etc/pacman.d/mirrorlist.ranked | grep -v rackspace >> /etc/pacman.d/mirrorlist
}

function add_documentation {
    local DOC="${1}"
    local DISK="${2}"
    local SWAP_KEY="${3}"
    local BACKUP_PARTITION_TABLE="${4}"
    local BACKUP_LUKS_HEADER="${5}"

    stderr "Adding documentation: "
    (echo -e "# Installation documentation\n";

    echo -e "## Before chroot\n";

    echo -e "\nInstallation parameters:\n";
    
    printf "%-45s | %-35s\n" "Parameter" "Value";
    printf "%-45s | %-35s\n" "------" "------";
    eval "$(set | grep '^INS_' | grep -v PASSWORD | sed -e 's/INS_//' | sort | sed -r -e 's/([^=]+)=(.*)/printf "%-45s | %-35s\n" \1 \2/')";

    echo -e "\nISO label: \`$(sed -r -e 's/.*archisolabel=([^ ]+).*/\1/' /proc/cmdline)\`";

    echo "Installation date: \`$(date --utc)\`";

    echo -e "\n### Partitions\n";

    echo "Destination disk: \`$DISK\`";
    echo "Swap key location: \`$SWAP_KEY\`";
    echo "Partition table backup: \`$BACKUP_PARTITION_TABLE\`";
    echo "LUKS header backup: \`$BACKUP_LUKS_HEADER\`";

    echo -e "\n\`fdisk -l\`:\n";
    fdisk -l "$DISK" | sed -e 's/^/    /';

    echo -e "\n\`blkid\`:\n";
    blkid | grep -E "/mapper/|$DISK.:" | sed -e 's/^/    /') >> "$DOC"

    stderr 'DONE!\n'
}

###
### Installation
###

if [[ -z "${INS_ENC_PASS}" ]]; then
    stderr "Enter disk encryption password:\n"
    read -s ENTER1
    stderr "Enter disk encryption password again:\n"
    read -s ENTER2
    if [[ "${ENTER1}" != "${ENTER2}" ]]; then
        error 'Passwords do not match'
    fi
    INS_ENC_PASS="${ENTER1}"
    unset ENTER1 ENTER2
fi

test_network "1.1.1.1"

assert_efi_boot

assert_valid_disk "${INS_DISK}"

set_time_through_ntp "$INS_TIME_ZONE"

wipe_disk_with_random_data "${INS_DISK}"

create_partitions "${INS_DISK}" "${INS_EFI_SIZE}" "${INS_SWAP_SIZE}"

format_fat32 "${INS_EFI_PART}"

INS_ROOT_CONTAINER="$(cryptsetup_slash "${INS_PASSWORD}" "${INS_ROOT_PART}")"

format_btrfs "/dev/mapper/${INS_ROOT_CONTAINER}"

mount_chroot "/dev/mapper/${INS_ROOT_CONTAINER}" "${INS_EFI_PART}"

create_key "/mnt${INS_SWAP_KEY}"

INS_SWAP_CONTAINER="$(cryptsetup_swap "${INS_SWAP_PART}" "/mnt${INS_SWAP_KEY}")"

set_as_swap "/dev/mapper/${INS_SWAP_CONTAINER}"

INS_BACKUP_PARTITION_TABLE_BASENAME="$(backup_partition_table "${INS_DISK}" "/mnt${INS_BAK_DIR}")"

INS_BACKUP_LUKS_HEADER_BASENAME="$(backup_luks_header "${INS_SLASH_PART}" "/mnt${INS_BAK_DIR}")"

add_documentation "/mnt$INS_DOC" "$INS_DISK" "$INS_SWAP_KEY" "$INS_BAK_DIR/$INS_BACKUP_PARTITION_TABLE_BASENAME" "$INS_BAK_DIR/$INS_BACKUP_LUKS_HEADER_BASENAME"

update_mirrorlist
