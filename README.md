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
