#!/bin/bash
set -ex

echo "-----> Running script: $0"

docker run \
  --rm=true \
  --volume=${PWD}:/vm_shepherd \
  --workdir=/vm_shepherd \
  --env=VCENTER_IP=${VCENTER_IP} \
  --env=USERNAME=${USERNAME} \
  --env=PASSWORD=${PASSWORD} \
  --env=DATACENTER_NAME=${DATACENTER_NAME} \
  --env=DATASTORE_NAME=${DATASTORE_NAME} \
  ${DOCKER_REGISTRY}/${DOCKER_IMAGE_NAME} \
  /bin/sh -c 'bundle && bundle exec rspec --format documentation'
