#!/bin/sh

set -x

if [ -z "$EUID" ]; then
    EUID=`id -u`
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/nfs-client-done ]; then
    exit 0
fi

logtstart "nfs-client"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi
if [ -f $LOCALSETTINGS ]; then
    . $LOCALSETTINGS
fi

if [ -z "$DONFS" -o ! "$DONFS" = "1" ]; then
    exit 0
fi

maybe_install_packages nfs-common
service_enable rpcbind
service_start rpcbind

dataip=`getnodeip $HEAD $DATALAN`
prefix=`getnetmaskprefix $DATALAN`

while ! (rpcinfo -s $dataip | grep -q nfs); do
    echo "Waiting for NFS server $dataip..."
    sleep 10
done

$SUDO mkdir -p $NFSMOUNTDIR
$SUDO chmod 755 $NFSMOUNTDIR
echo "$dataip:$NFSEXPORTDIR $NFSMOUNTDIR nfs rw,bg,sync,hard,intr 0 0" | $SUDO tee -a /etc/fstab
while ! $SUDO mount $NFSMOUNTDIR ; do
    echo "Mounting $dataip:$NFSEXPORTDIR..."
    sleep 10
done

logtend "nfs-client"

touch $OURDIR/nfs-client-done
