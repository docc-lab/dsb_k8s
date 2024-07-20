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

# Clone the repository as geniuser
cd /local
git clone $REPO_URL
REPO_NAME=$(basename $REPO_URL .git)

# Pull hotelreservation docker images
docker pull $DOCKER_IMAGE


chmod -R 777 /local/DeathStarBench
chown geniuser -R /local/DeathStarBench
sudo ln -s /local/DeathStarBench /users/geniuser/
su geniuser -c "kubectl apply -f /users/geniuser/$REPO_NAME/$KUBERNETES_DIR"

echo "deathstarbench-k8s setup complete"

logtend "dsb"

touch $OURDIR/dsb-done
exit 0