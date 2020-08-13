#!/bin/sh

set -x

if [ -z "$EUID" ]; then
    EUID=`id -u`
fi
if [ $EUID -ne 0 ] ; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/self-signed-ssl-done ]; then
    exit 0
fi

logtstart "self-signed-ssl"

maybe_install_packages easy-rsa

export EASY_RSA="/etc/ssl/easy-rsa"
if [ ! -e $EASY_RSA ]; then
    mkdir -p $EASY_RSA
    cp -r /usr/share/easy-rsa/* $EASY_RSA
    # Batch mode
    sed -i -e s/--interact/--batch/ $EASY_RSA/build-ca
    sed -i -e s/--interact/--batch/ $EASY_RSA/build-key-server
    sed -i -e s/--interact/--batch/ $EASY_RSA/build-key
    sed -i -e s/DEBUG=0/DEBUG=1/ $EASY_RSA/pkitool
fi

export OPENSSL="openssl"
export PKCS11TOOL="pkcs11-tool"
export GREP="grep"
export KEY_CONFIG="`$EASY_RSA/whichopensslcnf $EASY_RSA`"
export KEY_DIR="$EASY_RSA/keys"
export PKCS11_MODULE_PATH="dummy"
export PKCS11_PIN="dummy"
export KEY_SIZE=2048
export CA_EXPIRE=3650
export KEY_EXPIRE=3650

export KEY_COUNTRY="US"
export KEY_PROVINCE="UT"
export KEY_CITY="Salt Lake City"
export KEY_ORG="$EPID-$EEID"
TRUNCATED_EMAIL=`echo ${SWAPPER_EMAIL} | cut -c 1-40`
export KEY_EMAIL="${TRUNCATED_EMAIL}"
export KEY_CN="k8s-$EPID-$EEID"
export KEY_NAME=$KEY_CN
export KEY_OU=$KEY_CN
# --batch mode is unhappy if it's not this
export KEY_ALTNAMES="DNS:$HEAD"

mkdir -p $KEY_DIR
cd $EASY_RSA

# Handle the case on Ubuntu18 where easy-rsa is broken for openssl 1.1.0
# (https://github.com/OpenVPN/easy-rsa/issues/159)
openssl version | grep -iq '^openssl 1\.1\.'
if [ $? -eq 0 -a -n "$KEY_CONFIG" -a ! -e $KEY_CONFIG -a -e openssl-1.0.0.cnf ]; then
    cp -p openssl-1.0.0.cnf $KEY_CONFIG
    echo '# For use with easy-rsa version 2.x and OpenSSL 1.1.0*' >> $KEY_CONFIG
    echo '# For use with easy-rsa version 2.0 and OpenSSL 1.1.0*' >> $KEY_CONFIG
fi

# Fixup the openssl.cnf files
for file in `ls -1 $EASY_RSA/openssl*.cnf | xargs` ; do
    sed -i -e 's/^\(subjectAltName=.*\)$/#\1/' $file
done

./clean-all
./build-ca
# We needed a CN for the CA build -- but now we have to drop it cause
# the build-key* scripts don't want it set -- they set it to the first arg,
# and behave badly if it IS set.
unset KEY_CN
./build-key-server $HEAD
cp -p $KEY_DIR/$HEAD.crt $KEY_DIR/$HEAD.key $KEY_DIR/ca.crt $EASY_RSA

./build-dh
cp -p $KEY_DIR/dh2048.pem $EASY_RSA

#
# Now build keys and set static IPs for the controller and the
# compute nodes.
#
for node in $NODES ; do
    nf=`getfqdn $node`
    export KEY_CN="$nf"
    ./build-key $node
done

unset KEY_COUNTRY
unset KEY_PROVINCE
unset KEY_CITY
unset KEY_ORG
unset KEY_EMAIL
unset KEY_NAME
unset KEY_OU
unset KEY_ALTNAMES

unset EASY_RSA
unset OPENSSL
unset PKCS11TOOL
unset GREP
unset KEY_CONFIG
unset PKCS11_MODULE_PATH
unset PKCS11_PIN
unset KEY_SIZE
unset CA_EXPIRE
unset KEY_EXPIRE

logtend "self-signed-ssl"
touch $OURDIR/self-signed-ssl-done
