#!/bin/bash

set -x

. "`dirname $0`/setup-lib.sh"

if [ -f $OURDIR/dsb-done ]; then
    exit 0
fi

logtstart "dsb"

# Variables
REPO_URL="https://github.com/docc-lab/DeathStarBench.git"
DOCKER_IMAGE="deathstarbench/hotel-reservation"
KUBERNETES_DIR="hotelReservation/kubernetes"  # Path to the Kubernetes directory within the repo

echo "setup deathstarbench in k8s"

# Clone the repository
cd /local
git clone $REPO_URL

# Prepare workload generator
cd /local/DeathStarBench/wrk2
git submodule update --init --recursive ./deps/luajit/
sudo apt-get update
sudo apt-get install -y libssl-dev
make all

# Pull hotelreservation docker images
sudo docker pull $DOCKER_IMAGE

# Setup kubernetes cluster
sudo kubectl apply -Rf /local/DeathStarBench/$KUBERNETES_DIR

echo "deathstarbench-k8s setup complete"

logtend "dsb"

touch $OURDIR/dsb-done
exit 0