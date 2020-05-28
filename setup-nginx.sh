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

if [ -f $OURDIR/nginx-done ]; then
    exit 0
fi

logtstart "nginx"

maybe_install_packages nginx apache2-utils
# Handle case where nginx won't start because the default site (which is
# enabled!) needs port 80, and apache might be listening there.
#rm -f /etc/nginx/sites-available/default \
#    /etc/nginx/sites-enabled/default
if [ ! $? -eq 0 ]; then
    maybe_install_packages nginx
fi

echo "$ADMIN_PASS" | htpasswd -n -i admin > /etc/nginx/htpasswd
chown www-data:root /etc/nginx/htpasswd
chmod 660 /etc/nginx/htpasswd

mkdir /var/www/profile-setup
chown www-data /var/www/profile-setup
mount -o bind,ro $OURDIR /var/www/profile-setup/
echo $OURDIR /var/www/profile-setup none defaults,bind 0 0 >> /etc/fstab
cat <<EOF >/etc/nginx/sites-available/profile-setup-logs
server {
        include /etc/nginx/mime.types;
        types { text/plain log; }
        listen 7999 default_server;
        listen [::]:7999 default_server;
        root /var/www/profile-setup;
        index index.html;
        server_name _;
        location / {
                 autoindex on;
                 auth_basic "profile-setup";
                 auth_basic_user_file /etc/nginx/htpasswd;
        }
}
EOF
ln -s /etc/nginx/sites-available/profile-setup-logs \
    /etc/nginx/sites-enabled/profile-setup-logs
service_enable nginx
service_restart nginx

logtend "nginx"
touch $OURDIR/nginx-done
