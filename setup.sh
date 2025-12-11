#!/bin/sh

### Precursor ###
# - Prepare the server's network before you can download and run this script
# setup-interfaces -ra && echo 'nameserver 8.8.8.8' >> /etc/resolv.conf && setup-apkrepos -f [87] && apk add curl

# - Download and run the script:
# /bin/sh -c "$(curl -fsSL http://1.1.1.2:3000)"

# ! REMEMBER !
# After the installation is complete you should set your SSH keys and reconfigure OpenSSH
# /etc/ssh/sshd_config
#   PermitRootLogin without-password
#   PasswordAuthentication no


#####################################################
############### Modify per your needs ###############
#####################################################

# If empty you will be asked interactively (safer, maybe?)
ROOT_PASSWORD="123";

DRIVES="/dev/sda /dev/sdb";

# Use software RAID < 0 | 1 >
SWRAID=1;
# RAID level < 0 | 1 | 10 >
SWRAIDLEVEL=1;

HOSTNAME="localhost";
TIMEZONE="Europe/Sofia"; # UTC is recommended

PARTITIONS="
PART /boot vfat 512M
PART /vm ext4 2G		# Data partition: The place where you store main data
PART /backup ext4 2G	# Use same fs like Data and at least the same size
PART swap swap 1G		# 1/2 of RAM, 1:1 RAM, or 2/1 of RAM
PART / ext4 all			# Define as last in order to occupy all remaining space
"

# RAM to be allocated for /tmp
TMP_SIZE="1G"; # leave empty ("") if not needed

EXTRA_PACKAGES="wget sgdisk wipefs parted mdadm e2fsprogs dosfstools rsync sfdisk grub-efi efibootmgr";
OS_PACKAGES="nano openssh chrony";








#####################################################
#----------- Do not edit below this line ------------
#####################################################

set -e;

SEP="\n------------------------------------------------------------\n";

ROOT_PART="";
ROOT_FS="";
export BOOTLOADER=grub;
export USE_EFI=1;


echo -e "=== Configuration summary ===\n"
if [ "$SWRAID" = "1" ]; then
	echo -e "RAID $SWRAIDLEVEL array"
	for d in $DRIVES; do printf "\t- %s\n" "$d"; done
else
	echo "\tDrive: $(echo "$DRIVES" | awk '{print $1}') only  (no RAID)"
fi
echo -e "\n\n - Hostname: "$HOSTNAME
echo " - Timezone: "$TIMEZONE
echo " - Extra packages: "$EXTRA_PACKAGES
echo -e "\n-----------------------------------"
echo "Partitions :"
echo "$PARTITIONS" | sed 's/^/  /'
echo -e "-----------------------------------\n"
echo "If something needs changing, exit, edit the variables in the script and re-run it."
read -p "    Do you wish to continue (y/n)?" answer
if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
	echo "Aborted by user."
	exit 1
fi


apk add $EXTRA_PACKAGES;

setup-keymap us us;

# Preparing drives for installation

if [ "$SWRAID" = "1" ]; then
	USED_DRIVES="$DRIVES";
	N_DRIVES=0;
	for _ in $USED_DRIVES; do N_DRIVES=$((N_DRIVES + 1)); done
else
	USED_DRIVES=$(echo "$DRIVES" | awk '{print $1}')
fi

# Detect boot mode (UEFI or BIOS)
if [ -d /sys/firmware/efi ]; then
    BOOT_MODE="uefi";
else
    BOOT_MODE="bios";
fi

# Stop any old RAID arrays that might be running
mdadm --stop --scan 2>/dev/null || true;

# Wiping signatures & removing partitions
for d in $USED_DRIVES; do
	wipefs -af "$d";
	sync
	dd if=/dev/zero of="$d" bs=1M count=10;
	partprobe "$d";
done

echo -e $SEP" -- Drives Wiped -- "$SEP

# Create temporary file with only the PART lines
tmp_partlist=$(mktemp)
grep '^PART ' > "$tmp_partlist" <<EOF
$PARTITIONS
EOF

# Apply to all drives
for d in $USED_DRIVES; do
	sgdisk -Z $d; # Wipe the disk
	pnum=1
	while read -r _ mp fs sz rest; do
		if [ "$mp" = "/boot" ]; then
			echo -n "Formatting /boot ... " && sgdisk -n$pnum:1M:+$sz -t$pnum:FD00 -c $pnum:"/boot" $d
		elif [ "$sz" = "all" ];then
			echo -n "Formatting $mp ... " && sgdisk -n$pnum:0:0 -t$pnum:FD00 -c $pnum:"$mp" $d
		else
			echo -n "Formatting $mp ... " && sgdisk -n$pnum:0:+$sz -t$pnum:FD00 -c $pnum:"$mp" $d
        fi

		eval "MOUNTPOINT_$pnum=\"$mp\""
		eval "FSTYPE_$pnum=\"$fs\""
		pnum=$((pnum + 1))
	done < "$tmp_partlist"

	sgdisk -G $d; # Ensure GPT partition table
	sync
	partprobe "$d"
done
# sgdisk $d --attributes=1:set:$pnum
sleep 1
mdev -s
sync

# Remove the temporary file
rm -f "$tmp_partlist"

mdadm --stop /dev/md* 2>/dev/null || true

# Re-detect the drives that actually have the partitions we just created
if [ "$SWRAID" = "1" ]; then
	DRIVES_TO_USE=""
	for d in $DRIVES; do
		if [ -b "${d}2" ]; then
			DRIVES_TO_USE="${DRIVES_TO_USE:+$DRIVES_TO_USE }$d"
		fi
	done
else
	DRIVES_TO_USE="$DRIVES"
fi
N_DRIVES=$(echo "$DRIVES_TO_USE" | wc -w | tr -d ' ')


array_idx=0
p=1
while [ "$p" -lt "$pnum" ]; do
	parts_list="";
	set -- $DRIVES_TO_USE;

	while [ $# -gt 0 ]; do
		drive="$1";
		part_num=$((p + 1));

		case "$drive" in
			*nvme*|*mmc*)
				this_part="${drive}p${part_num}";
				;;
			*)
				this_part="${drive}${part_num}";
				;;
		esac

		parts_list="${parts_list:+$parts_list }$this_part"
		shift
	done

	mp=$(eval echo "\$MOUNTPOINT_$p");
	fs=$(eval echo "\$FSTYPE_$p");

	label="$mp";
	[ "$mp" = "/" ] && label="/" && ROOT_FS="$fs";
	[ "$mp" = "swap" ] && label="[SWAP]";
	[ "$mp" = "/boot" ] && label="boot";

	if [ "$SWRAID" = "1" ]; then
		device="/dev/md${array_idx}";
		metadata="1.2";
		# The usage of metadata 1.0 is MANDATORY for the /boot EFI partition and for the SWAP partition
		[ "$fs" = "vfat" -o "$fs" = "swap" ] && metadata="1.0";

		echo "Creating RAID $SWRAIDLEVEL $device → $mp ($fs)"

		parts_list="";
		for drive in $DRIVES; do
			part="${drive}$((p + 0))";
			[ -b "$part" ] || { echo "FATAL: partition $part missing!"; exit 1; };
			parts_list="$parts_list $part";
		done

		parts_list=$(echo "$parts_list" | sed 's/^ //');

		yes | mdadm --create "$device" \
			--level="$SWRAIDLEVEL" \
			--raid-devices="$N_DRIVES" \
			--metadata="$metadata" \
			--assume-clean \
			$parts_list || { echo "mdadm failed on $device"; exit 1; }

		array_idx=$((array_idx + 1))
	else
		device=$(echo "$parts_list" | awk '{print $1}')
		echo "Using single partition $device → $mp ($fs)"
	fi

	eval "DEVICE_$p=\"$device\""

	if [ "$fs" != "tmpfs" ]; then
		echo "Formatting $device → $fs (label=$label)"
		case "$fs" in
			swap) mkswap -L "$label" "$device" ;;
			ext2) mkfs.ext2 -F -m 1 -L "$label" "$device" ;;
			ext4) mkfs.ext4 -F -L "$label" "$device" ;;
			vfat) mkfs.vfat -F 32 -n "$label" "$device" ;;
		esac

		# Map the ROOT and BOOT EFI partitions to the corresponding /dev/md$ devices
		[ "$mp" = "/" ] && ROOT_PART="$device";
		[ "$mp" = "/boot" ] && efipart="$device";
	fi
echo && echo
	p=$((p + 1))
done

# mdadm.conf for the installed system
if [ "$SWRAID" = "1" ]; then
	echo "Generating /etc/mdadm.conf ..."
	mdadm --examine --scan > /etc/mdadm.conf
fi

sync

echo -e $SEP$SEP"=== Mounting filesystems ===\n";

NUM_REAL_PARTS=0;
while eval [ -n \"\$MOUNTPOINT_$((NUM_REAL_PARTS + 1))\" ] 2>/dev/null; do
	NUM_REAL_PARTS=$((NUM_REAL_PARTS + 1));
done

# Mount the root partition
mount -t "$ROOT_FS" "$ROOT_PART" /mnt;

# Mount partitions
for p in $(seq 1 $NUM_REAL_PARTS); do
	mp=$(eval echo "\$MOUNTPOINT_$p")
	fs=$(eval echo "\$FSTYPE_$p")
	dev=$(eval echo "\$DEVICE_$p")

	[ "$mp" = "/" ] && continue
	[ "$fs" = "tmpfs" ] && continue
	[ "$mp" = "swap" ] && { swapon "$dev"; continue; }
	if [ "$mp" = "/boot" ] && [ "$BOOT_MODE" = "uefi" ];then
		mkdir -p /mnt/boot/efi;
		mount -t vfat "$efipart" /mnt/boot/efi;
		continue;
	fi

	mkdir -p "/mnt$mp"
	mount -t "$fs" "$dev" "/mnt$mp"
done


echo -e $SEP$SEP"=== Installing Alpine ... ===\n";
setup-disk -m sys /mnt <<EOF
y
EOF

echo "$HOSTNAME" > /mnt/etc/hostname
echo "$TIMEZONE" > /mnt/etc/timezone
echo raid1 > /mnt/etc/modules-load.d/raid1.conf

chroot /mnt setup-timezone -z "$TIMEZONE"

# Set the root password
[ -z "$ROOT_PASSWORD" ] && read -sp "Set root password: " ROOT_PASSWORD && echo
[ -n "$ROOT_PASSWORD" ] && echo "root:$ROOT_PASSWORD" | chroot /mnt chpasswd


[ "$SWRAID" = "1" ] && cp /etc/mdadm.conf /mnt/etc/mdadm.conf

echo -e $SEP$SEP"=== Generating dynamic /etc/fstab ... ===\n";

# Add the swap partition
echo `blkid | grep -i swap | grep -v '/dev/sd' | awk '{print $3}' | sed 's/"//g' | awk '{print $1 "\t none \t swap \t sw \t 0 0"}'` >> /mnt/etc/fstab

# Add the /tmp partition
if [ -n "$TMP_SIZE" ]; then
    echo "tmpfs /tmp tmpfs defaults,noatime,mode=1777,size=$TMP_SIZE 0 0" >> /mnt/etc/fstab
fi

echo -e $SEP$SEP"=== Installing OS packages ... ===\n";

# INSTALL ADDITIONAL PACKAGES FOR THE OS
chroot /mnt apk add $OS_PACKAGES

chroot /mnt rc-update add mdadm boot 2>/dev/null || true
chroot /mnt rc-update add swap
chroot /mnt rc-update add sshd default
chroot /mnt rc-update add chronyd default


# Configure SSHd to allow password authentication
sed -i '/^#PermitRootLogin/s/^#PermitRootLogin.*/PermitRootLogin yes/' /mnt/etc/ssh/sshd_config
sed -i '/^#PasswordAuthentication/s/^#PasswordAuthentication.*/PasswordAuthentication yes/' /mnt/etc/ssh/sshd_config

# Unmount all partitions
swapoff -a;
for i in `df -h | grep '/mnt' | awk '{print $6}' | sort -r`;do umount $i;done

echo -e "\n\n\n\n\n\n"$SEP$SEP$SEP" Alpine installation completed successfully !!!\n\n\nRebooting in 10 seconds ...";
reboot -d 10;