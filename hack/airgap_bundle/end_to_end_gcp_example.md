### Appendix: End to End GCP example

We'll set up these 3 instances in GCP. Unless otherwise specified, all commands are being run from a MacOS workstation outside this environment.

```
dex-airgap-jump                                      us-central1-b  n1-standard-1                10.240.0.127  35.193.94.81     RUNNING
dex-airgap-cluster                                   us-central1-b  n1-standard-1                10.240.0.41                    RUNNING
dex-airgap-workstation                               us-central1-b  n1-standard-1                10.240.0.26                    RUNNING
```
#### jump box

Create an jump box with a public IP and SSH it, this will be our jump box w/ internet access and also access to the airgapped environment


```
export INSTANCE=dex-airgap-jump
gcloud compute instances create $INSTANCE --boot-disk-size=200GB --image-project ubuntu-os-cloud --image-family ubuntu-1804-lts --machine-type n1-standard-1
```

#### airgapped workstation

create a GCP vm to be our airgapped workstation. We'll give it outbound network access for now to facilitate installing docker, but then we'll disconnect it from the internet. Replace `dex` in the `usermod` command with your unix username in GCP.


```shell
export INSTANCE=dex-airgap-workstation; gcloud compute instances create $INSTANCE --boot-disk-size=200GB --image-project ubuntu-os-cloud --image-family ubuntu-1804-lts --machine-type n1-standard-1 
```

```shell
gcloud compute ssh dex-airgap-workstation -- 'sudo apt update && sudo apt install docker.io'
gcloud compute ssh dex-airgap-workstation -- 'sudo usermod -aG docker dex'
gcloud compute ssh dex-airgap-workstation -- 'sudo snap install kubectl --classic'
```

Next, remove the machine's public IP. We'll use the kubeconfig from this server later.

```shell
gcloud compute instances delete-access-config dex-airgap-workstation
```

verify that internet access was disabled by ssh'ing via the jump box and trying to curl kubernetes.io. We'll forward the agent so that we can ssh the airgapped workstation without moving keys around

```shell
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

```shell
INSTANCE=dex-airgap-cluster; gcloud compute instances create $INSTANCE --boot-disk-size=200GB --image-project ubuntu-os-cloud --image-family ubuntu-1804-lts --machine-type n1-standard-4 
```

ssh into the insttance and bootstrap a minimal kubernetes cluster (details here:  https://kurl.sh/1010f0a  )

```shell
gcloud compute ssh dex-airgap-cluster -- 'curl  https://k8s.kurl.sh/1010f0a  | sudo bash'
```

deploy a minimal registry and verify it's running

```shell
gcloud compute ssh dex-airgap-cluster -- 'kubectl --kubeconfig ./admin.conf apply -f https://gist.githubusercontent.com/dexhorthy/7a3e6eb119d2d90ff7033a78151c3be2/raw/6c67f95367988d1a016635e3da689e2d998d458c/plain-registry.yaml'
```

This gist configures a basic auth htpasswd that configures a username/password for `kots/kots`, which we'll use later

```shell
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

```ssh
gcloud compute instances delete-access-config dex-airgap-cluster
```

verify that internet access was disabled by ssh'ing via the jump box and trying to curl kubernetes.io. We'll forward the agent so that we can ssh the airgapped cluster without moving keys around

```shell
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh dex-airgap-cluster 'curl -v https://kubernetes.io'"
```

this command should hang, and you should see something with `Network is unreachable`:

```text
  0     0    0     0    0     0      0      0 --:--:--  0:00:02 --:--:--     0*   Trying 2607:f8b0:4001:c05::64...
* TCP_NODELAY set
* Immediate connect fail for 2607:f8b0:4001:c05::64: Network is unreachable
  0     0    0     0    0     0      0      0 --:--:--  0:00:03 --:--:--     0
```


#### Final Setup

Now, let's very our docker client on the workstation and make sure we have kubectl access properly configured before we do the full installation.

First, let's get the IP address of our airgapped cluster so we can configure an insecure registry on the airgapped workstation:

```shell
export CLUSTER_PRIVATE_IP=$(gcloud compute instances describe dex-airgap-cluster --format='get(networkInterfaces[0].networkIP)')
# verify
echo ${CLUSTER_PRIVATE_IP}
```

Next, we can create a docker daemon config to trust this registry from the workstation and from the cluster. First, let's quickly verify that no existing daemon json config exists on the workstation (if it does, you'll have to modify the next step slightly to just add the registry setting)

```shell
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh dex-airgap-workstation 'cat /etc/docker/daemon.json'"
```

Next, we can create a config with the insecure registry

```shell
 gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh dex-airgap-workstation 'echo \"{\\\"insecure-registries\\\":[\\\"${CLUSTER_PRIVATE_IP}:32000\\\"]}\" | sudo tee /etc/docker/daemon.json'"
```

We can verify connectivity with a login + pull of the image we previously pushed

```shell
 gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh dex-airgap-workstation -- sudo docker login ${CLUSTER_PRIVATE_IP}:32000 --username kots --password kots"

 gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh dex-airgap-workstation -- sudo docker login ${CLUSTER_PRIVATE_IP}:32000 --username kots --password kots"


```

####

From the Jump box, download the kots bundle from S3 and scp it to the airgapped workstation. In a "full airgap" or "sneakernet" scenario, replace `scp` with whatever process is appropriate for moving assets into the airgapped cluster.

```shell
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- 'curl -fSsL https://kots-experimental.s3.amazonaws.com/kots-v1.16.1-airgap-experimental-alpha2.tar.gz'
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- 'scp kots-v1.16.1-airgap-experimental-alpha2.tar.gz dex-airgap-workstation:'
```

next, ssh into the airgapped worksation and grab the `admin.conf` from the cluster and run a few kubectl commands to ensure its working

```shell
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- 'ssh dex-airgap-workstation'
```

```shell
dex@dex-airgapped-workstation:~$ scp dex-airgapped-cluster:admin.conf .
dex@dex-airgapped-workstation:~$ export KUBECONFIG=$PWD/admin.conf
dex@dex-airgapped-workstation:~$ kubectl get ns
dex@dex-airgapped-workstation:~$ kubectl get pod -n kube-system
```


(this guide assumes kubectl and docker already exist on the `kubectl`-ing workstation, I used `` in this case)

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

should also make sure we can `docker image ls` or `sudo docker image ls` from the controlling workstation, in this case our Airgapped Workstation

```
REPOSITORY          TAG                 IMAGE ID            CREATED             SIZE
```


Next, grab our bundle output from the build script and scp it up


### shortcut: installing with docker hub (fake airgap)


In this first test case we can cheat a little bit. I've added network access to the airgap box, and used a private docker hub registry instead of a registry inside the airgapped environment:

```
gcloud compute instances add-access-config dex-airgap-1
sudo -E ./install.sh docker.io/dexhorthy "${NAMESPACE}" "registry-creds"
```

However, I've verified that all of the images are pulled from the specified repo with the registry creds supplied.

```
$ kubectl describe deployment -n ${NAMESPACE} kotsadm-api
...

Image: docker.io/dexhorthy/kotsadm-api:v1.16.1


```

```
$ kubectl kustomize ./yaml/ | grep imagePullSecrets -C 20
        image: docker.io/dexhorthy/kotsadm-api:v1.16.1
        imagePullPolicy: Always
        name: kotsadm-api
        ports:
        - containerPort: 3000
          name: http
        readinessProbe:
          failureThreshold: 3
          httpGet:
            path: /healthz
            port: 3000
            scheme: HTTP
          initialDelaySeconds: 10
          periodSeconds: 10
        resources: {}
      imagePullSecrets:
      - registry-creds
```

verifying the image image private from a random workstation:

```
$ sudo docker pull dexhorthy/kotsadm-api:v1.16.1
Error response from daemon: pull access denied for dexhorthy/kotsadm-api, repository does not exist or may require 'docker login': denied: requested access to the resource is denied
```

verifying the pod can pull an image (crash loop is just the pod waiting for database migrations to finish)

```
$ kubectl -n test-deploy get pod -lapp=kotsadm-api
NAME                           READY   STATUS             RESTARTS   AGE
kotsadm-api-5cdbd4d4f4-psxm6   0/1     CrashLoopBackOff   1          2m
```

