#!/bin/bash

# Variables
REPO_URL="https://github.com/docc-lab/DeathStarBench.git"
DOCKER_IMAGE="deathstarbench/hotel-reservation"
KUBERNETES_DIR="hotelReservation/kubernetes"  # Path to the Kubernetes directory within the repo

echo "setup deathstarbench in k8s"

# Clone the repository as geniuser
su geniuser -c "git clone $REPO_URL"
REPO_NAME=$(basename $REPO_URL .git)

su geniuser -c "docker pull $DOCKER_IMAGE"
su geniuser -c "kubectl apply -f $REPO_NAME/$KUBERNETES_DIR"

echo "deathstarbench-k8s setup complete"