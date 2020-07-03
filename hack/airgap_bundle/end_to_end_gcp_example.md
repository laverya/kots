### Appendix: End to End GCP example

We'll set up these 3 instances in GCP. Unless otherwise specified, all commands are being run from a MacOS workstation outside this environment.

```
dex-airgap-jump                                      us-central1-b  n1-standard-1                10.240.0.127  35.193.94.81     RUNNING
dex-airgap-cluster                                   us-central1-b  n1-standard-1                10.240.0.41                    RUNNING
dex-airgap-workstation                               us-central1-b  n1-standard-1                10.240.0.26                    RUNNING
```


**Note**: This guide does a lot of network configuration for address management, but omits any details regarding opening ports. While you could open specific ports between instances, this guide was written with inter-instance traffic wide open.

We'll use ssh tunneling for reaching the instances in the cluster, so it shouldn't be necessary to open ports for access from the outside world.

#### jump box

Create an jump box with a public IP and SSH it, this will be our jump box w/ internet access and also access to the airgapped environment


```
export INSTANCE=dex-airgap-jump
gcloud compute instances create $INSTANCE --boot-disk-size=200GB --image-project ubuntu-os-cloud --image-family ubuntu-1804-lts --machine-type n1-standard-1
```

#### airgapped workstation

create a GCP vm to be our airgapped workstation. We'll give it outbound network access for now to facilitate installing docker, but then we'll disconnect it from the internet. Replace `dex` in the `usermod` command with your unix username in GCP.


```shell script
export INSTANCE=dex-airgap-workstation; gcloud compute instances create $INSTANCE --boot-disk-size=200GB --image-project ubuntu-os-cloud --image-family ubuntu-1804-lts --machine-type n1-standard-1 
```

```shell script
export LINUX_USER=dex
gcloud compute ssh dex-airgap-workstation -- 'sudo apt update && sudo apt install -y docker.io'
gcloud compute ssh dex-airgap-workstation -- "sudo usermod -aG docker ${LINUX_USER}"
gcloud compute ssh dex-airgap-workstation -- 'sudo snap install kubectl --classic'
```

Next, remove the machine's public IP. 

```shell script
gcloud compute instances delete-access-config dex-airgap-workstation
```

verify that internet access was disabled by ssh'ing via the jump box and trying to curl kubernetes.io. We'll forward the agent so that we can ssh the airgapped workstation without moving keys around

```shell script
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh dex-airgap-workstation 'curl -v https://kubernetes.io'"
```

this command should hang, and you should see something with `Network is unreachable`:

```text
  0     0    0     0    0     0      0      0 --:--:--  0:00:02 --:--:--     0*   Trying 2607:f8b0:4001:c05::64...
* TCP_NODELAY set
* Immediate connect fail for 2607:f8b0:4001:c05::64: Network is unreachable
  0     0    0     0    0     0      0      0 --:--:--  0:00:03 --:--:--     0
```


#### airgapped cluster with registry

create a GCP vm with online internet access, this will be our airgapped cluster, but we'll use a an internet connection to install k8s and get a registry up and running.

```shell script
INSTANCE=dex-airgap-cluster; gcloud compute instances create $INSTANCE --boot-disk-size=200GB --image-project ubuntu-os-cloud --image-family ubuntu-1804-lts --machine-type n1-standard-4 
```

 Before installing Docker and Kubernetes, let's get the private IP and set it as an insecure docker registry

```shell script
export CLUSTER_PRIVATE_IP=$(gcloud compute instances describe dex-airgap-cluster --format='get(networkInterfaces[0].networkIP)')
# verify
echo ${CLUSTER_PRIVATE_IP}
```

```shell script
 gcloud compute ssh dex-airgap-cluster -- "sudo mkdir -p /etc/docker"
 gcloud compute ssh dex-airgap-cluster -- "echo \"{\\\"insecure-registries\\\":[\\\"${CLUSTER_PRIVATE_IP}:32000\\\"]}\" | sudo tee /etc/docker/daemon.json"
```


Now, let's ssh into the instance and bootstrap a minimal kubernetes cluster (details here:  https://kurl.sh/1010f0a  )

```shell script
gcloud compute ssh dex-airgap-cluster -- 'curl  https://k8s.kurl.sh/1010f0a  | sudo bash'
```

deploy a minimal registry and verify it's running

```shell script
gcloud compute ssh dex-airgap-cluster -- 'kubectl --kubeconfig ./admin.conf apply -f https://gist.githubusercontent.com/dexhorthy/7a3e6eb119d2d90ff7033a78151c3be2/raw/6c67f95367988d1a016635e3da689e2d998d458c/plain-registry.yaml'
```

This gist configures a basic auth htpasswd that configures a username/password for `kots/kots`, which we'll use later

```shell script
gcloud compute ssh dex-airgap-cluster -- 'kubectl --kubeconfig ./admin.conf get pod,svc -n registry'
```

Now that the registry is up, let's verify that we can docker push/pull to it. We'll use the public IP attached to the instance.

```text
export INSTANCE_IP=34.66.168.81
docker login --username kots --password kots ${INSTANCE_IP}:32000
docker pull busybox
docker tag busybox ${INSTANCE_IP}:32000/busybox
docker push ${INSTANCE_IP}:32000/busybox
```

you may need to also add an `insecure-registy` entry to allow pushing/pulling via http instead of https. If you're testing from docker-for-mac, you can add this via the setttings:

![insecure registry](./img/insecure-registry.png)


Next, remove the machine's public IP. We'll use the kubeconfig from this server later.

```shell script
gcloud compute instances delete-access-config dex-airgap-cluster
```

verify that internet access was disabled by ssh'ing via the jump box and trying to curl kubernetes.io. We'll forward the agent so that we can ssh the airgapped cluster without moving keys around

```shell script
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh dex-airgap-cluster 'curl -v https://kubernetes.io'"
```

this command should hang, and you should see something with `Network is unreachable`:

```text
  0     0    0     0    0     0      0      0 --:--:--  0:00:02 --:--:--     0*   Trying 2607:f8b0:4001:c05::64...
* TCP_NODELAY set
* Immediate connect fail for 2607:f8b0:4001:c05::64: Network is unreachable
  0     0    0     0    0     0      0      0 --:--:--  0:00:03 --:--:--     0
```


#### Final Workstation Setup


Now, let's very our docker client on the workstation and make sure we have kubectl access properly configured before we do the full installation. We'll do by ssh'ing the workstation via the jump box

###### Docker

First, let's get the IP address of our airgapped cluster so we can configure an insecure registry on the airgapped workstation:


Next, we can create a docker daemon config to trust this registry from the workstation and from the cluster. First, let's quickly verify that no existing daemon json config exists on the workstation (if it does, you'll have to modify the next step slightly to just add the registry setting)

```shell script
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh dex-airgap-workstation 'cat /etc/docker/daemon.json'"
```

Next, we can create a config with the insecure registry, then restart docker


```shell script
 gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh dex-airgap-workstation 'echo \"{\\\"insecure-registries\\\":[\\\"${CLUSTER_PRIVATE_IP}:32000\\\"]}\" | sudo tee /etc/docker/daemon.json'"
 gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh dex-airgap-workstation -- sudo systemctl restart docker"
```

Before proceeding, re-run the following command until docker has come back up:

```shell script script
 gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh dex-airgap-workstation -- docker image ls"
```

and you see

```shell script
REPOSITORY          TAG                 IMAGE ID            CREATED             SIZE
```



We can verify connectivity with a login + pull of the image we previously pushed

```shell script
 gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh dex-airgap-workstation -- docker login ${CLUSTER_PRIVATE_IP}:32000 --username kots --password kots"

# note we've hard-coded the IP here, not using the env var
 gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh dex-airgap-workstation -- docker pull ${CLUSTER_PRIVATE_IP}:32000/busybox:latest"
```


should see something like 

```text
latest: Pulling from busybox
91f30d776fb2: Pulling fs layer
91f30d776fb2: Verifying Checksum
91f30d776fb2: Download complete
91f30d776fb2: Pull complete
Digest: sha256:2131f09e4044327fd101ca1fd4043e6f3ad921ae7ee901e9142e6e36b354a907
Status: Downloaded newer image for 10.240.0.100:32000/busybox:latest
10.240.0.100:32000/busybox:latest
```

###### Kubectl

next, ssh into the airgapped worksation and grab the `admin.conf` from the cluster and run a few kubectl commands to ensure its working

```shell script
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- 'ssh -A dex-airgap-workstation'
```

From the Airgapped workstation, run the following:

```shell script
scp dex-airgap-cluster:admin.conf .
export KUBECONFIG=$PWD/admin.conf
kubectl get ns
kubectl get pod -n kube-system
```

Should see something like

```
NAME                                   READY   STATUS    RESTARTS   AGE
coredns-5644d7b6d9-j6gqs               1/1     Running   0          15m
coredns-5644d7b6d9-s7q64               1/1     Running   0          15m
etcd-dex-airgap-2                      1/1     Running   0          14m
kube-apiserver-dex-airgap-2            1/1     Running   0          14m
kube-controller-manager-dex-airgap-2   1/1     Running   0          13m
kube-proxy-l6fw8                       1/1     Running   0          15m
kube-scheduler-dex-airgap-2            1/1     Running   0          13m
weave-net-7nf4z                        2/2     Running   0          15m
```

Now -- log out of the airgapped instance

```shell script
exit
```

###### Namespace and Secret

One of the prerequisites for the installer is a namespace with an existing pull secret for the install, let's create those now:


```shell script
export NAMESPACE=test-deploy
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh -A dex-airgap-workstation -- /snap/bin/kubectl --kubeconfig=admin.conf create namespace ${NAMESPACE}"
```

Should show

```text
namespace/test-deploy created
```

Next, let's make a secret for our registry

```shell script
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh -A dex-airgap-workstation -- /snap/bin/kubectl --kubeconfig=admin.conf -n $NAMESPACE create secret  docker-registry registry-creds --docker-server=${CLUSTER_PRIVATE_IP}:32000 --docker-username=kots --docker-password=kots --docker-email=a@b.c"
```

We should see

```text
secret/registry-creds
```

#### Installing

From the Jump box, download the kots bundle from S3 and scp it to the airgapped workstation. In a "full airgap" or "sneakernet" scenario, replace `scp` with whatever process is appropriate for moving assets into the airgapped cluster.

```shell script
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- 'wget https://kots-experimental.s3.amazonaws.com/kots-v1.16.1-airgap-experimental-alpha3.tar.gz'
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- 'scp kots-v1.16.1-airgap-experimental-alpha3.tar.gz dex-airgap-workstation:'
```

Now, we're ready to untar the bundle and run the install script:


```shell script
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- 'ssh dex-airgap-workstation tar xvf kots-v1.16.1-airgap-experimental-alpha3.tar.gz'
```


Should print

```text

./
./support-bundle
./troubleshoot/
./LICENSE
./images/
./install.sh
./README.md
./kots
./yaml/
./yaml/kotsadm.yaml
./images/kotsadm-kotsadm-migrations-v1.16.1.tar
./images/postgres-10.7.tar
./images/kotsadm-kotsadm-operator-v1.16.1.tar
./images/kotsadm-kotsadm-api-v1.16.1.tar
./images/kotsadm-kotsadm-v1.16.1.tar
./images/kotsadm-minio-v1.16.1.tar
./troubleshoot/support-bundle.yaml
```

Next, let's run it with our parameters, passing the registry IP, namespace we created, and name of the registry secret:

```shell script
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh dex-airgap-workstation -- KUBECONFIG=./admin.conf PATH=${PATH}:/snap/bin ./install.sh ${CLUSTER_PRIVATE_IP}:32000 ${NAMESPACE} registry-creds "
```


Full output should look something like


```text


==========
Checking for prerequisites: namespace exists, with image pull secret, and registry push credentials are valid
==========
SUCCESS: namespace "test-deploy" exists
SUCCESS: secret "registry-creds" exists
SUCCESS: no push credentials provided, skipping docker login.
Error from server (NotFound): deployments.apps "kotsadm-api" not found
SUCCESS: it appears that namespace "test-deploy" does not contain any existing KOTS resources from a previous deploy

==========
preparing kustomization
==========
    MIGRATIONS_POD_NAME=kotsadm-migrations-1593530428
    AUTO_CREATE_CLUSTER_TOKEN=WnMVWPwhrabyAmbu
SUCCESS: valid kustomization yaml created in ./yaml

==========
loading docker images
==========
Loaded image: kotsadm/kotsadm-api:v1.16.1
Loaded image: kotsadm/kotsadm-migrations:v1.16.1
Loaded image: kotsadm/kotsadm-operator:v1.16.1
Loaded image: kotsadm/kotsadm:v1.16.1
Loaded image: kotsadm/minio:v1.16.1
Loaded image: postgres:10.7

==========
tagging and pushing to 10.240.0.88:32000
==========
The push refers to repository [10.240.0.88:32000/kotsadm-api]
9906809c4536: Preparing
64e44f6ee017: Preparing
64fb7723a8c9: Preparing
...
```


### Connecting to KOTS

Now that we're installed, we need to connect in. We'll use a NodePort and an ssh tunnel, but based on your cluster you could also create an ingress or access via a kubectl port-forward if you have access from a workstation.

First though, we'll reset the password:

```shell script
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- ssh dex-airgap-workstation -- KUBECONFIG=./admin.conf ./kots reset-password -n "${NAMESPACE}"
```

Enter any password you like:

```text
  • Reset the admin console password for test-deploy
Enter a new password to be used for the Admin Console: █
Enter a new password to be used for the Admin Console: ••••••••
  • The admin console password has been reset
```

Now, we'll create a node port to expose the service


```shell script
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- ssh dex-airgap-workstation -- KUBECONFIG=./admin.conf /snap/bin/kubectl -n "${NAMESPACE}" expose deployment kotsadm --name=kotsadm-nodeport --port=3000 --target-port=3000 --type=NodePort
```

Next, we need to get the port and expose it locally via an SSH tunnel

```shell script
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- ssh dex-airgap-workstation -- KUBECONFIG=./admin.conf /snap/bin/kubectl -n "${NAMESPACE}" get svc kotsadm-nodeport
```

Asumming this is our output, we'll set the `PORT` to `40038`

```shell script
NAME               TYPE       CLUSTER-IP   EXTERNAL-IP   PORT(S)          AGE
kotsadm-nodeport   NodePort   10.96.3.54   <none>        3000:40038/TCP   6s
```

Create a SSH tunnel on your laptop via the Jumpbox node.

```shell script
export GCLOUD_USER=dex
export JUMPBOX_PUBLIC_IP=35.193.94.87
export PORT=40038
ssh -N -L ${PORT}:${CLUSTER_PRIVATE_IP}:${PORT}  ${GCLOUD_USER}@${JUMPBOX_PUBLIC_IP}
```


Now, open `localhost:${PORT}` in your browser and you should get to the kotsadm console

### Cleaning up

To clean up, delete the servers in question

```shell script
gcloud compute instances delete dex-airgap-cluster dex-airgap-jump dex-airgap-workstation
```
