#!/bin/bash

set -e

if [[ -z "$3" ]]; then
  echo "Usage: $0 [REPOSITORY] [RELEASE] [BUNDLE LOCATION]"
  exit 1
fi

if [[ -z "$QUAY_USERNAME" ]]; then
  echo -n "Quay Username: "
    read QUAY_USERNAME
fi

if [[ -z "$QUAY_PASSWORD" ]]; then
  echo -n "Quay Password: "
  read -s QUAY_PASSWORD
  echo
fi

TOKEN=$(curl -sH "Content-Type: application/json" -XPOST https://quay.io/cnr/api/v1/users/login -d '
{
    "user": {
        "username": "'"${QUAY_USERNAME}"'",
        "password": "'"${QUAY_PASSWORD}"'"
    }
}' | jq -r '.token')


NAMESPACE=helmoperators
REPOSITORY=$1
APP_NAME="$1-app"
RELEASE=$2
BUNDLE_LOCATION=$3

function cleanup() {
    rm -f ${REPOSITORY}.tar.gz
}

trap cleanup EXIT

tar czf ${REPOSITORY}.tar.gz $BUNDLE_LOCATION

BUNDLE=$(cat ${REPOSITORY}.tar.gz | base64 -b 0)

curl -H "Content-Type: application/json" \
     -H "Authorization: ${TOKEN}" \
     -XPOST https://quay.io/cnr/api/v1/packages/${NAMESPACE}/${APP_NAME} -d '
{
    "blob": "'"${BUNDLE}"'",
    "release": "'"${RELEASE}"'",
    "media_type": "helm"
}'
