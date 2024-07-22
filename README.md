# DSB HotelReservation K8S usage

1. Use the profile to create an experiment.
   1.  It should work under my user (royno7), and root at least. If it doesn't work under your user, su to mine or root after experiment setup and run "if not" cmds in step 2.
2. Check if several stuff
   1. If there is a `DeathStarBench` repository under `/local`.
      If not, manually clone `DeathStarBench` under `docclab`:
      ```bash
      git clone https://github.com/docc-lab/DeathStarBench.git
      ```
   2. Check if hotelreservation image is pulled
      ```bash
      docker images | grep hotel-reservation
      ```
      If not, pull the `hotelreservation` Docker image:
      ```bash
      docker pull deathstarbench/hotel-reservation
      ```
   3. Check if pods are running in kubernetes
      ```bash
      kubectl get pods
      ```
      If not, apply the Kubernetes configurations:
      ```bash
      kubectl apply -Rf /local/DeathStarBench/hotelreservation/kubernetes
      ```
   4. Check if there is wrk executable under /local/DeathStarBench/wrk2
      If not, build from src
      ```bash
      cd /local/DeathStarBench/wrk2
      git submodule update --init --recursive ./deps/luajit/
      sudo apt-get update
      sudo apt-get install -y libssl-dev
      make all
      ```

3. Run workload generator 
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

4. Jaeger Trace
   ```bash
   http://<jaeger service IP>:6831
   ```
   Note that all IPs in k8s cluster are not accessible from outside as CloudLab only provides a few public IPs per experiment.
   So if you want to check Jaeger UI, extra steps to setup graphic ssh to use browser are required on both your local and remote machine. I'll leave this part on **your** own.