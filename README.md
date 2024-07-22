# Instruction Steps

1. Use the profile to create an experiment.
2. Check if there is a `DeathStarBench` repository under `/local`. 
   1. If not, manually clone `DeathStarBench` under `docclab`:
   ```bash
   git clone https://github.com/docc-lab/DeathStarBench.git
   ```
   2. It should work under my user (royno7), and root at least. If it doesn't work under your user, su to mine or root.
3. Check if hotelreservation image is pulled
   ```bash
   docker images | grep hotel-reservation
   ```
   1. If not, pull the `hotelreservation` Docker image:
   ```bash
   docker pull deathstarbench/hotel-reservation
   ```
4. Check if pods are running in kubernetes
   ```bash
   kubectl get pods
   ```
   1. If not, apply the Kubernetes configurations:
   ```bash
   kubectl apply -Rf /local/DeathStarBench/hotelreservation/kubernetes
   ```

5. Run workload generator 
   1. Find IP address of services
   ```bash
   kubectl get services | grep frontend
   ```
   2. Update URL written in wrk2 script
   ```bash
   nano /local/DeathStarBench/hotelReservation/wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua
   ```
   3. Copy files into standalone pod (called hr-client)
   ```bash
   hrclient=$(kubectl get pod | grep hr-client | cut -f 1 -d " ")
   kubectl cp /local/DeathStarBench "${hrclient}":/home -c hr-client
   ```
   4. Enter the pod to run workload generator
   ```bash
   kubectl exec -it deployment/hr-client -- /bin/bash
   ```
   After entering client pod
   ```bash
   cd /home/DeathStarBench/hotelReservation
   ../wrk2/wrk -D exp -t 2 -c 2 -d 30 -L -s ./wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua http://<replace with frontend ip in I. >:5000 -R 2
   ```
