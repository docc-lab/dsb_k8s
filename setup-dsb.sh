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
sudo bash -c "git clone $REPO_URL /local"

# Pull hotelreservation docker images
sudo docker pull $DOCKER_IMAGE

# sudo chmod -R 777 /local/DeathStarBench
# sudo ln -s /local/DeathStarBench /users/royno7/
sudo kubectl apply -Rf /local/DeathStarBench/$KUBERNETES_DIR

echo "deathstarbench-k8s setup complete"

logtend "dsb"

touch $OURDIR/dsb-done
exit 0