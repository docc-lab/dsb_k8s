#!/bin/sh

set -x

if [ -z "$EUID" ]; then
    EUID=`id -u`
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/nfs-server-done ]; then
    exit 0
fi

logtstart "nfs-server"

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi
if [ -f $LOCALSETTINGS ]; then
    . $LOCALSETTINGS
fi

maybe_install_packages nfs-kernel-server
service_stop nfs-kernel-server

$SUDO mkdir -p $NFSEXPORTDIR
$SUDO chmod 755 $NFSEXPORTDIR

dataip=`getnodeip $HEAD $DATALAN`
prefix=`getnetmaskprefix $DATALAN`
networkip=`getnetworkip $HEAD $DATALAN`

syncopt="sync"
if [ -n "$NFSASYNC" -a $NFSASYNC -eq 1 ]; then
    syncopt="async"
fi
echo "$NFSEXPORTDIR $networkip/$prefix(rw,$syncopt,no_root_squash,no_subtree_check,fsid=0)" | $SUDO tee -a /etc/exports

echo "OPTIONS=\"-l -h 127.0.0.1 -h $dataip\"" | $SUDO tee /etc/default/rpcbind
$SUDO sed -i.bak -e "s/^rpcbind/#rpcbind/" /etc/hosts.deny
echo "rpcbind: ALL EXCEPT 127.0.0.1, $networkip/$prefix" | $SUDO tee -a /etc/hosts.deny

service_enable rpcbind
service_restart rpcbind
service_enable rpc-statd
service_restart rpc-statd
service_enable nfs-idmapd
service_restart nfs-idmapd
service_enable nfs-kernel-server
service_restart nfs-kernel-server

$SUDO mkdir -p $NFSMOUNTDIR
$SUDO chmod 755 $NFSMOUNTDIR
echo "$NFSEXPORTDIR $NFSMOUNTDIR none defaults,bind 0 0" | $SUDO tee -a /etc/fstab
$SUDO mount $NFSMOUNTDIR

logtend "nfs-server"

touch $OURDIR/nfs-server-done
