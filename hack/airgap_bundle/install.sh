#!/bin/sh

set -e


KOTS_REGISTRY_URL=$1
KOTS_REGISTRY_USERNAME=$2
KOTS_REGISTRY_PASSWORD=$3 KOTS_REGISTRY_NAMESPACE=$4
KOTS_APP_SLUG=$5
KOTS_NAMESPACE=$6


validate() {
  if [ -z "${KOTS_REGISTRY_URL}" ]; then usage "missing registry URL"; exit 1; fi
  if [ -z "${KOTS_REGISTRY_USERNAME}" ]; then usage "missing registry username"; exit 1; fi
  if [ -z "${KOTS_REGISTRY_PASSWORD}" ]; then usage "missing registry password"; exit 1; fi
  if [ -z "${KOTS_APP_SLUG}" ]; then usage "missing app slug"; exit 1; fi
  if [ -z "${KOTS_NAMESPACE}" ]; then usage "missing namespace"; exit 1; fi
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

usage() {
  cat <<EOF
error: $@


USAGE
install.sh: load a kotsadm bundle


Positional Arguments

KOTS_REGISTRY_URL -- the url to a registry to use
KOTS_REGISTRY_USERNAME -- username to push images
KOTS_REGISTRY_PASSWORD -- password to push images
KOTS_REGISTRY_NAMESPACE -- optional, a slash-prefixed registry namespace, e.g. "/app-images"

APP_SLUG -- The app slug to deploy
KOTS_NAMESPACE -- The Namespace to deploy
KOTS_IMAGE_PULL_SECRET_NAME=$6

EOF
}

make_kustomization() {
  cat <<EOF >./yaml/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: ${KOTS_NAMESPACE}
resources:
- ./kotsadm.yaml
patches:
    -   target:
            kind: Deployment
        patch: |-
            - op: add
              path: /spec/template/spec/imagePullSecrets
              value:
                name: registry-creds
    -   target:
            kind: StatefulSet
        patch: |-
            - op: replace
              path: /spec/template/spec/imagePullSecrets
              value:
                - name: registry-creds
images:
EOF


}

preflight() {
  log "Checking for prerequisites: namespace exists, with image pull secret, and registry push credentials are valid"
  if ! kubectl get namespace ${KOTS_NAMESPACE} >/dev/null; then
    echo "namespace ${KOTS_NAMESPACE} not found, please provide the name of an existing namespace"
    exit 1
  fi
  if ! docker login --username ${KOTS_REGISTRY_USERNAME} --password ${KOTS_REGISTRY_PASSWORD} ${KOTS_REGISTRY_URL}; then
    echo "registry creds for ${KOTS_REGISTRY_URL} failed 'docker login', please very credentials have 'docker push' access"
    exit 1
  fi

}

load_images() {
  log "loading"
  for image in `ls ./images/`; do
    docker load < ./images/${image}
  done
}

tag_and_push_images() {
  log "tagging and pushing"
  docker login --username ${KOTS_REGISTRY_USERNAME} --password ${KOTS_REGISTRY_PASSWORD} ${KOTS_REGISTRY_URL}
  for image in `cat yaml/kotsadm.yaml | grep 'image: ' | cut -d':' -f 2,3 | cut -d ' ' -f2 | sort | uniq `; do
    if contains "${image}" "postgres"; then
        subPart=${image}
        rewritePrefix=""
    else
        subPart=`echo ${image} | cut -d'/' -f 2`
        rewritePrefix="kotsadm/"
    fi

    newName=${KOTS_REGISTRY_URL}${KOTS_REGISTRY_NAMESPACE}/${subPart}
    docker tag ${image} ${newName}
    docker push ${newName}

    echo adding kustomization snippet for ${image}
    echo
    subPartWithoutTag=`echo ${subPart} | cut -d':' -f 1`
    subPartTag=`echo ${subPart} | cut -d':' -f 2`

    echo adding kustomization snippet for ${image}: ${subPartWithoutTag} ${subPartTag}
    echo

    cat <<EOF >> ./yaml/kustomization.yaml
- name: ${rewritePrefix}${subPartWithoutTag}
  newName: ${KOTS_REGISTRY_URL}${KOTS_REGISTRY_NAMESPACE}/${subPartWithoutTag}
  newTag: "${subPartTag}"
EOF
  done
}

# EXPERIMENTAL / ALPHA
  ## retag & push images, w/ CLI args
  ## unpack kotsadm yaml
  ## create kustomize patch so kotsadm images get pulled from internal registry
  ## create kustomize patch for app name / slug
  ## create kustomize patch for airgap?
  ## kubectl apply
main() {

  validate
  preflight

  make_kustomization
  load_images
  tag_and_push_images


  log deploying
  kubectl create secret docker-registry -n ${KOTS_NAMESPACE} registry-creds --docker-server=index.docker.io --docker-username=${KOTS_REGISTRY_USERNAME} --docker-password=${KOTS_REGISTRY_PASSWORD} --docker-email=@
  kubectl apply -k ./yaml
}

main
