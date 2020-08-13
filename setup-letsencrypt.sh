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
#cp -p /etc/letsencrypt/live/$NFQDN/*.pem /etc/nginx/ssl/
#chown -R www-data:root /etc/nginx/ssl/
#chmod 770 /etc/nginx/ssl

#
# Add a simple revocation service that runs on shutdown/reboot and if
# the node is no longer allocated, certbot revoke .
#
cat <<'EOF' >/etc/systemd/system/tbhook.service
[Unit]
Description=Testbed Hook Service
After=testbed.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c "/usr/local/etc/emulab/tmcc.bin -s boss status > /var/emulab/boot/tmcc/status"
ExecStop=/bin/sh -c '. /var/emulab/boot/tmcc/status ; if [ -z "$ALLOCATED" ]; then echo "No info from tmcd, skipping" ; exit 0 ; fi ; OLD="$ALLOCATED" ; /usr/local/etc/emulab/tmcc.bin -s boss status > /tmp/allocated ; . /tmp/allocated ; if [ -z "$ALLOCATED" ]; then echo "No updated info from tmcd, skipping" ; exit 0 ; fi ; if [ "$OLD" = "$ALLOCATED" ]; then exit 0 ; fi ; echo Revoking "letsencrypt certificate"; certbot revoke --cert-path /etc/letsencrypt/live/`cat /var/emulab/boot/nodeid`.`cat /var/emulab/boot/mydomain`/fullchain.pem -n ; exit 0'
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable tbhook
systemctl start tbhook

logtend "letsencrypt"
touch $OURDIR/letsencrypt-done
