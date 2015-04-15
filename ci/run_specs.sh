#!/bin/bash
set -ex

echo "-----> Running script: $0"

docker run \
  --rm=true \
  --volume=${PWD}:/vm_shepherd \
  --workdir=/vm_shepherd \
  ${DOCKER_REGISTRY}/${DOCKER_IMAGE_NAME} \
  /bin/sh -c 'bundle && bundle exec rake -t'
