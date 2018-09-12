#!/usr/bin/env zsh
if ! ping -c1 1.1.1.1; then
  echo 'Network not connected, setting up network now'
  ip a
  read 'adapter?Interface: '
  read 'user_name?Username: '
  read -s 'user_password?Password: '
  if ! (systemctl status NetworkManager | grep -q 'Active: active (running)'); then
    cat <<EOF > /etc/wpa_supplicant/wpa_supplicant-wired-${adapter}.conf
ctrl_interface=/var/run/wpa_supplicant
ap_scan=0
network={
  eap=PEAP
  key_mgmt=IEEE8021X
  phase2="autheap=MSCHAPV2"
  identity="${user_name}"
  password="${user_password}"
}
EOF
    systemctl start dhcpcd@${adapter}.service
  else
    nmcli connection add save yes \
    +connection.id RS8021x \
    +connection.type 802-3-ethernet \
    +connection.interface-name ${adapter} \
    +ipv4.method auto \
    +802-1x.eap peap \
    +802-1x.phase1-peapver 0 \
    +802-1x.phase2-auth mschapv2 \
    +802-1x.system-ca-certs no \
    +802-1x.identity "${user_name}" \
    +802-1x.password "${user_password}"
    nmcli connection up RS8021x
  fi
fi

if ! ping -c1 archlinux.org; then
  echo "Sorry, couldn't get networking working."
  echo "Please set it up manually and try again."
  exit
fi

DRIVE=/dev/$(lsblk | awk '/ disk /{print $1}' | sort -u | head -1)
MYHOSTNAME=raxnuc
ALWAYSPAUSE=0
function ekho {
  if [[ ${ALWAYSPAUSE} != 0 ]]; then
    echo "Did the previous command execute successfully (y/n)? "
    read yn
    if [[ "${yn}" != "y" ]]; then
      exit
    fi
  fi
  echo
  echo "${@}"
}
printf -v SWAPSIZE %.0f $((($(awk '/MemTotal/{print $2}' /proc/meminfo) * 1.25) / 1000000))
echo "Swap will be ${SWAPSIZE}GiB"

lsblk
ekho "Zapping ${DRIVE}..."
echo "Press w to wipe and continue, z to just zap the disk, or CTRL-C to exit"
read p
if [[ "${p}" == "w" ]]; then
  cryptsetup open --type plain ${DRIVE} container --key-file /dev/urandom
  dd if=/dev/zero of=/dev/mapper/container status=progress bs=1M
  cryptsetup close container
elif [[ "${p}" == "z" ]]; then
  sgdisk --zap-all ${DRIVE}
fi
partprobe ${DRIVE} || exit
lsblk

ekho "Creating partitions on ${DRIVE}"
sgdisk --clear \
       --new=1:0:+550MiB         --typecode=1:ef00 --change-name=1:EFI \
       --new=2:0:+${SWAPSIZE}GiB --typecode=2:8200 --change-name=2:cryptswp \
       --new=3:0:0               --typecode=3:8300 --change-name=3:cryptsys \
         ${DRIVE}
partprobe ${DRIVE} || exit
lsblk

ekho "Making EFI filesystem"
mkfs.fat -F32 -n EFI /dev/disk/by-partlabel/EFI || exit

ekho "Creating LUKS partition for system"
cryptsetup luksFormat --align-payload=8192 --key-size 512 --cipher aes-xts-plain64 /dev/disk/by-partlabel/cryptsys || exit

ekho "Opening LUKS partition for system"
cryptsetup open --type luks /dev/disk/by-partlabel/cryptsys system || exit

ekho "Opening LUKS partition for swap"
cryptsetup open --type plain --key-file /dev/random /dev/disk/by-partlabel/cryptswp swap || exit

ekho "Initializing swap on /dev/mapper/swap"
mkswap -L swap /dev/mapper/swap || exit

ekho "Engaging swap" || exit
swapon -L swap

ekho "Creating BTRFS filesystem on /dev/mapper/system"
mkfs.btrfs --force --label system /dev/mapper/system || exit

DEFAULT_OPTS=defaults,x-mount.mkdir
BTRFS_OPTS=${DEFAULT_OPTS},compress=lzo,ssd,noatime

ekho "Mounting BTRFS filesystem on /mnt"
mount -t btrfs -o ${BTRFS_OPTS} LABEL=system /mnt || exit

ekho "Creating subvolume for root"
btrfs subvolume create /mnt/@ || exit

ekho "Creating subvolume for /home"
btrfs subvolume create /mnt/@home || exit

ekho "Creating subvolume for /.snapshots"
btrfs subvolume create /mnt/@snapshots || exit

ekho "Unmounting /mnt system"
umount -R /mnt

ekho "Remounting root subvolume"
mount -t btrfs -o subvol=@,${BTRFS_OPTS} LABEL=system /mnt

ekho "Remounting /home subvolume"
mount -t btrfs -o subvol=@home,${BTRFS_OPTS} LABEL=system /mnt/home

ekho "Remounting /.snapshots subvolume"
mount -t btrfs -o subvol=@snapshots,${BTRFS_OPTS} LABEL=system /mnt/.snapshots

ekho "Creating /boot"
mkdir /mnt/boot

ekho "Mounting EFI partition on /boot"
mount -t vfat LABEL=EFI /mnt/boot

ekho "Backing up pacman mirrorlist"
mv /etc/pacman.d/mirrorlist{,.backup}

ekho "Ranking pacman mirrors"
rankmirrors -n 5 /etc/pacman.d/mirrorlist.backup > /etc/pacman.d/mirrorlist.ranked

ekho "Creating new mirrorlist"
head -6 /etc/pacman.d/mirrorlist.ranked > /etc/pacman.d/mirrorlist
echo 'Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch' >> /etc/pacman.d/mirrorlist
tail -5 /etc/pacman.d/mirrorlist.ranked | grep -v rackspace >> /etc/pacman.d/mirrorlist

ekho "Created:"
cat /etc/pacman.d/mirrorlist

ekho "Cleaning up ranked list"
rm -f /etc/pacman.d/mirrorlist.ranked

ekho "Updating archlinux-keyring"
pacman -Syy --needed archlinux-keyring pacman

ekho "Running pacstrap"
pacstrap /mnt btrfs-progs ansible base

ekho "Generating fstab"
genfstab -L -p /mnt >> /mnt/etc/fstab

ekho "Fixing swap partition"
sed -i 's!LABEL=swap!/dev/mapper/swap!' /mnt/etc/fstab

## Phase 2
cat <<ENDPHASE2 > /mnt/phase2.sh
#!/usr/bin/env bash
ALWAYSPAUSE=0

function ekho {
  if [[ ${ALWAYSPAUSE} != 0 ]]; then
    echo "Did the previous command execute successfully (y/n)? "
    read yn
    if [[ "${yn}" != "y" ]]; then
      exit
    fi
  fi
  echo
  echo "${@}"
}

echo "Set root password:"
passwd

ekho "Configuring /etc/mkinitcpio.conf"
sed -i -e 's/^MODULES=.*/MODULES=(i915)/' /etc/mkinitcpio.conf
sed -i -e 's/^HOOKS=/#HOOKS=/' /etc/mkinitcpio.conf
sed -i -e '/#HOOKS=/a HOOKS=(base systemd sd-vconsole autodetect modconf keyboard block filesystems btrfs sd-encrypt fsck)' /etc/mkinitcpio.conf
grep -v '^#' /etc/mkinitcpio.conf

ekho "Installing systemd-boot in /boot"
bootctl --path=/boot install

ekho "Adding cryptsys to /etc/crypttab for initramfs"
cat <<EOF >> /etc/crypttab.initramfs
# <name>  <device>                           <password>    <options>
system    /dev/disk/by-partlabel/cryptsys
EOF
cat /etc/crypttab.initramfs

ekho "Adding cryptswp to /etc/crypttab"
awk -v p=/dev/disk/by-partlabel/cryptswp '/# swap/{print $2"    "p"    "$4"    "$5}' /etc/crypttab >> /etc/crypttab
cat /etc/crypttab

echo "Setting bootloader settings"
cat <<EOF > /boot/loader/loader.conf
default arch
timeout 15
editor 0
EOF

ekho "Creating arch bootloader entry"
cat <<EOF >> /boot/loader/entries/arch.conf
title Arch Linux
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options luks.allow-discards root=/dev/mapper/system rootflags=subvol=@ rw
EOF

echo "Exiting systemd-nspawn"
poweroff
ENDPHASE2

chmod +x /mnt/phase2.sh

ekho "Log in to systemd shell as root and run /phase2.sh"
systemd-nspawn -b -E MYHOSTNAME=${MYHOSTNAME} -D /mnt

ekho "Unmounting /mnt"
umount -R /mnt

ekho "Turning off swap"
swapoff /dev/mapper/swap

ekho "Closing LUKS partitions"
cryptsetup close /dev/mapper/system
cryptsetup close /dev/mapper/swap

ekho "Shutting down in 15 seconds..."
sleep 15
poweroff
echo 'Done!'
