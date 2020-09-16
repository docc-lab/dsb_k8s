#!/bin/sh

set -x

# Grab our libs
BINDIR=`dirname $0`
. "$BINDIR/setup-lib.sh"

if [ -f $OURDIR/ssl-done ]; then
    exit 0
fi

logtstart "ssl"

if [ -z "$SSLCERTTYPE" ]; then
    echo "No SSL certs requested"
elif [ "$SSLCERTTYPE" = "self" ]; then
    $BINDIR/setup-self-signed-ssl.sh
elif [ "$SSLCERTTYPE" = "letsencrypt" ]; then
    $BINDIR/setup-letsencrypt.sh
fi

logtend "ssl"
touch $OURDIR/ssl-done
