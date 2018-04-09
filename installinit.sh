#!/usr/bin/env zsh
DRIVE=/dev/$(lsblk | awk '/disk/{print $1}' | sort -u | head -1)
MYHOSTNAME=raxnuc
printf -v SWAPSIZE %.0f $(($(awk '/MemTotal/{print $2}' /proc/meminfo) * 1.5 / 1000000))
echo "Swap will be ${SWAPSIZE}GiB"
echo
echo "Zapping ${DRIVE}..."
sgdisk --zap-all ${DRIVE}
echo "Creating partitions on ${DRIVE}"
sgdisk --clear \
       --new=1:0:+550MiB         --typecode=1:ef00 --change-name=1:EFI \
       --new=2:0:+${SWAPSIZE}GiB --typecode=2:8200 --change-name=2:cryptswp \
       --new=3:0:0               --typecode=2:8300 --change-name=3:cryptsys \
         ${DRIVE}
echo "Making EFI filesystem"
mkfs.fat -F32 -n EFI /dev/disk/by-partlabel/EFI
echo "Creating LUKS partition for system"
cryptsetup luksFormat --align-payload=8192 -s 256 -c aes-xts-plain64 /dev/disk/by-partlabel/cryptsys
echo "Opening LUKS partition for system"
cryptsetup open /dev/disk/by-partlabel/cryptsys system
echo "Opening LUKS partition for swap"
cryptsetup open --type plain --key-file /dev/random /dev/disk/by-partlabel/cryptswp swap
echo "Initializing swap on /dev/mapper/swap"
mkswap -L swap /dev/mapper/swap
echo "Engaging swap"
swapon -L swap
echo "Creating BTRFS filesystem on /dev/mapper/system"
mkfs.btrfs --force --label system /dev/mapper/system

DEFAULT_OPTS=defaults,x-mount.mkdir

BTRFS_OPTS=${DEFAULT_OPTS},compress=lzo,ssd,noatime
echo "Mounting BTRFS filesystem on /mnt"
mount -t btrfs LABEL=system /mnt
echo "Creating subvolume for root"
btrfs subvolume create /mnt/@
echo "Creating subvolume for /home"
btrfs subvolume create /mnt/@home
echo "Creating subvolume for /.snapshots"
btrfs subvolume create /mnt/@snapshots
echo "Unmounting /mnt system"
umount -R /mnt
echo "Remounting root subvolume"
mount -t btrfs -o subvol=@,${BTRFS_OPTS} LABEL=system /mnt
echo "Remounting /home subvolume"
mount -t btrfs -o subvol=@home,${BTRFS_OPTS} LABEL=system /mnt/home
echo "Remounting /.snapshots subvolume"
mount -t btrfs -o subvol=@snapshots,${BTRFS_OPTS} LABEL=system /mnt/.snapshots
echo "Creating /boot"
mkdir /mnt/boot
echo "Mounting EFI partition on /boot"
mount -t vfat LABEL=EFI /mnt/boot
echo "Backing up pacman mirrorlist"
mv /etc/pacman.d/mirrorlist{,.backup}
echo "Ranking pacman mirrors"
rankmirrors -n 5 /etc/pacman.d/mirrorlist.backup > /etc/pacman.d/mirrorlist.ranked
echo "Creating new mirrorlist"
head -6 /etc/pacman.d/mirrorlist.ranked > /etc/pacman.d/mirrorlist
echo 'Server = https://mirror.rackspace.com/archlinux/$repo/os/$arch' >> /etc/pacman.d/mirrorlist
tail -5 /etc/pacman.d/mirrorlist.ranked | grep -v rackspace >> /etc/pacman.d/mirrorlist
echo "Created:"
cat /etc/pacman.d/mirrorlist
echo "Cleaning up ranked list"
rm -f /etc/pacman.d/mirrorlist.ranked
echo "Running pacstrap"
pacstrap /mnt btrfs-progs networkmanager ansible base
echo "Generating fstab"
genfstab -L -p /mnt >> /mnt/etc/fstab
echo "Fixing swap partition"
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

echo "Enter systemd shell and run /phase2.sh"
systemd-nspawn -b -E MYHOSTNAME=${MYHOSTNAME} -D /mnt

## Phase 3
cat <<'ENDPHASE3' > /mnt/phase3.sh
#!/usr/bin/env bash
echo "Adding sudo group"
groupadd -g 100 sudo
echo "Adding stephen user"
useradd -m -c "Stephen Brown II" -u 1000 -U -G sudo -s /usr/bin/zsh stephen
echo "Set stephen's password"
passwd stephen
echo "Adding stephen to sudoers.d"
mkdir /etc/sudoers.d
echo 'stephen ALL=(ALL) ALL' > /etc/sudoers.d/stephen
echo "Installing base-devel and other useful utilities"
pacman -Syu --needed base-devel gptfdisk zsh vim terminus-font intel-ucode git
echo "Configuring /etc/mkinitcpio.conf"
sed -i -e 's/^MODULES=.*/MODULES=(i915)/' /etc/mkinitcpio.conf
sed -i -e 's/^HOOKS=/#HOOKS=/' /etc/mkinitcpio.conf
sed -i -e '/#HOOKS=/a HOOKS=(base systemd sd-vconsole autodetect modconf keyboard block filesystems btrfs sd-encrypt fsck)' /etc/mkinitcpio.conf
grep -v '^#' /etc/mkinitcpio.conf
echo "Setting vconsole font"
cat <<EOF >> /etc/vconsole.conf
FONT=Lat2-Terminus16
EOF
echo "Installing systemd-boot in /boot"
bootctl --path=/boot install
echo "Adding cryptsys to /etc/crypttab for initramfs"
cat <<EOF >> /etc/crypttab.initramfs
# <name>  <device>                           <password>    <options>
system    /dev/disk/by-partlabel/cryptsys
EOF
echo "Adding cryptswp to /etc/crypttab"
awk -v p=/dev/disk/by-partlabel/cryptswp '/# swap/{print $2"    "p"    "$4"    "$5}' /etc/crypttab >> /etc/crypttab
echo "Setting bootloader settings"
cat <<EOF > /boot/loader/loader.conf
default arch
timeout 15
editor 0
EOF
echo "Creating arch bootloader entry"
cat <<EOF >> /boot/loader/entries/arch.conf
title Arch Linux
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options luks.allow-discards root=/dev/mapper/system rootflags=subvol=@ rw
EOF
echo "Installing yay from AUR using git as stephen"
su - stephen -c 'git clone https://aur.archlinux.org/yay.git ~/yay; cd ~/yay; makepkg -fsri; cd ~; rm -rf yay'
echo "Installing more things including AUR packages"
su - stephen -c 'yay -Syu sddm cinnamon arc-gtk-theme arc-icon-theme paper-icon-theme noto-fonts-emoji ttf-ubuntu-font-family otf-montserrat nerd-fonts-complete kitty aic94xx-firmware wd719x-firmware grml-zsh-config'
echo "Fixing Arc icon theme inheritence"
sed -i -e 's/Inherits=Moka/Inherits=Paper/' /usr/share/icons/Arc/index.theme
echo "Setting Cinnamon DE dconf icons keyfile"
cat <<EOF >> /etc/dconf/db/user.d/icons.txt
[/org/cinnamon/desktop/interface]
cursor-theme='Paper'
icon-theme='Arc'
gtk-theme='Arc-Dark'
[/org/cinnamon/desktop/wm/preferences]
theme='Arc-Dark'
[/org/cinnamon/theme]
name='Arc-Dark'
EOF
echo "Setting Cinnamon DE dconf fonts keyfile"
cat <<EOF >> /etc/dconf/db/user.d/fonts.txt
[/org/cinnamon/desktop/interface]
font-name='Montserrat Light 9'
[/org/cinnamon/desktop/wm/preferences]
titlebar-font='Montserrat 10'
[/org/gnome/desktop/interface]
document-font-name='Montserrat 11'
monospace-font-name='FantasqueSansMono Nerd Font 11'
[/org/nemo/desktop]
font='Montserrat Light 10'
EOF
echo "Enabling sddm without systemd"
ln -s /usr/lib/systemd/system/sddm.service /etc/systemd/system/display-manager.service
echo "Running mkinitcpio"
mkinitcpio -p linux
ENDPHASE3

chmod +x /mnt/phase3.sh
echo "Enter arch-chroot and run /phase3.sh"
arch-chroot /mnt /phase3.sh
echo "Unmounting /mnt"
umount -R /mnt
echo "Rebooting in 15 seconds..."
sleep 15
reboot
