

### building a full bundle

./build_kots_bundle.sh


### airgapped kubernetes cluster

create a GCP vm with `--no-address`, this will be our airgapped instance


```shell
INSTANCE=dex-airgap-1; gcloud compute instances create $INSTANCE --boot-disk-size=200GB --image-project ubuntu-os-cloud --image-family ubuntu-1804-lts --machine-type n1-standard-4 --no-address
```

create a jump box with a public IP and SSH it


```
export INSTANCE=dex-airgap-jump
gcloud compute instances create $INSTANCE --boot-disk-size=200GB --image-project ubuntu-os-cloud --image-family ubuntu-1804-lts --machine-type n1-standard-1
until gcloud compute ssh --ssh-flag=-A $INSTANCE; do sleep 1; done
```


On the jump box, download a kURL installer bundle without KOTS (details here: https://kurl.sh/47f35bd )

```
curl -LO https://kurl.sh/bundle/47f35bd.tar.gz
```

From the jump box, SCP the kURL bundle to the airgapped node, then ssh over to it and run the script

```
scp 47f35bd.tar.gz dex-airgap-1:
ssh dex-airgap-1
tar xvf 47f35bd.tar.gz
sudo bash ./install.sh airgap
```
