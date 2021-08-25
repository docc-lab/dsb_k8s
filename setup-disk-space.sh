
##
## Setup extra space.  We prefer the LVM route, using all available PVs
## to create a big VG.  If that's not available, we fall back to
## mkextrafs.pl to create whatever it can in /storage.
##

set -x

if [ -z "$EUID" ]; then
    EUID=`id -u`
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/disk-space-done ]; then
    exit 0
fi

logtstart "disk-space"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi
if [ -f $LOCALSETTINGS ]; then
    . $LOCALSETTINGS
fi

VGNAME="emulab"
ARCH=`uname -m`

maybe_install_packages lvm2 maybe_install_packages thin-provisioning-tools

#
# First try to make LVM volumes; fall back to mkextrafs.pl /storage.  We
# use /storage later, so we make the dir either way.
#
$SUDO mkdir -p ${STORAGEDIR}
echo "STORAGEDIR=${STORAGEDIR}" >> $LOCALSETTINGS
# Check to see if we already have an `emulab` VG.  This would occur
# if the user requested a temp dataset.  If this happens, we simple
# rename it to the VG name we expect.
$SUDO vgdisplay emulab
if [ $? -eq 0 ]; then
    if [ ! emulab = $VGNAME ]; then
	$SUDO vgrename emulab $VGNAME
	$SUDO sed -i -re "s/^(.*)(\/dev\/emulab)(.*)$/\1\/dev\/$VGNAME\3/" /etc/fstab
    fi
    LVM=1
    echo "VGNAME=${VGNAME}" >> $LOCALSETTINGS
    echo "LVM=1" >> $LOCALSETTINGS
elif [ -z "$LVM" ] ; then
    LVM=1
    DONE=0

    #
    # Handle unexpected partition layouts (e.g. no 4th partition on boot
    # disk), and setup mkextrafs args, even if we're not going to use
    # it.
    #
    MKEXTRAFS_ARGS="-l -v ${VGNAME} -m util -z 1024"
    # On Cloudlab ARM machines, there is no second disk nor extra disk space
    # Well, now there's a new partition layout; try it.
    if [ "$ARCH" = "aarch64" -o "$ARCH" = "ppc64le" ]; then
	maybe_install_packages gdisk
	$SUDO sgdisk -i 1 /dev/sda
	if [ $? -eq 0 ] ; then
	    nparts=`sgdisk -p /dev/sda | grep -E '^ +[0-9]+ +.*$' | wc -l`
	    if [ $nparts -lt 4 ]; then
		newpart=`expr $nparts + 1`
		$SUDO sgdisk -N $newpart /dev/sda
		$SUDO partprobe /dev/sda
		if [ $? -eq 0 ] ; then
		    $SUDO partprobe /dev/sda
		    # Add the new partition specifically
		    MKEXTRAFS_ARGS="${MKEXTRAFS_ARGS} -s $newpart"
		fi
	    fi
	fi
    fi

    #
    # See if we can try to use an LVM instead of just the 4th partition.
    #
    $SUDO lsblk -n -P -b -o NAME,FSTYPE,MOUNTPOINT,PARTTYPE,PARTUUID,TYPE,PKNAME,SIZE | perl -e 'my %devs = (); while (<STDIN>) { $_ =~ s/([A-Z0-9a-z]+=)/;\$$1/g; eval "$_"; if (!($TYPE eq "disk" || $TYPE eq "part")) { next; }; if (exists($devs{$PKNAME})) { delete $devs{$PKNAME}; } if ($FSTYPE eq "" && $MOUNTPOINT eq "" && ($PARTTYPE eq "" || $PARTTYPE eq "0x0") && (int($SIZE) > 3221225472)) { $devs{$NAME} = "/dev/$NAME"; } }; print join(" ",values(%devs))."\n"' > /tmp/devs
    DEVS=`cat /tmp/devs`
    if [ -n "$DEVS" ]; then
	$SUDO pvcreate $DEVS && $SUDO vgcreate $VGNAME $DEVS
	if [ ! $? -eq 0 ]; then
	    echo "ERROR: failed to create PV/VG with '$DEVS'; falling back to mkextrafs.pl"
	    $SUDO vgremove $VGNAME
	    $SUDO pvremove $DEVS
	    DONE=0
	else
	    DONE=1
	fi
    fi

    if [ $DONE -eq 0 ]; then
	$SUDO /usr/local/etc/emulab/mkextrafs.pl ${MKEXTRAFS_ARGS}
	if [ $? -ne 0 ]; then
	    $SUDO /usr/local/etc/emulab/mkextrafs.pl ${MKEXTRAFS_ARGS} -f
	    if [ $? -ne 0 ]; then
		$SUDO /usr/local/etc/emulab/mkextrafs.pl -f ${STORAGEDIR}
		LVM=0
	    fi
	fi
    fi

    # Get integer total space (G) available.
    VGTOTAL=`$SUDO vgs -o vg_size --noheadings --units G $VGNAME | sed -ne 's/ *\([0-9]*\)[0-9\.]*G/\1/p'`
    echo "VGNAME=${VGNAME}" >> $LOCALSETTINGS
    echo "VGTOTAL=${VGTOTAL}" >> $LOCALSETTINGS
    echo "LVM=${LVM}" >> $LOCALSETTINGS
fi

#
# If using LVM, create an LV that is 70% of VGTOTAL.
#
if [ $LVM -eq 1 ]; then
    LVNAME=k8s
    echo "LVNAME=${LVNAME}" >> $LOCALSETTINGS
    vgt=`expr $VGTOTAL - 1`
    LV_SIZE=`perl -e "print 0.75 * $vgt;"`
    echo "LV_SIZE=${LV_SIZE}" >> $LOCALSETTINGS

    #$SUDO lvcreate -l 75%FREE -n $LVNAME $VGNAME
    $SUDO lvcreate -L ${LV_SIZE}G -n $LVNAME $VGNAME

    if [ -f /sbin/mkfs.ext4 ]; then
	$SUDO mkfs.ext4 /dev/$VGNAME/$LVNAME
	echo "/dev/$VGNAME/$LVNAME ${STORAGEDIR} ext4 defaults 0 0" \
	    | $SUDO tee -a /etc/fstab
    else
	$SUDO mkfs.ext3 /dev/$VGNAME/$LVNAME
	echo "/dev/$VGNAME/$LVNAME ${STORAGEDIR} ext3 defaults 0 0" \
	    | $SUDO tee -a /etc/fstab
    fi
    $SUDO mount ${STORAGEDIR}
fi

#
# Redirect some Docker/k8s dirs into our extra storage.
#
for dir in docker kubelet ; do
    $SUDO mkdir -p $STORAGEDIR/$dir /var/lib/$dir
    $SUDO mount -o bind $STORAGEDIR/$dir /var/lib/$dir
    echo "$STORAGEDIR/$dir /var/lib/$dir none defaults,bind 0 0" \
        | $SUDO tee -a /etc/fstab
done

logtend "disk-space"
touch $OURDIR/disk-space-done
