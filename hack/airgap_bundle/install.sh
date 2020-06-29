#!/bin/sh
# EXPERIMENTAL / ALPHA

set -e


KOTS_REGISTRY_URL=$1
KOTS_NAMESPACE=$2
KOTS_IMAGE_PULL_SECRET_NAME=$3

KOTS_REGISTRY_USERNAME=$4
KOTS_REGISTRY_PASSWORD=$5

KOTS_REGISTRY_DOMAIN=

usage() {
  cat <<EOF
error: $@


USAGE
install.sh: load a kotsadm bundle


Positional Arguments

KOTS_REGISTRY_URL -- the url to a registry to use, with any path attached
KOTS_NAMESPACE -- the name of an existing namespace to deploy into
KOTS_IMAGE_PULL_SECRET_NAME -- the name of an existing image pull secret to use for pulling from the private registry

Optional Arguments:

KOTS_REGISTRY_USERNAME -- optional, username to push images. Leave blank if this workstation already had docker push access
KOTS_REGISTRY_PASSWORD -- optional, password to push images. Leave blank if this workstation already had docker push access

EOF
}

log() {
  echo
  echo "=========="
  echo $@
  echo "=========="
}

contains() {
    string="$1"
    substring="$2"
    if test "${string#*$substring}" != "$string"
    then
        return 0
    else
        return 1
    fi
}


validate() {
  if [ -z "${KOTS_REGISTRY_URL}" ]; then usage "missing registry URL"; exit 1; fi
  if [ -z "${KOTS_NAMESPACE}" ]; then usage "missing namespace"; exit 1; fi
  if [ -z "${KOTS_IMAGE_PULL_SECRET_NAME}" ]; then usage "missing image pull secret name"; exit 1; fi
  KOTS_REGISTRY_DOMAIN=$(echo "${KOTS_REGISTRY_URL}" | cut -d'/' -f1)
}


preflight() {
  log "Checking for prerequisites: namespace exists, with image pull secret, and registry push credentials are valid"
  if ! kubectl get namespace ${KOTS_NAMESPACE} >/dev/null; then
    echo "FAIL: namespace ${KOTS_NAMESPACE} not found, please provide the name of an existing namespace"
    exit 1
  fi
  echo "SUCCESS: namespace \"${KOTS_NAMESPACE}\" exists"

  if ! kubectl get secret -n ${KOTS_NAMESPACE} ${KOTS_IMAGE_PULL_SECRET_NAME} >/dev/null; then
    echo "FAIL: namespace ${KOTS_NAMESPACE} does not contain a secret ${KOTS_IMAGE_PULL_SECRET_NAME}, please provide the name of an existing namespace"
    exit 1
  fi
  echo "SUCCESS: secret \"${KOTS_IMAGE_PULL_SECRET_NAME}\" exists"

  # if there are creds, validate w/ docker login
  if [ ! -z "${KOTS_REGISTRY_USERNAME}${KOTS_REGISTRY_PASSWORD}" ]; then
    if ! docker login --username ${KOTS_REGISTRY_USERNAME} --password ${KOTS_REGISTRY_PASSWORD} ${KOTS_REGISTRY_DOMAIN}; then
      echo "FAIL: registry creds for ${KOTS_REGISTRY_DOMAIN} failed 'docker login', please very credentials have 'docker push' access"
      exit 1
    fi
    echo "SUCCESS: push credentials valid"
  else
    echo "SUCCESS: no push credentials provided, skipping docker login."
  fi

  if kubectl get deploy -n ${KOTS_NAMESPACE} kotsadm-api 2>&1 >/dev/null; then
    printf "FAIL: Deployment kotsadm-api already found in namespace, please ensure namespace is empty before installing. "
    printf "Because many objects like services and secrets will have been created by a previous deployment, you should "
    printf "proceed to delete the entire namespace and recreate it before trying again\n"
    echo
    echo "    kubectl delete namespace ${KOTS_NAMESPACE}"
    echo "    kubectl create namespace ${KOTS_NAMESPACE}"
    echo "    kubectl -n ${KOTS_NAMESPACE} create secret docker-registry registry-creds --docker-server=... --docker-username=... --docker-password=... --docker-email=a@b.c"
    echo

    exit 1
  fi
  echo "SUCCESS: it appears that namespace \"${KOTS_NAMESPACE}\" does not contain any existing KOTS resources from a previous deploy"

}

make_kustomization() {
  log "preparing kustomization"

  MIGRATIONS_POD_NAME=$(cat yaml/kotsadm.yaml | grep 'name: kotsadm-migrations' | head -n 1 | cut -d' ' -f 4)
  echo "    MIGRATIONS_POD_NAME=${MIGRATIONS_POD_NAME}"

  AUTO_CREATE_CLUSTER_TOKEN=$(< /dev/urandom tr -dc A-Za-z0-9 | head -c16)
  echo "    AUTO_CREATE_CLUSTER_TOKEN=${AUTO_CREATE_CLUSTER_TOKEN}"


  cat <<EOF >./yaml/cluster-token-value.yaml
apiVersion: v1
kind: Secret
metadata:
  name: kotsadm-cluster-token
stringData:
  kotsadm-cluster-token: "${AUTO_CREATE_CLUSTER_TOKEN}"
EOF

  cat <<EOF >./yaml/cluster-token-patch.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kotsadm-api
  namespace: appname
spec:
  template:
    spec:
      containers:
        - name: kotsadm-api
          env:
            - name: AUTO_CREATE_CLUSTER_TOKEN
              valueFrom:
                secretKeyRef:
                  key: kotsadm-cluster-token
                  name: kotsadm-cluster-token
EOF

  cat <<EOF >./yaml/regcred.json
[
  { "op": "add",
    "path": "/spec/template/spec/imagePullSecrets",
    "value": [{ "name": "${KOTS_IMAGE_PULL_SECRET_NAME}"}]
  }
]
EOF

  cat <<EOF >./yaml/regcred-pod.json
[
  { "op": "add",
    "path": "/spec/imagePullSecrets",
    "value": [{ "name": "${KOTS_IMAGE_PULL_SECRET_NAME}"}]
  }
]
EOF

  cat <<EOF >./yaml/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${KOTS_NAMESPACE}
resources:
- ./kotsadm.yaml
patches:
- ./cluster-token-value.yaml
- ./cluster-token-patch.yaml
patchesJson6902:
  - path: ./regcred.json
    target:
      group: apps
      version: v1
      kind: Deployment
      name: kotsadm
  - path: ./regcred.json
    target:
      group: apps
      version: v1
      kind: Deployment
      name: kotsadm-api
  - path: ./regcred.json
    target:
      group: apps
      version: v1
      kind: Deployment
      name: kotsadm-operator
  - path: ./regcred.json
    target:
      group: apps
      version: v1
      kind: StatefulSet
      name: kotsadm-minio
  - path: ./regcred-pod.json
    target:
      version: v1
      kind: Pod
      name: ${MIGRATIONS_POD_NAME}
images:
EOF

  # postflight for yaml
  if ! kubectl kustomize ./yaml >/dev/null; then
    echo "ERROR: invalid yaml after generating kustomize base in ./yaml"
    exit 1
  fi
  echo "SUCCESS: valid kustomization yaml created in ./yaml"

}

load_images() {
  log "loading docker images"
  for image in `ls ./images/`; do
    docker load < ./images/${image}
  done
}

tag_and_push_images() {
  log "tagging and pushing to ${KOTS_REGISTRY_URL}"
  for image in `cat yaml/kotsadm.yaml | grep 'image: ' | cut -d':' -f 2,3 | cut -d ' ' -f2 | sort | uniq `; do
    if contains "${image}" "postgres"; then
        imageSuffixWithTag=${image}
        rewritePrefix=""
    else
        imageSuffixWithTag=`echo ${image} | cut -d'/' -f 2` # kotsadm-api:1.16.1
        rewritePrefix="kotsadm/"
    fi

    newName=${KOTS_REGISTRY_URL}/${imageSuffixWithTag}
    docker tag ${image} ${newName}
    docker push ${newName}

    imageSuffixWithoutTag=`echo ${imageSuffixWithTag} | cut -d':' -f 1`
    imageTag=`echo ${imageSuffixWithTag} | cut -d':' -f 2`

    echo
    echo adding kustomization snippet for ${rewritePrefix}${imageSuffixWithoutTag}: ${KOTS_REGISTRY_URL}/${imageSuffixWithoutTag}:${imageTag}
    echo

    cat <<EOF >> ./yaml/kustomization.yaml
- name: ${rewritePrefix}${imageSuffixWithoutTag}
  newName: ${KOTS_REGISTRY_URL}/${imageSuffixWithoutTag}
  newTag: "${imageTag}"
EOF

  done
}

postflight() {
  log "postflight checks"
  if kubectl -n ${KOTS_NAMESPACE} get secret kotsadm-cluster-token -o yaml | grep -qE 'kotsadm-cluster-token: ""'; then
    echo "WARN: invalid yaml: empty kotsadm-cluster-token "
    kubectl -n ${KOTS_NAMESPACE} get secret kotsadm-cluster-token -o yaml
    exit 1
  fi
  echo "SUCCESS: cluster token configured"
}

main() {

  validate
  preflight

  make_kustomization
  load_images
  tag_and_push_images


  log deploying
  echo "manifests have been written to ./yaml -- you can press ENTER to deploy them, or Ctrl+C to exit this script. You can deploy them later with"
  echo
  # deploy this separately due to bug in kustomize
  echo   "    kubectl apply --namespace ${KOTS_NAMESPACE} -k ./yaml"
  echo
  echo -n "would you like to deploy? [ENTER] "
  read continue

  kubectl apply --namespace ${KOTS_NAMESPACE} -k ./yaml

  postflight
}


main
