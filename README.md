# Instruction Steps

1. Use the profile to create an experiment.
2. Switch to the `geniuser`:
   ```bash
   sudo su geniuser
   ```
   Check if there is a `DeathStarBench` repository in its user directory. If not, manually clone `DeathStarBench` under `docclab`:
   ```bash
   git clone https://github.com/docc-lab/DeathStarBench.git
   ```
3. Pull the `hotelreservation` Docker image:
   ```bash
   docker pull deathstarbench/hotel-reservation
   ```
4. Apply the Kubernetes configurations:
   ```bash
   kubectl apply -Rf ./DeathStarBench/hotelreservation/kubernetes
   ```
