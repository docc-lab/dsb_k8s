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

if [ -f $OURDIR/kubespray-done ]; then
    exit 0
fi

logtstart "kubespray"

cd $OURDIR
if [ -e kubespray ]; then
    rm -rf kubespray
fi
git clone $KUBESPRAY_REPO kubespray
if [ -n "$KUBESPRAY_VERSION" ]; then
    cd kubespray && git checkout "$KUBESPRAY_VERSION" && cd ..
fi

#
# Get Ansible and the kubespray python reqs installed.
#
maybe_install_packages ${PYTHON}
if [ $KUBESPRAY_USE_VIRTUALENV -eq 1 ]; then
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
    add-apt-repository --yes --update ppa:ansible/ansible
    maybe_install_packages ansible
    $PIP install -r kubespray/requirements.txt
fi

#
# Build the kubespray inventory file.  The basic builder changes our
# hostname, and we don't want that.  So do it manually.  We generate
# .ini format because it's much simpler to do in shell.
#
mkdir -p inventories/emulab
cp -pR kubespray/inventory/sample/group_vars inventories/emulab

INVDIR=inventories/emulab
INV=$INVDIR/inventory.ini
echo '[all]' > $INV
for node in $NODES ; do
    mgmtip=`getnodeip $node $MGMTLAN`
    dataip=`getnodeip $node $DATALANS`
    echo "$node ansible_host=$mgmtip ip=$dataip access_ip=$mgmtip" >> $INV
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

cat <<EOF >> $INVDIR/group_vars/all/all.yml
override_system_hostname: False
disable_swap: True
ansible_python_interpreter: /usr/bin/python2.7
ansible_user: root
ansible_become: true
docker_version: ${DOCKER_VERSION}
docker_iptables_enabled: True
kube_version: ${K8S_VERSION}
kube_feature_gates: [SCTPSupport=true]
kube_network_plugin: calico
kube_network_plugin_multus: true
multus_version: stable
kube_proxy_mode: iptables
kube_pods_subnet: 192.168.0.0/17
kube_service_addresses: 192.168.128.0/17
kube_apiserver_node_port_range: 2000-36767
kubeadm_enabled: True
kubelet_custom_flags: [--allowed-unsafe-sysctls=net.*]
dns_min_replicas: 1
helm_enabled: True
helm_version: ${HELM_VERSION}
EOF

DOCKOPTS='--insecure-registry={{ kube_service_addresses }}  {{ docker_log_opts }}'
for lan in $DATALANS ; do
    DOCKOPTS="--insecure-registry=`getnodeip node-0 $lan`/`getnetmaskprefix $lan` $DOCKOPTS"
done
cat <<EOF >>$INVDIR/group_vars/k8s-cluster/k8s-cluster.yml
docker_dns_servers_strict: false
kubectl_localhost: true
kubeconfig_localhost: true
docker_options: "$DOCKOPTS"
metrics_server_enabled: true
kube_basic_auth: true
kube_api_pwd: $ADMIN_PASS
EOF

ansible-playbook -i inventories/emulab/inventory.ini \
    kubespray/cluster.yml -b -v

mkdir /root/.kube
mkdir ~$SWAPPER/.kube
cp -p $INVDIR/artifacts/admin.conf /root/.kube/config
cp -p $INVDIR/artifacts/admin.conf ~$SWAPPER/.kube/config
chown $SWAPPER ~$SWAPPER/.kube/config

kubectl wait pod -n kube-system --for=condition=Ready --all

#
# If helm is not installed, do that manually.  Seems that there is a
# kubespray bug (release-2.11) that causes this.
#
which helm
if [ ! $? -eq 0 ]; then
    wget https://storage.googleapis.com/kubernetes-helm/helm-${HELM_VERSION}-linux-amd64.tar.gz
    tar -xzvf helm-${HELM_VERSION}-linux-amd64.tar.gz
    mv linux-amd64/helm /usr/local/bin/helm

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
