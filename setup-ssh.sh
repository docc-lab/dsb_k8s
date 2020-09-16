#!/bin/sh

##
## Setup a ssh key on the calling node *for the calling uid*, and
## broadcast it to all the other nodes' authorized_keys file.
##

set -x

if [ -z "$EUID" ]; then
    EUID=`id -u`
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/setup-ssh-$EUID-done ]; then
    echo "setup-ssh-$EUID already ran; not running again"
    exit 0
fi

logtstart "ssh-$EUID"

sshkeyscan() {
    #
    # Run ssh-keyscan on all nodes to build known_hosts.
    #
    ssh-keyscan $NODES >> ~/.ssh/known_hosts
    chmod 600 ~/.ssh/known_hosts
    for node in $NODES ; do
	fqdn=`getfqdn $node`
	publicip=`dig +noall +answer $fqdn A | sed -ne 's/^.*IN[ \t]*A[ \t]*\([0-9\.]*\)$/\1/p'`
	mgmtip=`getnodeip $node $MGMTLAN`
	echo "$publicip $fqdn,$publicip"
	echo "$mgmtip $node,$node-$MGMTLAN,$mgmtip"
    done | ssh-keyscan -4 -f - >> ~/.ssh/known_hosts
}

KEYNAME=id_rsa

# Remove it if it exists...
rm -f ~/.ssh/${KEYNAME} ~/.ssh/${KEYNAME}.pub

##
## Figure out our strategy.  Are we using the new geni_certificate and
## geni_key support to generate the same keypair on each host, or not.
##
geni-get key > $OURDIR/$KEYNAME
chmod 600 $OURDIR/${KEYNAME}
if [ -s $OURDIR/${KEYNAME} ] ; then
    ssh-keygen -f $OURDIR/${KEYNAME} -y > $OURDIR/${KEYNAME}.pub
    chmod 600 $OURDIR/${KEYNAME}.pub
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    cp -p $OURDIR/${KEYNAME} $OURDIR/${KEYNAME}.pub ~/.ssh/
    ps axwww > $OURDIR/ps.txt
    cat $OURDIR/${KEYNAME}.pub >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    sshkeyscan
    logtend "ssh-$EUID"
    touch $OURDIR/setup-ssh-$EUID-done
    exit 0
fi

##
## If geni calls are not available, make ourself a keypair; this gets copied
## to other roots' authorized_keys.
##
if [ ! -f ~/.ssh/${KEYNAME} ]; then
    ssh-keygen -t rsa -f ~/.ssh/${KEYNAME} -N ''
fi

if [ -f $SETTINGS ]; then
    . $SETTINGS
fi

if [ $GENIUSER -eq 1 ]; then
    SHAREDIR=/proj/$EPID/exp/$EEID/tmp

    $SUDO mkdir -p $SHAREDIR
    $SUDO chown $EUID $SHAREDIR

    cp ~/.ssh/${KEYNAME}.pub $SHAREDIR/$HOSTNAME

    for node in $NODES ; do
	while [ ! -f $SHAREDIR/$node ]; do
            sleep 1
	done
	echo $node is up
	cat $SHAREDIR/$node >> ~/.ssh/authorized_keys
    done
else
    for node in $NODES ; do
	if [ "$node" != "$HOSTNAME" ]; then 
	    fqdn=`getfqdn $node`
	    SUCCESS=1
	    while [ $SUCCESS -ne 0 ]; do
		su -c "$SSH  -l $SWAPPER $fqdn sudo tee -a ~/.ssh/authorized_keys" $SWAPPER < ~/.ssh/${KEYNAME}.pub
		SUCCESS=$?
		sleep 1
	    done
	fi
    done
fi

sshkeyscan

logtend "ssh-$EUID"

touch $OURDIR/setup-ssh-$EUID-done

exit 0
