#!/bin/sh

DIRNAME=`dirname $0`

#
# Setup our core vars
#
OURDIR=/local/setup
WWWPRIV=$OURDIR
WWWPUB=/local/profile-public
SETTINGS=$OURDIR/settings
LOCALSETTINGS=$OURDIR/settings.local
TOPOMAP=$OURDIR/topomap
BOOTDIR=/var/emulab/boot
TMCC=/usr/local/etc/emulab/tmcc
SWAPPER=`geni-get user_urn | cut -f4 -d+`

if [ -z "$EUID" ]; then
    EUID=`id -u`
fi
SUDO=
if [ ! $EUID -eq 0 ] ; then
    SUDO=sudo
fi

[ ! -d $OURDIR ] && ($SUDO mkdir -p $OURDIR && $SUDO chown $SWAPPER $OURDIR)
[ ! -e $SETTINGS ] && touch $SETTINGS
[ ! -e $LOCALSETTINGS ] && touch $LOCALSETTINGS
cd $OURDIR

# Setup time logging stuff early
TIMELOGFILE=$OURDIR/setup-time.log
FIRSTTIME=0
if [ ! -f $OURDIR/setup-lib-first ]; then
    touch $OURDIR/setup-lib-first
    FIRSTTIME=`date +%s`
fi

logtstart() {
    area=$1
    varea=`echo $area | sed -e 's/[^a-zA-Z_0-9]/_/g'`
    stamp=`date +%s`
    date=`date`
    eval "LOGTIMESTART_$varea=$stamp"
    echo "START $area $stamp $date" >> $TIMELOGFILE
}

logtend() {
    area=$1
    #varea=${area//-/_}
    varea=`echo $area | sed -e 's/[^a-zA-Z_0-9]/_/g'`
    stamp=`date +%s`
    date=`date`
    eval "tss=\$LOGTIMESTART_$varea"
    tsres=`expr $stamp - $tss`
    resmin=`perl -e 'print '"$tsres"' / 60.0 . "\n"'`
    echo "END $area $stamp $date" >> $TIMELOGFILE
    echo "TOTAL $area $tsres $resmin" >> $TIMELOGFILE
}

if [ $FIRSTTIME -ne 0 ]; then
    logtstart "libfirsttime"
fi

#LOCKFILE="lockfile -1 -r -1 "
LOCKFILE="lockfile-create --retry 65535 "
RMLOCKFILE="lockfile-remove "
PSWDGEN="openssl rand -hex 10"
SSH="ssh -o StrictHostKeyChecking=no"
SCP="scp -p -o StrictHostKeyChecking=no"

#
# Our default configuration
#
HEAD="node-0"
DO_APT_INSTALL=1
DO_APT_UPGRADE=0
DO_APT_DIST_UPGRADE=0
DO_APT_UPDATE=1
UBUNTUMIRRORHOST=""
UBUNTUMIRRORPATH=""
KUBESPRAYREPO="https://github.com/kubernetes-incubator/kubespray.git"
KUBESPRAYUSEVIRTUALENV=1
KUBESPRAY_VIRTUALENV=kubespray-virtualenv
KUBESPRAYVERSION=release-2.16
DOCKERVERSION=
DOCKEROPTIONS=
KUBEVERSION=
HELMVERSION=
KUBENETWORKPLUGIN="calico"
KUBEENABLEMULTUS=0
KUBEPROXYMODE="ipvs"
KUBEPODSSUBNET="192.168.0.0/17"
KUBESERVICEADDRESSES="192.168.128.0/17"
KUBEDOMETALLB=1
KUBEACCESSIP="mgmt"
KUBEFEATUREGATES="[EphemeralContainers=true]"
KUBELETCUSTOMFLAGS=""
KUBELETMAXPODS=0
KUBEALLWORKERS=0
SSLCERTTYPE="self"
SSLCERTCONFIG="proxy"
MGMTLAN="datalan-1"
DATALAN="datalan-1"
DATALANS="datalan-1"
SINGLENODE_MGMT_IP=10.10.1.1
SINGLENODE_MGMT_NETMASK=255.255.0.0
SINGLENODE_MGMT_NETBITS=16
SINGLENODE_MGMT_CIDR=${SINGLENODE_MGMT_IP}/${SINGLENODE_MGMT_NETBITS}
DOLOCALREGISTRY=1
STORAGEDIR=/storage
DONFS=1
NFSEXPORTDIR=$STORAGEDIR/nfs
NFSMOUNTDIR=/nfs
NFSASYNC=0

#
# We have an 'admin' user that gets a random password that comes in from
# geni-lib/rspec as a hash.
#
ADMIN='admin'
ADMIN_PASS=''
ADMIN_PASS_HASH=''

#
# Setup apt-get to not prompt us
#
if [ ! -e $OURDIR/apt-configured ]; then
    echo "force-confdef" | $SUDO tee -a /etc/dpkg/dpkg.cfg.d/cloudlab
    echo "force-confold" | $SUDO tee -a /etc/dpkg/dpkg.cfg.d/cloudlab
    touch $OURDIR/apt-configured
fi
export DEBIAN_FRONTEND=noninteractive
# -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" 
DPKGOPTS=''
APTGETINSTALLOPTS='-y'
APTGETINSTALL="$SUDO apt-get $DPKGOPTS install $APTGETINSTALLOPTS"
# Don't install/upgrade packages if this is not set
if [ ${DO_APT_INSTALL} -eq 0 ]; then
    APTGETINSTALL="/bin/true ${APTGETINSTALL}"
fi

do_apt_update() {
    if [ ! -f $OURDIR/apt-updated -a "${DO_APT_UPDATE}" = "1" ]; then
	$SUDO apt-get update
	touch $OURDIR/apt-updated
    fi
}

are_packages_installed() {
    retval=1
    while [ ! -z "$1" ] ; do
	dpkg -s "$1" >/dev/null 2>&1
	if [ ! $? -eq 0 ] ; then
	    retval=0
	fi
	shift
    done
    return $retval
}

maybe_install_packages() {
    if [ ! ${DO_APT_UPGRADE} -eq 0 ] ; then
        # Just do an install/upgrade to make sure the package(s) are installed
	# and upgraded; we want to try to upgrade the package.
	$APTGETINSTALL $@
	return $?
    else
	# Ok, check if the package is installed; if it is, don't install.
	# Otherwise, install (and maybe upgrade, due to dependency side effects).
	# Also, optimize so that we try to install or not install all the
	# packages at once if none are installed.
	are_packages_installed $@
	if [ $? -eq 1 ]; then
	    return 0
	fi

	retval=0
	while [ ! -z "$1" ] ; do
	    are_packages_installed $1
	    if [ $? -eq 0 ]; then
		$APTGETINSTALL $1
		retval=`expr $retval \| $?`
	    fi
	    shift
	done
	return $retval
    fi
}

##
## Figure out the system python version.
##
python --version
if [ ! $? -eq 0 ]; then
    python3 --version
    if [ $? -eq 0 ]; then
	PYTHON=python3
    else
	are_packages_installed python3
	success=`expr $? = 0`
	# Keep trying again with updated cache forever;
	# we must have python.
	while [ ! $success -eq 0 ]; do
	    do_apt_update
	    $SUDO apt-get $DPKGOPTS install $APTGETINSTALLOPTS python3
	    success=$?
	done
	PYTHON=python3
    fi
else
    PYTHON=python
fi
$PYTHON --version | grep -q "Python 3"
if [ $? -eq 0 ]; then
    PYVERS=3
    PIP=pip3
else
    PYVERS=2
    PIP=pip
fi
PYTHONBIN=`which $PYTHON`

##
## Grab our geni creds, and create a GENI credential cert
##
are_packages_installed ${PYTHON}-cryptography ${PYTHON}-future \
    ${PYTHON}-six ${PYTHON}-lxml ${PYTHON}-pip
success=`expr $? = 0`
# Keep trying again with updated cache forever;
# we must have this package.
while [ ! $success -eq 0 ]; do
    do_apt_update
    $SUDO apt-get $DPKGOPTS install $APTGETINSTALLOPTS ${PYTHON}-cryptography \
	${PYTHON}-future ${PYTHON}-six ${PYTHON}-lxml ${PYTHON}-pip
    success=$?
done

if [ ! -e $OURDIR/geni.key ]; then
    geni-get key > $OURDIR/geni.key
    cat $OURDIR/geni.key | grep -q END\ .\*\PRIVATE\ KEY
    if [ ! $? -eq 0 ]; then
	echo "ERROR: could not get geni key; aborting!"
	exit 1
    fi
fi
if [ ! -e $OURDIR/geni.certificate ]; then
    geni-get certificate > $OURDIR/geni.certificate
    cat $OURDIR/geni.certificate | grep -q END\ CERTIFICATE
    if [ ! $? -eq 0 ]; then
	echo "ERROR: could not get geni cert; aborting!"
	exit 1
    fi
fi

if [ ! -e ~/.ssl/encrypted.pem ]; then
    mkdir -p ~/.ssl
    chmod 700 ~/.ssl

    cat $OURDIR/geni.key > ~/.ssl/encrypted.pem
    cat $OURDIR/geni.certificate >> ~/.ssl/encrypted.pem
fi

if [ ! -e $OURDIR/manifests.xml ]; then
    $PYTHON $DIRNAME/getmanifests.py $OURDIR/manifests
    if [ ! $? -eq 0 ]; then
	# Fall back to geni-get
	echo "WARNING: falling back to getting manifest from AM, not Portal -- multi-site experiments will not work fully!"
	geni-get manifest > $OURDIR/manifests.0.xml
    fi
fi

if [ ! -e $OURDIR/encrypted_admin_pass ]; then
    cat $OURDIR/manifests.0.xml | perl -e '@lines = <STDIN>; $all = join("",@lines); if ($all =~ /^.+<[^:]+:password[^>]*>([^<]+)<\/[^:]+:password>.+/igs) { print $1; }' > $OURDIR/encrypted_admin_pass
fi

if [ ! -e $OURDIR/decrypted_admin_pass -a -s $OURDIR/encrypted_admin_pass ]; then
    openssl smime -decrypt -inform PEM -inkey geni.key -in $OURDIR/encrypted_admin_pass -out $OURDIR/decrypted_admin_pass
fi

#
# Suck in user parameters, if we haven't already.  This also pulls in
# global labels.
#
if [ ! -e $OURDIR/parameters ]; then
    $PYTHON $DIRNAME/manifest-to-parameters.py $OURDIR/manifests.0.xml > $OURDIR/parameters
fi
. $OURDIR/parameters

#
# Grab our public addrs.
#
if [ ! -f $OURDIR/publicaddrs ]; then
    $PYTHON $DIRNAME/manifest-to-publicaddrs.py $OURDIR/manifests.0.xml $CLUSTER > $OURDIR/publicaddrs.raw
    PUBLICADDRS=`cat $OURDIR/publicaddrs.raw | sed -e 's|^\([^/]*\)/.*$|\1|' | xargs`
    PUBLICADDRCOUNT=`cat $OURDIR/publicaddrs.raw | wc -l`
    PUBLICADDRNETMASK=`cat $OURDIR/publicaddrs.raw | sed -e 's|^[^/]*/\(.*\)$|\1|' | head -1`
    cat <<EOF > $OURDIR/publicaddrs
PUBLICADDRS="$PUBLICADDRS"
PUBLICADDRCOUNT=$PUBLICADDRCOUNT
PUBLICADDRNETMASK="$PUBLICADDRNETMASK"
EOF
fi
. $OURDIR/publicaddrs

#
# Ok, to be absolutely safe, if the ADMIN_PASS_HASH we got from params was "",
# and if admin pass wasn't sent as an encrypted string to us, we have we have
# to generate a random admin pass and hash it.
#
if [ "x${ADMIN_PASS_HASH}" = "x" ] ; then
    DEC_ADMIN_PASS=`cat $OURDIR/decrypted_admin_pass`
    if [ "x${DEC_ADMIN_PASS}" = "x" ]; then
	ADMIN_PASS=`$PSWDGEN`
	ADMIN_PASS_HASH="`echo \"${ADMIN_PASS}\" | openssl passwd -1 -stdin`"

	# Save it off so we can email the user -- because nobody has the
	# random pass we just generated!
	echo "${ADMIN_PASS}" > $OURDIR/random_admin_pass
    else
	ADMIN_PASS="${DEC_ADMIN_PASS}"
	ADMIN_PASS_HASH="`echo \"${ADMIN_PASS}\" | openssl passwd -1 -stdin`"
    fi

    #
    # Overwrite the params.
    #
    echo "ADMIN_PASS='${ADMIN_PASS}'" >> $OURDIR/parameters
    echo "ADMIN_PASS_HASH='${ADMIN_PASS_HASH}'" >> $OURDIR/parameters
fi

EXPTTYPE="Kubernetes"
CREATOR=`geni-get user_urn | cut -f4 -d+`
SWAPPER=`geni-get user_urn | cut -f4 -d+`
NODEID=`cat $BOOTDIR/nickname | cut -d . -f 1`
PNODEID=`cat $BOOTDIR/nodeid`
EEID=`cat $BOOTDIR/nickname | cut -d . -f 2`
EPID=`cat $BOOTDIR/nickname | cut -d . -f 3`
OURDOMAIN=`cat $BOOTDIR/mydomain`
FULLDOMAIN="${EEID}.${EPID}.$OURDOMAIN"
NFQDN="`cat $BOOTDIR/nickname`.$OURDOMAIN"
PFQDN="`cat $BOOTDIR/nodeid`.$OURDOMAIN"
MYIP=`cat $BOOTDIR/myip`
EXTERNAL_NETWORK_INTERFACE=`cat $BOOTDIR/controlif`
HOSTNAME=`cat ${BOOTDIR}/nickname | cut -f1 -d.`
ARCH=`uname -m`

# Check if our init is systemd
dpkg-query -S /sbin/init | grep -q systemd
HAVE_SYSTEMD=`expr $? = 0`

. /etc/lsb-release
DISTRIB_MAJOR=`echo $DISTRIB_RELEASE | cut -d. -f1`
if [ -e /etc/emulab/bossnode ]; then
    BOSSNODE=`cat /etc/emulab/bossnode`
fi
if [ -n "$BOSSNODE" ]; then
    SWAPPER_EMAIL=`geni-get -s $BOSSNODE slice_email`
else
    SWAPPER_EMAIL=`geni-get slice_email`
fi

#
# Grab our topomap so we can see how many nodes we have.
# NB: only safe to use topomap for non-fqdn things.
#
if [ ! -f $TOPOMAP ]; then
    if [ -f $TOPOMAP ]; then
	cp -p $TOPOMAP $TOPOMAP.old
    fi

    # First try via manifest; fall back to tmcc if necessary (although
    # that will break multisite exps with >1 second cluster node(s)).
    $PYTHON $DIRNAME/manifest-to-topomap.py $OURDIR/manifests.0.xml > $TOPOMAP
    if [ ! $? -eq 0 ]; then
	echo "ERROR: could not extract topomap from manifest; aborting to tmcc"
	rm -f $TOPOMAP
	$TMCC topomap | gunzip > $TOPOMAP
    fi

    # Filter out blockstore nodes
    cat $TOPOMAP | grep -v '^bsnode,' > $TOPOMAP.no.bsnode
    mv $TOPOMAP.no.bsnode $TOPOMAP
    cat $TOPOMAP | grep -v '^bslink,' > $TOPOMAP.no.bslink
    mv $TOPOMAP.no.bslink $TOPOMAP
    if [ -f $TOPOMAP.old ]; then
	diff -u $TOPOMAP.old $TOPOMAP > $TOPOMAP.diff
	#
	# NB: this does assume that nodes either leave all the lans, or join
	# all the lans.  We don't try to distinguish anything else.
	#
	NEWNODELIST=`cat topomap.diff | sed -n -e 's/^\+\([a-zA-Z0-9\-]*\),.*:.*$/\1/p' | uniq | xargs`
	OLDNODELIST=`cat topomap.diff | sed -n -e 's/^\-\([a-zA-Z0-9\-]*\),.*:.*$/\1/p' | uniq | xargs`

	# Just remove the fqdn map and let it be recalculated below
	rm -f $OURDIR/fqdn.map
	rm -f $OURDIR/fqdn.physical.map
    fi
fi


#
# Create a map of node nickname to FQDN (and another one of pnode id to FQDN).
# This supports geni multi-site experiments.
#
if [ \( -s $OURDIR/manifests.xml \) -a \( ! \( -s $OURDIR/fqdn.map \) \) ]; then
    cat $OURDIR/manifests.xml | tr -d '\n' | sed -e 's/<node /\n<node /g'  | sed -n -e "s/^<node [^>]*client_id=['\"]*\([^'\"]*\)['\"].*<host name=['\"]\([^'\"]*\)['\"].*$/\1\t\2/p" > $OURDIR/fqdn.map
    # Add a newline if we wrote anything.
    if [ -s $OURDIR/fqdn.map ]; then
	echo '' >> $OURDIR/fqdn.map
    fi
    # Filter out any blockstore nodes
    # XXX: this strategy doesn't work, because only the NM node makes
    # the fqdn.map file.  So, just look for bsnode for now.
    #BSNODES=`cat /var/emulab/boot/tmcc/storageconfig | sed -n -e 's/^.* HOSTID=\([^ \t]*\) .*$/\1/p' | xargs`
    #for bs in $BSNODES ; do
    #	cat $OURDIR/fqdn.map | grep -v "^${bs}"$'\t' > $OURDIR/fqdn.map.tmp
    #	mv $OURDIR/fqdn.map.tmp $OURDIR/fqdn.map
    #done
    # XXX: why doesn't the tab grep work here, sigh...
    #cat $OURDIR/fqdn.map | grep -v '^bsnode'$'\t' > $OURDIR/fqdn.map.tmp
    cat $OURDIR/fqdn.map | grep -v '^bsnode' > $OURDIR/fqdn.map.tmp
    mv $OURDIR/fqdn.map.tmp $OURDIR/fqdn.map
    cat $OURDIR/fqdn.map | grep -v '^fw[ \t]*' > $OURDIR/fqdn.map.tmp
    mv $OURDIR/fqdn.map.tmp $OURDIR/fqdn.map
    cat $OURDIR/fqdn.map | grep -v '^fw-s2[ \t]*' > $OURDIR/fqdn.map.tmp
    mv $OURDIR/fqdn.map.tmp $OURDIR/fqdn.map

    cat $OURDIR/manifests.xml | tr -d '\n' | sed -e 's/<node /\n<node /g'  | sed -n -e "s/^<node [^>]*component_id=['\"]*[a-zA-Z0-9:\+\.]*node+\([^'\"]*\)['\"].*<host name=['\"]\([^'\"]*\)['\"].*$/\1\t\2/p" > $OURDIR/fqdn.physical.map
    # Add a newline if we wrote anything.
    if [ -s $OURDIR/fqdn.physical.map ]; then
	echo '' >> $OURDIR/fqdn.physical.map
    fi
    # Filter out any blockstore nodes
    cat $OURDIR/fqdn.physical.map | grep -v '[ \t]bsnode\.' > $OURDIR/fqdn.physical.map.tmp
    mv $OURDIR/fqdn.physical.map.tmp $OURDIR/fqdn.physical.map
    # Filter out any firewall nodes
    cat $OURDIR/fqdn.physical.map | grep -v '[ \t]*fw\.' > $OURDIR/fqdn.physical.map.tmp
    mv $OURDIR/fqdn.physical.map.tmp $OURDIR/fqdn.physical.map
    cat $OURDIR/fqdn.physical.map | grep -v '[ \t]*fw-s2\.' > $OURDIR/fqdn.physical.map.tmp
    mv $OURDIR/fqdn.physical.map.tmp $OURDIR/fqdn.physical.map
fi

#
# Grab our list of short-name and FQDN nodes.  One way or the other, we have
# an fqdn map.  First we tried the GENI way; then the old Emulab way with
# topomap.
#
NODES=`cat $OURDIR/fqdn.map | cut -f1 | sort -n | xargs`
FQDNS=`cat $OURDIR/fqdn.map | cut -f2 | sort -n | xargs`
NODEIPS=""
NODECOUNT=0
for node in $NODES ; do
    ip=`grep "${node}-" /etc/hosts | cut -f1`
    NODEIPS="$NODEIPS $ip"
    NODECOUNT=`expr $NODECOUNT + 1`
done

# Construct parallel-ssh hosts files
if [ ! -e $OURDIR/pssh.all-nodes ]; then
    echo > $OURDIR/pssh.all-nodes
    echo > $OURDIR/pssh.other-nodes
    for node in $NODES ; do
	echo $node >> $OURDIR/pssh.all-nodes
	[ "$node" = "$NODEID" ] && continue
	echo $node >> $OURDIR/pssh.other-nodes
    done
fi

OTHERNODES=""
for node in $NODES ; do
    [ "$node" = "$NODEID" ] && continue
    OTHERNODES="$OTHERNODES $node"
done

##
## Setup our Ubuntu package mirror, if necessary.
##
grep MIRRORSETUP $SETTINGS
if [ ! $? -eq 0 ]; then
    if [ ! "x${UBUNTUMIRRORHOST}" = "x" ]; then
	oldstr='us.archive.ubuntu.com'
	newstr="${UBUNTUMIRRORHOST}"

	if [ ! "x${UBUNTUMIRRORPATH}" = "x" ]; then
	    oldstr='us.archive.ubuntu.com/ubuntu'
	    newstr="${UBUNTUMIRRORHOST}/${UBUNTUMIRRORPATH}"
	fi

	echo "*** Changing Ubuntu mirror from $oldstr to $newstr ..."
	$SUDO sed -E -i.us.archive.ubuntu.com -e "s|(${oldstr})|$newstr|" /etc/apt/sources.list
    fi

    echo "MIRRORSETUP=1" >> $SETTINGS
fi

if [ ! -f $OURDIR/apt-updated -a "${DO_APT_UPDATE}" = "1" ]; then
    #
    # Attempt to handle old EOL releases; so far only need to handle utopic
    #
    . /etc/lsb-release
    grep -q old-releases /etc/apt/sources.list
    if [  $? != 0 -a "x${DISTRIB_CODENAME}" = "xutopic" ]; then
	sed -i -re 's/([a-z]{2}\.)?archive.ubuntu.com|security.ubuntu.com/old-releases.ubuntu.com/g' /etc/apt/sources.list
    fi
    $SUDO apt-get update
    touch $OURDIR/apt-updated
fi

if [ ! -f $OURDIR/apt-dist-upgraded -a "${DO_APT_DIST_UPGRADE}" = "1" ]; then
    # First, mark grub packages not to be upgraded; we don't want an
    # install going to the wrong place.
    PKGS="grub-common grub-gfxpayload-lists grub-pc grub-pc-bin grub2-common"
    for pkg in $PKGS; do
	$SUDO apt-mark hold $pkg
    done
    $SUDO apt-get dist-upgrade -y
    for pkg in $PKGS; do
	$SUDO apt-mark unhold $pkg
    done
    touch $OURDIR/apt-dist-upgraded
fi



#
# Process our network information.
#
netmask2prefix() {
    nm=$1
    bits=0
    IFS=.
    read -r i1 i2 i3 i4 <<EOF
$nm
EOF
    unset IFS
    for n in $i1 $i2 $i3 $i4 ; do
	v=128
	while [ $v -gt 0 ]; do
	    bits=`expr $bits + \( \( $n / $v \) % 2 \)`
	    v=`expr $v / 2`
	done
    done
    echo $bits
}

getnodeip() {
    node=$1
    network=$2

    if [ -z "$node" -o -z "$network" ]; then
	echo ""
	return
    fi

    ip=`sed -ne "s/^\([0-9\.]*\)[ \t]*${node}-${network}[ \t]*.*$/\1/p" /etc/hosts`
    if [ "$network" = "$MGMTLAN" -a -z "$ip" ]; then
	echo $SINGLENODE_MGMT_IP
    else
	echo $ip
    fi
}

getnetmask() {
    network=$1

    if [ -z "$network" ]; then
	echo ""
	return
    fi

    nm=`sed -ne "s/^${network},\([0-9\.]*\),.*$/\1/p" $TOPOMAP`
    if [ "$network" = "$MGMTLAN" -a -z "$nm" ]; then
	echo $SINGLENODE_MGMT_NETMASK
    else
	echo $nm
    fi
}

getnetmaskprefix() {
    netmask=`getnetmask $1`
    if [ -z "$netmask" ]; then
	echo ""
	return
    fi
    prefix=`netmask2prefix $netmask`
    echo $prefix
}

getnetworkip() {
    node=$1
    network=$2
    nodeip=`getnodeip $node $network`
    netmask=`getnetmask $network`

    IFS=.
    read -r i1 i2 i3 i4 <<EOF
$nodeip
EOF
    read -r m1 m2 m3 m4 <<EOF
$netmask
EOF
    unset IFS
    printf "%d.%d.%d.%d\n" "$((i1 & m1))" "$((i2 & m2))" "$((i3 & m3))" "$((i4 & m4))"
}

#
# Note that the `.`s are escaped enough to make it from shell into yaml into
# ansible and eventually into the golang regexp used by flanneld.  Not
# generic.
#
getnetworkregex() {
    node=$1
    network=$2
    nodeip=`getnodeip $node $network`
    netmask=`getnetmask $network`

    IFS=.
    read -r i1 i2 i3 i4 <<EOF
$nodeip
EOF
    read -r m1 m2 m3 m4 <<EOF
$netmask
EOF
    unset IFS
    REGEX=""
    if [ $m1 -ge 255 ]; then
	REGEX="${REGEX}$i1"
    else
	REGEX="${REGEX}[0-9]{1,3}"
    fi
    REGEX="${REGEX}\\\\\\\\."
    if [ $m2 -ge 255 ]; then
	REGEX="${REGEX}$i2"
    else
	REGEX="${REGEX}[0-9]{1,3}"
    fi
    REGEX="${REGEX}\\\\\\\\."
    if [ $m3 -ge 255 ]; then
	REGEX="${REGEX}$i3"
    else
	REGEX="${REGEX}[0-9]{1,3}"
    fi
    REGEX="${REGEX}\\\\\\\\."
    if [ $m4 -ge 255 ]; then
	REGEX="${REGEX}$i4"
    else
	REGEX="${REGEX}[0-9]{1,3}"
    fi
    echo "$REGEX"
}

##
## Util functions.
##

getfqdn() {
    n=$1
    fqdn=`cat $OURDIR/fqdn.map | grep -E "$n\s" | cut -f2`
    echo $fqdn
}

getcontrolip() {
    n=$1
    fqdn=`getfqdn $n`
    ip=`host -4 $fqdn | sed -nre 's/.* has address ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)$/\1/p'`
    echo $ip
}

service_init_reload() {
    if [ ${HAVE_SYSTEMD} -eq 1 ]; then
	$SUDO systemctl daemon-reload
    fi
}

service_enable() {
    service=$1
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	$SUDO update-rc.d $service enable
    else
	$SUDO systemctl enable $service
    fi
}

service_disable() {
    service=$1
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	$SUDO update-rc.d $service disable
    else
	$SUDO systemctl disable $service
    fi
}

service_restart() {
    service=$1
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	$SUDO service $service restart
    else
	$SUDO systemctl restart $service
    fi
}

service_stop() {
    service=$1
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	$SUDO service $service stop
    else
	$SUDO systemctl stop $service
    fi
}

service_start() {
    service=$1
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	$SUDO service $service start
    else
	$SUDO systemctl start $service
    fi
}

GETTER=`which wget`
if [ -n "$GETTER" ]; then
    GETTEROUT="$GETTER --remote-encoding=unix -c -O"
    GETTER="$GETTER --remote-encoding=unix -c -N"
    GETTERLOGARG="-o"
else
    GETTER="/bin/false NO WGET INSTALLED!"
    GETTEROUT="/bin/false NO WGET INSTALLED!"
fi

get_url() {
    if [ -z "$GETTER" ]; then
	/bin/false
	return
    fi

    urls="$1"
    outfile="$2"
    if [ -n "$3" ]; then
	retries=$3
    else
	retries=3
    fi
    if [ -n "$4" ]; then
	interval=$4
    else
	interval=5
    fi
    if [ -n "$5" ]; then
	force="$5"
    else
	force=0
    fi

    if [ -n "$outfile" -a -f "$outfile" -a $force -ne 0 ]; then
	rm -f "$outfile"
    fi

    success=0
    tmpfile=`mktemp /tmp/wget.log.XXX`
    for url in $urls ; do
	tries=$retries
	while [ $tries -gt 0 ]; do
	    if [ -n "$outfile" ]; then
		$GETTEROUT $outfile $GETTERLOGARG $tmpfile "$url"
	    else
		$GETTER $GETTERLOGARG $tmpfile "$url"
	    fi
	    if [ $? -eq 0 ]; then
		if [ -z "$outfile" ]; then
		    # This is the best way to figure out where wget
		    # saved a file!
		    outfile=`bash -c "cat $tmpfile | sed -n -e 's/^.*Saving to: '$'\u2018''\([^'$'\u2019'']*\)'$'\u2019''.*$/\1/p'"`
		    if [ -z "$outfile" ]; then
			outfile=`bash -c "cat $tmpfile | sed -n -e 's/^.*File '$'\u2018''\([^'$'\u2019'']*\)'$'\u2019'' not modified.*$/\1/p'"`
		    fi
		fi
		success=1
		break
	    else
		sleep $interval
		tries=`expr $tries - 1`
	    fi
	done
	if [ $success -eq 1 ]; then
	    break
	fi
    done

    rm -f $tmpfile

    if [ $success -eq 1 ]; then
	echo "$outfile"
	/bin/true
    else
	/bin/false
    fi
}

# Time logging
if [ $FIRSTTIME -ne 0 ]; then
    logtend "libfirsttime"
fi
