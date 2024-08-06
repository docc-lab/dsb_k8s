# DSB HotelReservation K8S profile usage

## A. Use the profile to create an experiment.

   The cloudlab profile is called hotelreserv-k8s-setup [link](https://www.cloudlab.us/p/Tracing-Pythia/hotelreserv-k8s-setup).
   It should work under my user (royno7), and root at least. If it doesn't work under your user, su to mine or root after experiment setup and run "if not" cmds in step B.

## B. Check if several stuff before proceeding forward

   1. Check if there is a `DeathStarBench` repository under `/local`.

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

## C. (Optional) Build and use your own docker images from src

   1. Build HotelReservation executable from src

      ```bash
      cd /local/DeathStarBench/hotelreservation
      make bin
      ```

   2. Build images from current filesystem
      Before executing following cmds, take a look at `build-docker-images.sh` script to accomendate your needs, including
      - `--no-cache` to build images w/t using any cached layers.
      - `--push` to push image to docker hub (user variable in script and extra auth with `docker login` are required)
      - `--output type=docker` to output image to local image store instead of pushing.
      - `--cache-from` to specifies external cache source for build
      - etc...
      Then use the script to build images

      ```bash
      cd /local/DeathStarBench/hotelreservation/kubernetes/scripts
      ./build-docker-images.sh
      ```

   3. Update yamls

      ```bash
      cd /local/DeathStarBench/hotelreservation/kubernetes/scripts
      ./update-yamls.sh
      ```

   4. Apply updated yamls in k8s, and continue to step D

      ```bash
      kubectl apply -Rf /local/DeathStarBench/hotelReservation/kubernetes
      ```

## D. Run workload generator

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

      After entering client pod, execute following cmd (there is placeholder for frontend's IP inline, don't forget to change it)

      ```bash
      cd /home/DeathStarBench/hotelReservation
      ../wrk2/wrk -D exp -t 2 -c 2 -d 30 -L -s ./wrk2/scripts/hotel-reservation/mixed-workload_type_1.lua http://<FRONTEND_IP_IN_STEP_D.1>:5000 -R 2
      ```

## E. Check Jaeger Trace

   1. (Recommended) Via Jaeger web UI with port forwarding

      Note that all IPs in k8s cluster are not accessible from outside as CloudLab only provides a few public IPs per experiment.
      You can either setup port forwarding from k8s controler node to your local as the following (or use graphic ssh, see step E.2).

      ```bash
      ssh  -L 16686:localhost:16686 -i <PATH_TO_YOUR_KEY>  <YOUR_CLOUDLAB_USERID>@<HOST_FOR_NODE_0> ‘kubectl port-forward deployment/jaeger 16686:16686’
      ```

      Then you'll be able to see Jaeger web UI by visiting `http://localhost:16686/` with browser in your local.

   2. Via Jaeger web UI with graphic ssh

      ```bash
      http://<jaeger service IP>:16686
      ```

      Note that all IPs in k8s cluster are not accessible from outside as CloudLab only provides a few public IPs per experiment.
      So if you want to check Jaeger UI with graphic ssh, extra steps to setup graphic ssh to use browser are required on both your local and remote machine. I'll leave this part on your own.

   3. Via api
