systemctl start dhcpcd@<tab>

DRIVE=/dev/DRIVEID
HOSTNAME=myhostname
let SWAPSIZE="$(awk '/MemTotal/{print $2}' /proc/meminfo) * 1.5 / 1000000"

sgdisk --zap-all ${DRIVE}

sgdisk --clear \
       --new=1:0:+550MiB         --typecode=1:ef00 --change-name=1:EFI \
       --new=2:0:+${SWAPSIZE}GiB --typecode=2:8200 --change-name=2:cryptswp \
       --new=3:0:0               --typecode=2:8300 --change-name=3:cryptsys \
         ${DRIVE}

EFI_UUID=$(ls -l /dev/disk/by-uuid | awk '/'$(ls -l /dev/disk/by-partlabel/EFI | awk -F/ '{print $NF}')'/{print $(NF-2)}')
SWP_UUID=$(ls -l /dev/disk/by-uuid | awk '/'$(ls -l /dev/disk/by-partlabel/cryptswp | awk -F/ '{print $NF}')'/{print $(NF-2)}')
SYS_UUID=$(ls -l /dev/disk/by-uuid | awk '/'$(ls -l /dev/disk/by-partlabel/cryptsys | awk -F/ '{print $NF}')'/{print $(NF-2)}')

mkfs.fat -F32 -n EFI /dev/disk/by-partlabel/EFI

cryptsetup luksFormat --align-payload=8192 -s 256 -c aes-xts-plain64 /dev/disk/by-partlabel/cryptsys

cryptsetup open /dev/disk/by-partlabel/cryptsys system

cryptsetup open --type plain --key-file /dev/random /dev/disk/by-partlabel/cryptswp swap

mkswap -L swap /dev/mapper/swap

swapon -L swap

mkfs.btrfs --force --label system /dev/mapper/system

DEFAULT_OPTS=defaults,x-mount.mkdir

BTRFS_OPTS=${DEFAULT_OPTS},compress=lzo,ssd,noatime

mount -t btrfs LABEL=system /mnt

btrfs subvolume create /mnt/@

btrfs subvolume create /mnt/@home

btrfs subvolume create /mnt/@snapshots

umount -R /mnt

mount -t btrfs -o subvol=@,${BTRFS_OPTS} LABEL=system /mnt

mount -t btrfs -o subvol=@home,${BTRFS_OPTS} LABEL=system /mnt/home

mount -t btrfs -o subvol=@snapshots,${BTRFS_OPTS} LABEL=system /mnt/.snapshots

mv /etc/pacman.d/mirrorlist{,.backup}

rankmirrors -n6 /etc/pacman.d/mirrorlist.backup > /etc/pacman.d/mirrorlist.ranked

head -n6 /etc/pacman.d/mirrorlist.ranked > /etc/pacman.d/mirrorlist

tail -n6 /etc/pacman.d/mirrorlist.ranked >> /etc/pacman.d/mirrorlist

rm -f /etc/pacman.d/mirrorlist.ranked

pacstrap /mnt btrfs-progs intel-ucode base

genfstab -U -p /mnt >> /mnt/etc/fstab

systemd-nspawn -bD /mnt
# Login as root

passwd

sed -i 's/^#en_US/en_US/' /etc/locale.gen

locale-gen

localectl set-locale LANG=en_US.UTF-8

timedatectl set-ntp true

timedatectl set-timezone America/Chicago

hostnamectl set-hostname ${HOSTNAME}

echo "127.0.1.1 ${HOSTNAME}.localdomain  ${HOSTNAME}" >> /etc/hosts

cat <<EOF >> /etc/vconsole.conf
FONT=Lat2-Terminus16
EOF

cat <<EOF >> /boot/loader/loader.conf
default arch
timeout 5
editor 0
EOF

cat <<EOF >> /boot/loader/entries/arch.conf
title Arch Linux
linux /vmlinuz-linux
initrd /intel-ucode.img
initrd /initramfs-linux.img
options rd.luks.name=${SYS_UUID}=system luks.name=${SWP_UUID}=swap luks.allow-discards root=/dev/mapper/system rootflags=subvol=@ rw
EOF

sed -i -e 's/^HOOKS=/#HOOKS=/' /etc/mkinitcpio.conf
sed -i -e '/#HOOKS=/a HOOKS=(base systemd autodetect keyboard sd-vconsole modconf block filesystems btrfs sd-encrypt fsck)' /etc/mkinitcpio.conf

useradd -m -c "Stephen Brown II" -u 1000 -U -G sudo -s /usr/bin/zsh stephen

shutdown -h now

systemd-nspawn -bD /mnt
# Login as stephen

passwd

pacman -Syu base-devel haveged gptfdisk zsh vim terminus-font networkmanager ansible git

git clone https://aur.archlinux.org/pikaur.git

cd pikaur

makepkg -fsri

cd ..

rm -rf pikaur

mkdir /home/stephen/.config
cat <<EOF >> /home/stephen/.config/pikaur.conf
[sync]
AlwaysShowPkgOrigin = no
DevelPkgsExpiration = -1

[build]
KeepBuildDir = no

[colors]
Version = 10
VersionDiffOld = 11
VersionDiffNew = 9

[ui]
RequireEnterConfirm = yes
EOF

pikaur -Syu sddm cinnamon

sudo systemctl enable sddm

reboot
