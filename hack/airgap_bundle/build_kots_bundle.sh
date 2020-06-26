#!/bin/sh

# EXPERIMENTAL / ALPHA

set -euo pipefail


KOTS_VERSION=v1.16.1
UNAME=linux
OUTFILE=kots-${KOTS_VERSION}.tar.gz



log() {
  echo
  echo "=========="
  echo $@
  echo "=========="
}

main() {


  intro

  build_admin_console_yaml
  pack_docker_images
  get_kots
  build_unpack_script


  tar_bundle
  outro
  return
}

pack_docker_images() {
  log packing images

  for image in `cat dist_bundle/yaml/kotsadm.yaml | grep 'image: ' | cut -d':' -f 2,3 | cut -d ' ' -f2 | sort | uniq `; do
      filename=`echo ${image} | tr '/' '-' | tr ':' '-'`
      docker pull ${image}
      echo "docker save ${image} > dist_bundle/images/${filename}.tar"
      docker save ${image} > dist_bundle/images/${filename}.tar
  done
}

build_admin_console_yaml() {
  log building yaml

  [ -x bin/kots ] || make kots
  set -x
  ./bin/kots install --yaml --offline --kotsadm-tag ${KOTS_VERSION} appname --namespace appname > dist_bundle/yaml/kotsadm.yaml
  set +x
}


tar_bundle() {
  log tarring bundle

  tree dist_bundle || :
  pushd dist_bundle
    tar czvf ../${OUTFILE} .
  popd
}

build_unpack_script() {
  log building script

  cp hack/airgap_bundle/install.sh dist_bundle
}


intro() {
  log setting up
  rm -rf dist_bundle
  mkdir -p dist_bundle
  mkdir -p dist_bundle/yaml
  mkdir -p dist_bundle/images
}

outro() {
  log finalizing
  echo
  echo
  echo "created ${OUTFILE}"
}

get_kots() {
  log getting kots
  curl -fsSL https://github.com/replicatedhq/kots/releases/download/${KOTS_VERSION}/kots_${UNAME}_amd64.tar.gz | tar xv -C dist_bundle
}


main
