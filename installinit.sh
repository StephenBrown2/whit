#!/usr/bin/env zsh
DRIVE=/dev/$(lsblk | awk '/disk/{print $1}' | sort -u | head -1)
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
printf -v SWAPSIZE %.0f $(($(awk '/MemTotal/{print $2}' /proc/meminfo) * 1.25 / 1000000))
echo "Swap will be ${SWAPSIZE}GiB"

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
partprobe ${DRIVE}

ekho "Creating partitions on ${DRIVE}"
sgdisk --clear \
       --new=1:0:+550MiB         --typecode=1:ef00 --change-name=1:EFI \
       --new=2:0:+${SWAPSIZE}GiB --typecode=2:8200 --change-name=2:cryptswp \
       --new=3:0:0               --typecode=2:8300 --change-name=3:cryptsys \
         ${DRIVE}
partprobe ${DRIVE}

ekho "Making EFI filesystem"
mkfs.fat -F32 -n EFI /dev/disk/by-partlabel/EFI

ekho "Creating LUKS partition for system"
cryptsetup luksFormat --align-payload=8192 -s 256 -c aes-xts-plain64 /dev/disk/by-partlabel/cryptsys

ekho "Opening LUKS partition for system"
cryptsetup open /dev/disk/by-partlabel/cryptsys system

ekho "Opening LUKS partition for swap"
cryptsetup open --type plain --key-file /dev/random /dev/disk/by-partlabel/cryptswp swap

ekho "Initializing swap on /dev/mapper/swap"
mkswap -L swap /dev/mapper/swap

ekho "Engaging swap"
swapon -L swap

ekho "Creating BTRFS filesystem on /dev/mapper/system"
mkfs.btrfs --force --label system /dev/mapper/system

DEFAULT_OPTS=defaults,x-mount.mkdir
BTRFS_OPTS=${DEFAULT_OPTS},compress=lzo,ssd,noatime

ekho "Mounting BTRFS filesystem on /mnt"
mount -t btrfs LABEL=system /mnt

ekho "Creating subvolume for root"
btrfs subvolume create /mnt/@

ekho "Creating subvolume for /home"
btrfs subvolume create /mnt/@home

ekho "Creating subvolume for /.snapshots"
btrfs subvolume create /mnt/@snapshots

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
pacman -Syy archlinux-keyring pacman

ekho "Running pacstrap"
pacstrap /mnt btrfs-progs ansible base

ekho "Generating fstab"
genfstab -L -p /mnt >> /mnt/etc/fstab

ekho "Fixing swap partition"
sed -i 's!LABEL=swap!/dev/mapper/swap!' /mnt/etc/fstab

## Phase 2
cat <<ENDPHASE2 > /mnt/phase2.sh
#!/usr/bin/env bash
echo "Set root password:"
passwd

echo "Enabling en_US locales"
sed -i 's/^#en_US/en_US/' /etc/locale.gen

echo "Generating locales"
locale-gen

echo "Setting locales with localectl"
localectl set-locale LANG=en_US.UTF-8

echo "Enabling NTP"
timedatectl set-ntp true

echo "Setting timezone to America/Chicago"
timedatectl set-timezone America/Chicago

echo "Setting hostname to ${MYHOSTNAME}"
hostnamectl set-hostname ${MYHOSTNAME}

echo "Writing /etc/hosts file"
cat <<EOF >> /etc/hosts
127.0.0.1  localhost
::1        localhost
127.0.1.1  ${MYHOSTNAME}.localdomain ${MYHOSTNAME}
EOF

echo "Exiting systemd-nspawn"
poweroff
ENDPHASE2

chmod +x /mnt/phase2.sh

ekho "Log in to systemd shell as root and run /phase2.sh"
systemd-nspawn -b -E MYHOSTNAME=${MYHOSTNAME} -D /mnt

## Phase 3
cat <<'ENDPHASE3' > /mnt/phase3.sh
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

echo "Adding sudo group"
groupadd -g 100 sudo

ekho "Adding stephen user"
useradd -m -c "Stephen Brown II" -u 1000 -U -G sudo -s /usr/bin/zsh stephen

ekho "Set stephen's password"
passwd stephen

ekho "Adding stephen to sudoers.d"
mkdir /etc/sudoers.d
echo 'stephen ALL=(ALL) ALL' > /etc/sudoers.d/stephen
echo 'stephen ALL=(ALL) NOPASSWD:/usr/bin/pacman' >> /etc/sudoers.d/stephen

ekho "Installing base-devel and other useful utilities"
pacman -Syu --needed base-devel gptfdisk zsh vim terminus-font intel-ucode git go

ekho "Configuring /etc/mkinitcpio.conf"
sed -i -e 's/^MODULES=.*/MODULES=(i915)/' /etc/mkinitcpio.conf
sed -i -e 's/^HOOKS=/#HOOKS=/' /etc/mkinitcpio.conf
sed -i -e '/#HOOKS=/a HOOKS=(base systemd sd-vconsole autodetect modconf keyboard block filesystems btrfs sd-encrypt fsck)' /etc/mkinitcpio.conf
grep -v '^#' /etc/mkinitcpio.conf

ekho "Setting vconsole font"
cat <<EOF >> /etc/vconsole.conf
FONT=Lat2-Terminus16
EOF

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

ekho "Installing yay from AUR using git as stephen"
su - stephen -c 'git clone https://aur.archlinux.org/yay.git ~/yay; cd ~/yay; makepkg -fi; cd ~; rm -rf yay'

ekho "Installing more things including AUR packages"
su - stephen -c 'yay -Syu sddm cinnamon arc-gtk-theme arc-icon-theme paper-icon-theme noto-fonts-emoji ttf-ubuntu-font-family otf-montserrat nerd-fonts-complete kitty aic94xx-firmware wd719x-firmware grml-zsh-config'

ekho "Fixing Arc icon theme inheritence"
sed -i -e 's/Inherits=Moka/Inherits=Paper/' /usr/share/icons/Arc/index.theme

ekho "Setting Cinnamon DE dconf icons keyfile"
mkdir -p /etc/dconf/db/user.d
cat <<EOF >> /etc/dconf/db/user.d/icons.txt
[org/cinnamon/desktop/interface]
cursor-theme='Paper'
icon-theme='Arc'
gtk-theme='Arc-Dark'
[org/cinnamon/desktop/wm/preferences]
theme='Arc-Dark'
[org/cinnamon/theme]
name='Arc-Dark'
EOF

ekho "Setting Cinnamon DE dconf fonts keyfile"
cat <<EOF >> /etc/dconf/db/user.d/fonts.txt
[org/cinnamon/desktop/interface]
font-name='Montserrat Light 9'
[org/cinnamon/desktop/wm/preferences]
titlebar-font='Montserrat 10'
[org/gnome/desktop/interface]
document-font-name='Montserrat 11'
monospace-font-name='FantasqueSansMono Nerd Font 11'
[org/nemo/desktop]
font='Montserrat Light 10'
EOF

ekho "Enabling sddm without systemd"
ln -s /usr/lib/systemd/system/sddm.service /etc/systemd/system/display-manager.service

ekho "Enabling NetworkManager without systemd"
ln -s /usr/lib/systemd/system/NetworkManager.service /etc/systemd/system/dbus-org.freedesktop.NetworkManager.service
ln -s /usr/lib/systemd/system/NetworkManager.service /etc/systemd/system/multi-user.target.wants/NetworkManager.service
ln -s /usr/lib/systemd/system/NetworkManager-dispatcher.service /etc/systemd/system/dbus-org.freedesktop.nm-dispatcher.service

ekho "Setting keyserver options"
sed -i 's@keyserver hkp.*@keyserver hkps://hkps.pool.sks-keyservers.net:443@' /etc/pacman.d/gnupg/gpg.conf
sed -i 's@keyserver-options@keyserver-options auto-key-retrieve@' /etc/pacman.d/gnupg/gpg.conf
ENDPHASE3

chmod +x /mnt/phase3.sh

ekho "Entering arch-chroot to run /phase3.sh"
arch-chroot /mnt /phase3.sh

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
