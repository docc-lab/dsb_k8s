#!/bin/sh

DIRNAME=`dirname $0`

#
# Setup our core vars
#
OURDIR=/root/setup
SETTINGS=$OURDIR/settings
LOCALSETTINGS=$OURDIR/settings.local
TOPOMAP=$OURDIR/topomap
BOOTDIR=/var/emulab/boot
TMCC=/usr/local/etc/emulab/tmcc

[ ! -d $OURDIR ] && mkdir -p $OURDIR

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

[ ! -e $SETTINGS ] && touch $SETTINGS
[ ! -e $LOCALSETTINGS ] && touch $LOCALSETTINGS
cd $OURDIR

#LOCKFILE="lockfile -1 -r -1 "
LOCKFILE="lockfile-create --retry 65535 "
RMLOCKFILE="lockfile-remove "
PSWDGEN="openssl rand -hex 10"
SSH="ssh -o StrictHostKeyChecking=no"
SCP="scp -p -o StrictHostKeyChecking=no"
#PYTHON=python3
#PIP=pip3
PYTHON=python
PIP=pip

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
KUBESPRAY_REPO="https://github.com/kubernetes-incubator/kubespray.git"
KUBESPRAY_USE_VIRTUALENV=1
KUBESPRAY_VIRTUALENV=kubespray-virtualenv
KUBESPRAY_VERSION=release-2.13
DOCKER_VERSION=
K8S_VERSION=
HELM_VERSION=

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
    echo "force-confdef" > /etc/dpkg/dpkg.cfg.d/cloudlab
    echo "force-confold" >> /etc/dpkg/dpkg.cfg.d/cloudlab
    touch $OURDIR/apt-configured
fi
export DEBIAN_FRONTEND=noninteractive
# -o Dpkg::Options::="--force-confold" -o Dpkg::Options::="--force-confdef" 
DPKGOPTS=''
APTGETINSTALLOPTS='-y'
APTGETINSTALL="apt-get $DPKGOPTS install $APTGETINSTALLOPTS"
# Don't install/upgrade packages if this is not set
if [ ${DO_APT_INSTALL} -eq 0 ]; then
    APTGETINSTALL="/bin/true ${APTGETINSTALL}"
fi

#
# Grab our geni creds, and create a GENI credential cert
#
dpkg -s python-m2crypto >/dev/null 2>&1
if [ ! $? -eq 0 ]; then
    apt-get $DPKGOPTS install $APTGETINSTALLOPTS python-m2crypto
    # Keep trying again with updated cache forever;
    # we must have this package.
    success=$?
    while [ ! $success -eq 0 ]; do
	apt-get update
	apt-get $DPKGOPTS install $APTGETINSTALLOPTS python-m2crypto
	success=$?
    done
fi

if [ ! -e $OURDIR/geni.key ]; then
    geni-get key > $OURDIR/geni.key
    cat $OURDIR/geni.key | grep -q END\ .\*\PRIVATE\ KEY
    if [ $? -eq 0 ]; then
	HAS_GENI_KEY=1
    else
	HAS_GENI_KEY=0
    fi
else
	HAS_GENI_KEY=1
fi
if [ ! -e $OURDIR/geni.certificate ]; then
    geni-get certificate > $OURDIR/geni.certificate
    cat $OURDIR/geni.certificate | grep -q END\ CERTIFICATE
    if [ $? -eq 0 ]; then
	HAS_GENI_CERT=1
    else
	HAS_GENI_CERT=0
    fi
else
    HAS_GENI_CERT=1
fi

if [ ! -e /root/.ssl/encrypted.pem ]; then
    mkdir -p /root/.ssl
    chmod 600 /root/.ssl

    cat $OURDIR/geni.key > /root/.ssl/encrypted.pem
    cat $OURDIR/geni.certificate >> /root/.ssl/encrypted.pem
fi

if [ ! -e $OURDIR/manifests.xml ]; then
    if [ $HAS_GENI_CERT -eq 1 ]; then
	python $DIRNAME/getmanifests.py $OURDIR/manifests
    else
	# Fall back to geni-get
	echo "WARNING: falling back to getting manifest from AM, not Portal -- multi-site experiments will not work fully!"
	geni-get manifest > $OURDIR/manifests.0.xml
    fi
fi

if [ ! -e $OURDIR/encrypted_admin_pass ]; then
    cat /root/setup/manifests.0.xml | perl -e '@lines = <STDIN>; $all = join("",@lines); if ($all =~ /^.+<[^:]+:password[^>]*>([^<]+)<\/[^:]+:password>.+/igs) { print $1; }' > $OURDIR/encrypted_admin_pass
fi

if [ ! -e $OURDIR/decrypted_admin_pass -a -s $OURDIR/encrypted_admin_pass ]; then
    openssl smime -decrypt -inform PEM -inkey geni.key -in $OURDIR/encrypted_admin_pass -out $OURDIR/decrypted_admin_pass
fi

#
# Suck in user configuration overrides, if we haven't already
#
if [ ! -e $OURDIR/parameters ]; then
    touch $OURDIR/parameters
    cat $OURDIR/manifests.0.xml | sed -n -e 's/^[^<]*<[^:]*:parameter>\([^<]*\)<\/[^:]*:parameter>/\1/p' > $OURDIR/parameters
fi
. $OURDIR/parameters

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

CREATOR=`cat $BOOTDIR/creator`
SWAPPER=`cat $BOOTDIR/swapper`
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

PUBLICADDRS=`cat $OURDIR/manifests.*.xml | perl -e '$found = 0; while (<STDIN>) { if ($_ =~ /\<[\d\w:]*routable_pool [^\>\<]*\/>/) { print STDERR "DEBUG: found empty pool: $_\n"; next; } if ($_ =~ /\<[\d\w:]*routable_pool [^\>]*client_id=['"'"'"]'$NETWORKMANAGER'['"'"'"]/) { $found = 1; print STDERR "DEBUG: found: $_\n" } if ($found) { while ($_ =~ m/\<emulab:ipv4 address="([\d.]+)\" netmask=\"([\d\.]+)\"/g) { print "$1\n"; } } if ($found && $_ =~ /routable_pool\>/) { print STDERR "DEBUG: end found: $_\n"; $found = 0; } }' | xargs`
PUBLICCOUNT=0
for ip in $PUBLICADDRS ; do
    PUBLICCOUNT=`expr $PUBLICCOUNT + 1`
done



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
    python2 $DIRNAME/manifest-to-topomap.py $OURDIR/manifests.0.xml > $TOPOMAP
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
    cat manifests.xml | tr -d '\n' | sed -e 's/<node /\n<node /g'  | sed -n -e "s/^<node [^>]*client_id=['\"]*\([^'\"]*\)['\"].*<host name=['\"]\([^'\"]*\)['\"].*$/\1\t\2/p" > $OURDIR/fqdn.map
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

    cat manifests.xml | tr -d '\n' | sed -e 's/<node /\n<node /g'  | sed -n -e "s/^<node [^>]*component_id=['\"]*[a-zA-Z0-9:\+\.]*node+\([^'\"]*\)['\"].*<host name=['\"]\([^'\"]*\)['\"].*$/\1\t\2/p" > $OURDIR/fqdn.physical.map
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
for node in $NODES ; do
    ip=`grep "${node}-" /etc/hosts | cut -f1`
    NODEIPS="$NODEIPS $ip"
done

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
	sed -E -i.us.archive.ubuntu.com -e "s|(${oldstr})|$newstr|" /etc/apt/sources.list
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
    apt-get update
    touch $OURDIR/apt-updated
fi

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

if [ ! -f $OURDIR/apt-dist-upgraded -a "${DO_APT_DIST_UPGRADE}" = "1" ]; then
    # First, mark grub packages not to be upgraded; we don't want an
    # install going to the wrong place.
    PKGS="grub-common grub-gfxpayload-lists grub-pc grub-pc-bin grub2-common"
    for pkg in $PKGS; do
	apt-mark hold $pkg
    done
    apt-get dist-upgrade -y
    for pkg in $PKGS; do
	apt-mark unhold $pkg
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

    sed -ne "s/^\([0-9\.]*\)[ \t]*${node}-${network}[ \t]*.*$/\1/p" /etc/hosts
}

getnetmask() {
    network=$1

    if [ -z "$network" ]; then
	echo ""
	return
    fi

    sed -ne "s/^${network},\([0-9\.]*\),.*$/\1/p" $TOPOMAP
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

#
# NB: this IP/mask is only valid after setting up the management network IP
# addresses because they might not be the Emulab ones.
#
if [ ! -e $OURDIR/info.mgmt ]; then
    MGMTIP=`grep -E "$NODEID$" $OURDIR/mgmt-hosts | head -1 | sed -n -e 's/^\\([0-9]*\\.[0-9]*\\.[0-9]*\\.[0-9]*\\).*$/\\1/p'`
    MGMTNETMASK=`cat $OURDIR/mgmt-netmask`
    MGMTPREFIX=`netmask2prefix $MGMTNETMASK`
    if [ -z "$MGMTLAN" ] ; then
	MGMTVLAN=0
	MVMTVLANDEV=
	MGMTMAC=""
	MGMT_NETWORK_INTERFACE="tun0"
    else
	cat ${BOOTDIR}/tmcc/ifconfig | grep "IFACETYPE=vlan" | grep "${MGMTLAN}"
	if [ $? = 0 ]; then
	    MGMTVLAN=1
	    MGMTMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* VMAC=\([0-9a-f:\.]*\) .* LAN=${MGMTLAN}.*\$/\1/p"`
	    MGMT_NETWORK_INTERFACE=`/usr/local/etc/emulab/findif -m $MGMTMAC`
	    MGMTVLANDEV=`ip link show ${MGMT_NETWORK_INTERFACE} | sed -n -e "s/^.*${MGMT_NETWORK_INTERFACE}\@\([0-9a-zA-Z_]*\): .*\$/\1/p"`
	    MGMTVLANTAG=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* LAN=${MGMTLAN} VTAG=\([0-9]*\).*\$/\1/p"`
	else
	    MGMTVLAN=0
	    MGMTMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/.* MAC=\([0-9a-f:\.]*\) .* LAN=${MGMTLAN}/\1/p"`
	    MGMT_NETWORK_INTERFACE=`/usr/local/etc/emulab/findif -m $MGMTMAC`
	    MGMTVLANDEV=
	fi
    fi
    echo "MGMTIP='$MGMTIP'" >> $OURDIR/info.mgmt
    echo "MGMTNETMASK='$MGMTNETMASK'" >> $OURDIR/info.mgmt
    echo "MGMTPREFIX='$MGMTPREFIX'" >> $OURDIR/info.mgmt
    echo "MGMTVLAN=$MGMTVLAN" >> $OURDIR/info.mgmt
    echo "MGMTMAC='$MGMTMAC'" >> $OURDIR/info.mgmt
    echo "MGMT_NETWORK_INTERFACE='$MGMT_NETWORK_INTERFACE'" >> $OURDIR/info.mgmt
    echo "MGMTVLANDEV='$MGMTVLANDEV'" >> $OURDIR/info.mgmt
    echo "MGMTVLANTAG='$MGMTVLANTAG'" >> $OURDIR/info.mgmt
else
    . $OURDIR/info.mgmt
fi

#
# NB: this IP/mask is only valid after data ips have been assigned, because
# they might not be the Emulab ones.
#
for lan in $DATAFLATLANS $DATAOTHERLANS ; do
    if [ -e $OURDIR/info.$lan ] ; then
	continue
    fi

    DATAIP=`cat $OURDIR/data-hosts.$lan | grep -E "$NODEID$" | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
    DATANETMASK=`cat $OURDIR/data-netmask.$lan`
    DATAPREFIX=`netmask2prefix $DATANETMASK`
    cat ${BOOTDIR}/tmcc/ifconfig | grep "IFACETYPE=vlan" | grep "${lan}"
    if [ $? = 0 ]; then
	DATAVLAN=1
	DATAMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* VMAC=\([0-9a-f:\.]*\) .* LAN=${lan}.*\$/\1/p"`
	DATADEV=`/usr/local/etc/emulab/findif -m $DATAMAC`
	DATAVLANDEV=`ip link show ${DATADEV} | sed -n -e "s/^.*${DATADEV}\@\([0-9a-zA-Z_]*\): .*\$/\1/p"`
	DATAVLANTAG=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* LAN=${lan} VTAG=\([0-9]*\).*\$/\1/p"`
	DATAPMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* PMAC=\([0-9a-f:\.]*\) .* LAN=${lan}.*\$/\1/p"`
    else
	DATAVLAN=0
	DATAVLANDEV=""
	DATAVLANTAG=0
	DATAMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* MAC=\([0-9a-f:\.]*\) .* LAN=${lan}.*$/\1/p"`
	DATADEV=`/usr/local/etc/emulab/findif -m $DATAMAC`
	DATAPMAC=
    fi

    echo "DATABRIDGE=br-${lan}" >> $OURDIR/info.$lan
    echo "DATAIP=${DATAIP}" >> $OURDIR/info.$lan
    echo "DATANETMASK=${DATANETMASK}" >> $OURDIR/info.$lan
    echo "DATAPREFIX=${DATAPREFIX}" >> $OURDIR/info.$lan
    echo "DATAVLAN=${DATAVLAN}" >> $OURDIR/info.$lan
    echo "DATAVLANTAG=${DATAVLANTAG}" >> $OURDIR/info.$lan
    echo "DATAVLANDEV=${DATAVLANDEV}" >> $OURDIR/info.$lan
    echo "DATAMAC=${DATAMAC}" >> $OURDIR/info.$lan
    echo "DATAPMAC=${DATAPMAC}" >> $OURDIR/info.$lan
    echo "DATADEV=${DATADEV}" >> $OURDIR/info.$lan
done

for lan in $DATAVLANS ; do
    if [ -e $OURDIR/info.$lan ] ; then
	continue
    fi

    #DATAIP=`cat $OURDIR/data-hosts.$lan | grep -E "$NODEID$" | sed -n -e 's/^\([0-9]*.[0-9]*.[0-9]*.[0-9]*\).*$/\1/p'`
    #DATANETMASK=`cat $OURDIR/data-netmask.$lan`
    DATAVLAN=1
    DATAMAC=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* VMAC=\([0-9a-f:\.]*\) .* LAN=${lan}.*\$/\1/p"`
    DATADEV=`/usr/local/etc/emulab/findif -m $DATAMAC`
    DATAVLANDEV=`ip link show ${DATADEV} | sed -n -e "s/^.*${DATADEV}\@\([0-9a-zA-Z_]*\): .*\$/\1/p"`
    DATAVLANTAG=`cat ${BOOTDIR}/tmcc/ifconfig | sed -n -e "s/^.* LAN=${lan} VTAG=\([0-9]*\).*\$/\1/p"`

    echo "DATABRIDGE=br-${DATAVLANDEV}" >> $OURDIR/info.$lan
    #echo "DATAIP=${DATAIP}" >> $OURDIR/info.$lan
    #echo "DATANETMASK=${DATANETMASK}" >> $OURDIR/info.$lan
    echo "DATAVLAN=${DATAVLAN}" >> $OURDIR/info.$lan
    echo "DATAVLANTAG=${DATAVLANTAG}" >> $OURDIR/info.$lan
    echo "DATAVLANDEV=${DATAVLANDEV}" >> $OURDIR/info.$lan
    echo "DATAMAC=${DATAMAC}" >> $OURDIR/info.$lan
    echo "DATADEV=${DATADEV}" >> $OURDIR/info.$lan
done

##
## Util functions.
##

getfqdn() {
    n=$1
    fqdn=`cat $OURDIR/fqdn.map | grep -E "$n\s" | cut -f2`
    echo $fqdn
}

service_enable() {
    service=$1
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	update-rc.d $service enable
    else
	systemctl enable $service
    fi
}

service_disable() {
    service=$1
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	update-rc.d $service disable
    else
	systemctl disable $service
    fi
}

service_restart() {
    service=$1
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	service $service restart
    else
	systemctl restart $service
    fi
}

service_stop() {
    service=$1
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	service $service stop
    else
	systemctl stop $service
    fi
}

service_start() {
    service=$1
    if [ ${HAVE_SYSTEMD} -eq 0 ]; then
	service $service start
    else
	systemctl start $service
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
