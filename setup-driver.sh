#!/bin/sh

set -x

ALLNODESCRIPTS="setup-ssh.sh setup-disk-space.sh"
HEADNODESCRIPTS="setup-nginx.sh setup-ssl.sh setup-kubespray.sh setup-kubernetes-extra.sh setup-end.sh"

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
