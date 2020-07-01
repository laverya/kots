### Definitions

- Public Workstation: A laptop somewhere, has access to internet, probably in a DMZ somewhere. In this case we'll use a GCP server, `dex-airgap-jump`
- Airgapped Workstation: `dex-airgap-workstation` -- has kubectl access to an "airgapped cluster", and network access to a "private registry"
- Airgapped Cluster: in this case we'll [use a kURL cluster in GCP](#appendix-creating-an-airgapped-kubernetes-cluster-in-gcp), but any k8s cluster works, if you want a real test you should remove any public outbound internet gateways though. This example uses a node called `dex-airgap-cluster`
- Private Registry: a separate registry to which images will be pushed during install, and pulled from within the cluster. The cluster should have network access to this registry to pull images.
- KOTS Bundle: Kots bundle can be [built from source](#appendix-building-the-bundle), or downloaded from s3: https://kots-experimental.s3.amazonaws.com/kots-v1.16.1-airgap-experimental-alpha2.tar.gz

### Installing


From Public Workstation, move kots bundle to Airgapped Workstation

```
gcloud compute scp kots-v1.16.1.tar.gz dex-airgap-jump:
```

This installer expects a namespace and a pull secret to already exist on the target cluster. Let's create them from the Airgapped Workstation

```
export NAMESPACE=test-deploy
kubectl create namespace ${NAMESPACE}
```

```
namespace/test-deploy created
```

we also need to create an image pull secret:

```
export DOCKER_REGISTRY=...
export DOCKER_USERNAME=...
export DOCKER_PASSWORD=...
kubectl -n $NAMESPACE create secret  docker-registry registry-creds --docker-server=$DOCKER_REGISTRY --docker-username=$DOCKER_USERNAME --docker-password=$DOCKER_PASSWORD --docker-email=a@b.c
```

```
secret/registry-creds created
```

Now, let's unpack the bundle and run the script with no arguments to see the usage:

```
tar xvf kots-*.tar.gz
./install.sh
```

You should see an error and some help text

```
error: missing registry URL


USAGE
install.sh: load a kotsadm bundle


Positional Arguments

KOTS_REGISTRY_URL -- the url to a registry to use, with any path attached
KOTS_NAMESPACE -- the name of an existing namespace to deploy into
KOTS_IMAGE_PULL_SECRET_NAME -- the name of an existing image pull secret to use for pulling from the private registry

Optional Arguments:

KOTS_REGISTRY_USERNAME -- optional, username to push images. Leave blank if this workstation already had docker push access
KOTS_REGISTRY_PASSWORD -- optional, password to push images. Leave blank if this workstation already had docker push access

```


Let's invoke this with our set variables (I'm leaving namespace blank in this case). We use `sudo -E` to preserve the environment vars like `KUBECONFIG` and `DOCKER_REGISTRY` from the non-root user.

```
sudo -E ./install.sh "${DOCKER_REGISTRY}" "${NAMESPACE}" "registry-creds" "${DOCKER_USERNAME}" "${DOCKER_PASSWORD}" ""
```


Once this is finished and the postflight checks have completed, we can get a new password for the admin console:

```text
./kots reset-password -n "${NAMESPACE}"
```

Next, we need to expose the admin console. If we're running kubectl from a workstation with a browser, we can run 

```text
./kots admin-console -n "${NAMESPACE}"
```

Since I'm running this from a Jump box, I'm going to create a NodePort, but other options like creating an Ingress will let us configure TLS, etc. For an Ingress the service name should be `kotsadm` and it can be deployed out-of-band, either before or after the full install. If you're

```text
$ kubectl -n "${NAMESPACE}" expose deployment kotsadm --name=kotsadm-nodeport --port=3000 --target-port=3000 --type=NodePort
$ kubectl -n "${NAMESPACE}" get svc kotsadm-nodeport
NAME               TYPE       CLUSTER-IP    EXTERNAL-IP   PORT(S)          AGE
kotsadm-nodeport   NodePort   10.96.0.239   <none>        3000:25124/TCP   7s
```

And then navigate to <instance ip> : <port>, in this case `http://25.238.234.48:25124`


### note


in this first test case I've cheated a little bit, because just wanting to get a proof-of-concept out. I've added network access to the airgap box, and used a private docker hub registry:

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

### Appendix: building the bundle

```shell
make kots
./hack/airgap_bundle/build_kots_bundle.sh
```

### Appendix: End to End GCP example

We'll set up these 3 instances in GCP

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

create a GCP vm to be our airgapped workstation. We'll give it outbound network access for now to facilitate installing docker, but then we'll disconnect it from the internet.


```shell
export INSTANCE=dex-airgap-workstation; gcloud compute instances create $INSTANCE --boot-disk-size=200GB --image-project ubuntu-os-cloud --image-family ubuntu-1804-lts --machine-type n1-standard-1 
```

```shell
gcloud compute ssh dex-airgap-workstation -- 'sudo apt update && sudo apt install docker.io'
```

Next, remove the machine's public IP. We'll use the kubeconfig from this server later.

```shell
gcloud compute instances delete-access-config dex-airgap-workstation
```

verify that internet access was disabled by ssh'ing via the jump box and trying to curl kubernetes.io. We'll forward the agent so that we can ssh the airgapped workstation without moving keys around

```shell
gcloud compute ssh --ssh-flag=-A dex-airgap-jump -- "ssh dex-airgap-workstation 'curl -v https://google.com'"
```

this command should hang, and you should see something with `Network is unreachable`:

```text
  0     0    0     0    0     0      0      0 --:--:--  0:00:02 --:--:--     0*   Trying 2607:f8b0:4001:c05::64...
* TCP_NODELAY set
* Immediate connect fail for 2607:f8b0:4001:c05::64: Network is unreachable
  0     0    0     0    0     0      0      0 --:--:--  0:00:03 --:--:--     0^CConnection to 35.193.94.87 closed.
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

deploy a minimal registry and verify its running

```shell
gcloud compute ssh dex-airgap-cluster -- 'kubectl --kubeconfig ./admin.conf apply -f https://gist.githubusercontent.com/dexhorthy/7a3e6eb119d2d90ff7033a78151c3be2/raw/170dcb45c2fc9e539018bc5a3219c56043680534/plain-registry.yaml'
```

```shell
gcloud compute ssh dex-airgap-cluster -- 'kubectl --kubeconfig ./admin.conf get pod,svc -n registry'
```

Next, remove the machine's public IP. We'll use the kubeconfig from this server later.

```ssh
gcloud compute instances delete-access-config dex-airgap-cluster
```


#### installation

From the Jump box, download the kots bundle from S3

```

```

From the Airgapped Workstation, grab the `admin.conf` so we can run kubectl from this server:

```
scp dex-airgap-1:admin.conf .
export KUBECONFIG=$PWD/admin.conf
kubectl get pods -n kube-system
```

(this guide assumes kubectl and docker already exist on the `kubectl`-ing workstation, I used `snap install kubectl --classic` in this case)

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
