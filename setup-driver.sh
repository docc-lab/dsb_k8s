#!/bin/sh

set -x

if [ -z "$EUID" ]; then
    EUID=`id -u`
fi
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

ALLNODESCRIPTS="setup-root-ssh.sh setup-disk-space.sh"
HEADNODESCRIPTS="setup-letsencrypt.sh setup-nginx.sh setup-kubespray.sh setup-cord.sh setup-comac.sh"

export SRC=`dirname $0`
cd $SRC
. $SRC/setup-lib.sh

# Don't run setup-driver.sh twice
if [ -f $OURDIR/setup-driver-done ]; then
    echo "setup-driver already ran; not running again"
    exit 0
fi
for script in $ALLNODESCRIPTS ; do
    cd $SRC
    $SRC/$script | tee - $OURDIR/${script}.log 2>&1
done
if [ "$HOSTNAME" = "node-0" ]; then
    for script in $HEADNODESCRIPTS ; do
	cd $SRC
	$SRC/$script | tee - $OURDIR/${script}.log 2>&1
    done
fi

exit 0
