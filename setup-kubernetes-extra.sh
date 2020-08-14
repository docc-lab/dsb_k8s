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

if [ -f $OURDIR/kubernetes-extra-done ]; then
    exit 0
fi

logtstart "kubernetes-extra"

# Create a localhost kube-proxy service and fire it off.
cat <<'EOF' >/etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Local Proxy Service
After=kubelet.service

[Service]
Type=simple
Restart=always
User=root
ExecStart=/bin/sh -c "kubectl proxy --accept-hosts='.*' --address=127.0.0.1 --port=8888"
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable kube-proxy
systemctl start kube-proxy

# Expose the dashboard IFF we have a certificate configuration
if [ ! "$SSLCERTTYPE" = "none" -a "$SSLCERTCONFIG" = "proxy" ]; then
    if [ "$SSLCERTTYPE" = "self" ]; then
	certpath="/etc/ssl/easy-rsa/${NFQDN}.crt"
	keypath="/etc/ssl/easy-rsa/${NFQDN}.key"
    elif [ "$SSLCERTTYPE" = "letsencrypt" ]; then
	certpath="/etc/letsencrypt/live/${NFQDN}/fullchain.pem"
	keypath="/etc/letsencrypt/live/${NFQDN}/privkey.pem"
    fi
    cat <<EOF >/etc/nginx/sites-available/k8s-dashboard
map \$http_upgrade \$connection_upgrade {
        default Upgrade;
        ''      close;
}

server {
        listen 8080 ssl;
        listen [::]:8080 ssl;
        ssl_certificate_key ${certpath};
        ssl_certificate ${keypath};
        server_name _;
        location / {
                 proxy_set_header Host \$host;
                 proxy_set_header X-Forwarded-Proto \$scheme;
                 proxy_set_header X-Forwarded-Port \$server_port;
                 proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
                 proxy_set_header X-Real-IP \$remote_addr;
                 proxy_pass http://localhost:8888;
                 proxy_http_version 1.1;
                 proxy_set_header Upgrade \$http_upgrade;
                 proxy_set_header Connection \$connection_upgrade;
                 proxy_read_timeout 900s;
        }
}
EOF
    ln -sf /etc/nginx/sites-available/k8s-dashboard \
        /etc/nginx/sites-enabled/k8s-dashboard
    systemctl restart nginx
fi

# Generate a cluster-wide token for an admin account, and dump it into
# the profile-setup web dir.
kubectl create serviceaccount admin -n default
kubectl create clusterrolebinding cluster-default-admin --clusterrole=cluster-admin --serviceaccount=default:admin
secretid=`kubectl get serviceaccount admin -n default -o 'go-template={{(index .secrets 0).name}}'`
token=`kubectl get secrets $secretid -o 'go-template={{.data.token}}' | base64 -d`
echo -n "$token" > $OURDIR/admin-token.txt
chmod 644 $OURDIR/admin-token.txt

# Make kubeconfig and token available in profile-setup web dir.
cp -p ~/.kube/config $OURDIR/kubeconfig
chmod 644 $OURDIR/kubeconfig

logtend "kubernetes-extra"
touch $OURDIR/kubernetes-extra-done
exit 0
