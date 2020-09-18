#!/bin/sh

set -x

# Grab our libs
. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/kubespray-done ]; then
    exit 0
fi

logtstart "kubespray"

# First, we need yq.
are_packages_installed yq
if [ ! $? -eq 1 ]; then
    $SUDO apt-key adv --keyserver keyserver.ubuntu.com --recv-keys CC86BB64
    $SUDO add-apt-repository -y ppa:rmescandon/yq
    maybe_install_packages yq
fi

cd $OURDIR
if [ -e kubespray ]; then
    rm -rf kubespray
fi
git clone $KUBESPRAYREPO kubespray
if [ -n "$KUBESPRAYVERSION" ]; then
    cd kubespray && git checkout "$KUBESPRAYVERSION" && cd ..
fi

#
# Get Ansible and the kubespray python reqs installed.
#
maybe_install_packages ${PYTHON}
if [ $KUBESPRAYUSEVIRTUALENV -eq 1 ]; then
    if [ -e $KUBESPRAY_VIRTUALENV ]; then
	. $KUBESPRAY_VIRTUALENV/bin/activate
    else
	maybe_install_packages virtualenv

	mkdir -p $KUBESPRAY_VIRTUALENV
	virtualenv $KUBESPRAY_VIRTUALENV --python=${PYTHON}
	. $KUBESPRAY_VIRTUALENV/bin/activate
    fi
    $PIP install ansible==2.7
    $PIP install -r kubespray/requirements.txt
else
    maybe_install_packages software-properties-common ${PYTHON}-pip
    $SUDO add-apt-repository --yes --update ppa:ansible/ansible
    maybe_install_packages ansible
    $PIP install -r kubespray/requirements.txt
fi

#
# Build the kubespray inventory file.  The basic builder changes our
# hostname, and we don't want that.  So do it manually.  We generate
# .ini format because it's much simpler to do in shell.
#
INVDIR=$OURDIR/inventories/kubernetes
mkdir -p $INVDIR
cp -pR kubespray/inventory/sample/group_vars $INVDIR

HEAD_MGMT_IP=`getnodeip $HEAD $MGMTLAN`
INV=$INVDIR/inventory.ini

echo '[all]' > $INV
for node in $NODES ; do
    mgmtip=`getnodeip $node $MGMTLAN`
    dataip=`getnodeip $node $DATALAN`
    if [ "$KUBEACCESSIP" = "mgmt" ]; then
	accessip="$mgmtip"
    else
	accessip=`getcontrolip $node`
    fi
    echo "$node ansible_host=$mgmtip ip=$dataip access_ip=$accessip" >> $INV
done
# The first 2 nodes are kube-master.
echo '[kube-master]' >> $INV
for node in `echo $NODES | cut -d ' ' -f-2` ; do
    echo "$node" >> $INV
done
# The first 3 nodes are etcd.
echo '[etcd]' >> $INV
for node in `echo $NODES | cut -d ' ' -f-3` ; do
    echo "$node" >> $INV
done
# The last 2--N nodes are kube-node, unless there is only one node.
kubenodecount=2
if [ "$NODES" = `echo $NODES | cut -d ' ' -f2` ]; then
    kubenodecount=1
fi
echo '[kube-node]' >> $INV
for node in `echo $NODES | cut -d ' ' -f${kubenodecount}-` ; do
    echo "$node" >> $INV
done
cat <<EOF >> $INV
[k8s-cluster:children]
kube-master
kube-node
EOF

if [ $NODECOUNT -eq 1 ]; then
    # We cannot use localhost; we have to use a dummy device, and that
    # works fine.  We need to fix things up because there is nothing in
    # /etc/hosts, nor have ssh keys been scanned and placed in
    # known_hosts.
    ip=`getnodeip $HEAD $MGMTLAN`
    nm=`getnetmask $MGMTLAN`
    prefix=`netmask2prefix $nm`
    cidr=$ip/$prefix
    echo "$ip $HEAD $HEAD-$MGMTLAN" | $SUDO tee -a /etc/hosts
    $SUDO ip link add type dummy name dummy0
    $SUDO ip addr add $cidr dev dummy0
    $SUDO ip link set dummy0 up
    DISTRIB_MAJOR=`. /etc/lsb-release && echo $DISTRIB_RELEASE | cut -d. -f1`
    if [ $DISTRIB_MAJOR -lt 18 ]; then
	cat <<EOF | $SUDO tee /etc/network/interfaces.d/kube-single-node.conf
auto dummy0
iface dummy0 inet static
    address $cidr
    pre-up ip link add dummy0 type dummy
EOF
    else
	cat <<EOF | $SUDO tee /etc/systemd/network/dummy0.netdev
[NetDev]
Name=dummy0
Kind=type
EOF
	cat <<EOF | $SUDO tee /etc/systemd/network/dummy0.network
[Match]
Name=dummy0

[Network]
DHCP=no
Address=$cidr
IPForward=yes
EOF
    fi

    ssh-keyscan $HEAD >> ~/.ssh/known_hosts
    ssh-keyscan $ip >> ~/.ssh/known_hosts
fi

#
# Get our basic configuration into place.
#
cat <<EOF >> $INVDIR/group_vars/all/all.yml
override_system_hostname: false
disable_swap: true
ansible_python_interpreter: $PYTHONBIN
ansible_user: $SWAPPER
kube_apiserver_node_port_range: 2000-36767
kubeadm_enabled: true
dns_min_replicas: 1
dashboard_enabled: true
dashboard_token_ttl: 43200
EOF
if [ -n "${DOCKERVERSION}" ]; then
    cat <<EOF >> $INVDIR/group_vars/all/all.yml
docker_version: ${DOCKERVERSION}
EOF
fi
if [ -n "${KUBEVERSION}" ]; then
    cat <<EOF >> $INVDIR/group_vars/k8s-cluster/k8s-cluster.yml
kube_version: ${KUBEVERSION}
EOF
fi
if [ -n "$KUBEFEATUREGATES" ]; then
    echo "kube_feature_gates: $KUBEFEATUREGATES" \
	>> $INVDIR/group_vars/all/all.yml
fi
if [ -n "$KUBELETCUSTOMFLAGS" ]; then
    echo "kubelet_custom_flags: $KUBELETCUSTOMFLAGS" \
	>> $INVDIR/group_vars/all/all.yml
fi
if [ -n "$KUBELETMAXPODS" -a $KUBELETMAXPODS -gt 0 ]; then
    echo "kubelet_max_pods: $KUBELETMAXPODS" \
        >> $INVDIR/group_vars/all/all.yml
fi

if [ "$KUBENETWORKPLUGIN" = "calico" ]; then
    cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_network_plugin: calico
docker_iptables_enabled: true
EOF
elif [ "$KUBENETWORKPLUGIN" = "flannel" ]; then
cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_network_plugin: flannel
EOF
elif [ "$KUBENETWORKPLUGIN" = "weave" ]; then
cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_network_plugin: flannel
EOF
elif [ "$KUBENETWORKPLUGIN" = "canal" ]; then
cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_network_plugin: canal
EOF
fi

if [ "$KUBEENABLEMULTUS" = "1" ]; then
cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_network_plugin_multus: true
multus_version: stable
EOF
fi

if [ "$KUBEPROXYMODE" = "iptables" ]; then
    cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_proxy_mode: iptables
EOF
elif [ "$KUBEPROXYMODE" = "ipvs" ]; then
    cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_proxy_mode: ipvs
EOF
fi

cat <<EOF >> $INVDIR/group_vars/all/all.yml
kube_pods_subnet: $KUBEPODSSUBNET
kube_service_addresses: $KUBESERVICEADDRESSES
EOF

#
# Enable helm, and stash its config bits in the right file.
#
grep -q helm_enabled $INVDIR/group_vars/all/all.yml
if [ $? -eq 0 ]; then
    HELM_INV_FILE=$INVDIR/group_vars/all/all.yml
else
    HELM_INV_FILE=$INVDIR/group_vars/k8s-cluster/addons.yml
fi
echo "helm_enabled: true" >> $HELM_INV_FILE
if [ -n "${HELMVERSION}" ]; then
    echo "helm_version: ${HELMVERSION}" >> $HELM_INV_FILE
fi

#
# Add a bunch of options most people will find useful.
#
DOCKOPTS='--insecure-registry={{ kube_service_addresses }} {{ docker_log_opts }}'
if [ "$MGMTLAN" = "$DATALANS" ]; then
    DOCKOPTS="--insecure-registry=`getnodeip $HEAD $MGMTLAN`/`getnetmaskprefix $MGMTLAN` $DOCKOPTS"
else
    for lan in $MGMTLAN $DATALANS ; do
	DOCKOPTS="--insecure-registry=`getnodeip $HEAD $lan`/`getnetmaskprefix $lan` $DOCKOPTS"
    done
fi
cat <<EOF >>$INVDIR/group_vars/k8s-cluster/k8s-cluster.yml
docker_dns_servers_strict: false
kubectl_localhost: true
kubeconfig_localhost: true
docker_options: "$DOCKOPTS ${DOCKEROPTIONS}"
metrics_server_enabled: true
kube_basic_auth: true
kube_api_pwd: "$ADMIN_PASS"
kube_users:
  admin:
    pass: "{{kube_api_pwd}}"
    role: admin
    groups:
      - system:masters
EOF
#kube_api_anonymous_auth: false

#
# Add MetalLB support.
#
METALLB_PLAYBOOK=
if [ "$KUBEDOMETALLB" = "1" -a $PUBLICADDRCOUNT -gt 0 ]; then
    echo "kube_proxy_strict_arp: true" >> $INVDIR/group_vars/k8s-cluster/k8s-cluster.yml
    METALLB_PLAYBOOK=contrib/metallb/metallb.yml
    cat kubespray/contrib/metallb/roles/provision/defaults/main.yml | grep -v -- --- >>$INVDIR/group_vars/k8s-cluster/addons.yml
    echo "metallb:" >/tmp/metallb.yml
    mi=0
    for pip in $PUBLICADDRS ; do
	if [ $mi -eq 0 ]; then
	    cat <<EOF >>/tmp/metallb.yml
  ip_range:
    - "$pip-$pip"
  protocol: "layer2"
EOF
	else
	    if [ $mi -eq 1 ]; then
		cat <<EOF >>/tmp/metallb.yml
  additional_address_pools:
EOF
	    fi
	    cat <<EOF >>/tmp/metallb.yml
    kube_service_pool_$mi:
      ip_range:
        - "$pip-$pip"
      protocol: "layer2"
      auto_assign: true
EOF
	fi
	mi=`expr $mi + 1`
    done
    yq m --inplace --overwrite $INVDIR/group_vars/k8s-cluster/addons.yml /tmp/metallb.yml
    rm -f /tmp/metallb.yml
fi

#
# Run ansible to build our kubernetes cluster.
#
cd $OURDIR/kubespray
ansible-playbook -i $INVDIR/inventory.ini \
    cluster.yml $METALLB_PLAYBOOK -b -v

if [ ! $? -eq 0 ]; then
    cd ..
    echo "ERROR: ansible-playbook failed; check logfiles!"
    exit 1
fi
cd ..

$SUDO rm -rf /root/.kube
$SUDO mkdir -p /root/.kube
$SUDO cp -p $INVDIR/artifacts/admin.conf /root/.kube/config

[ -d /users/$SWAPPER/.kube ] && rm -rf /users/$SWAPPER/.kube
mkdir -p /users/$SWAPPER/.kube
cp -p $INVDIR/artifacts/admin.conf /users/$SWAPPER/.kube/config
chown -R $SWAPPER /users/$SWAPPER/.kube

kubectl wait pod -n kube-system --for=condition=Ready --all

#
# If helm is not installed, do that manually.  Seems that there is a
# kubespray bug (release-2.11) that causes this.
#
which helm
if [ ! $? -eq 0 -a -n "${HELM_VERSION}" ]; then
    wget https://storage.googleapis.com/kubernetes-helm/helm-${HELM_VERSION}-linux-amd64.tar.gz
    tar -xzvf helm-${HELM_VERSION}-linux-amd64.tar.gz
    $SUDO mv linux-amd64/helm /usr/local/bin/helm

    helm init --upgrade --force-upgrade
    kubectl create serviceaccount --namespace kube-system tiller
    kubectl create clusterrolebinding tiller-cluster-rule --clusterrole=cluster-admin --serviceaccount=kube-system:tiller
    kubectl patch deploy --namespace kube-system tiller-deploy -p '{"spec":{"template":{"spec":{"serviceAccount":"tiller"}}}}'
    helm init --service-account tiller --upgrade
    while [ 1 ]; do
	helm ls
	if [ $? -eq 0 ]; then
	    break
	fi
	sleep 4
    done
    kubectl wait pod -n kube-system --for=condition=Ready --all
fi

logtend "kubespray"
touch $OURDIR/kubespray-done
