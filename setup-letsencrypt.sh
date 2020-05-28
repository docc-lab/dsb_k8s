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

if [ -f $OURDIR/letsencrypt-done ]; then
    exit 0
fi

logtstart "letsencrypt"

maybe_install_packages python-certbot-nginx
certbot certonly -d $NFQDN --nginx --agree-tos -m "$SWAPPER_EMAIL" -n
mkdir -p /etc/nginx/ssl
cp -p /etc/letsencrypt/live/$NFQDN/*.pem /etc/nginx/ssl/
chown -R www-data:root /etc/nginx/ssl/
chmod 770 /etc/nginx/ssl

logtend "letsencrypt"
touch $OURDIR/letsencrypt-done
