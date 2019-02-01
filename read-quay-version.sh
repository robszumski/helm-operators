#!/bin/bash

set -e

if [[ -z "$1" ]]; then
  echo "Usage: $0 [REPOSITORY]"
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

function version_gt() { test "$(printf '%s\n' "$@" | sort -V | head -n 1)" != "$1"; }

NAMESPACE=helmoperators
APP_NAME="$1-app"

REMOTE_VERSION=$(curl -s -H "Content-Type: application/json" \
     -H "Authorization: ${TOKEN}" \
     -XGET https://quay.io/cnr/api/v1/packages/helmoperators/$APP_NAME | jq -r '. |= sort_by(.created_at) | last.release')

echo $REMOTE_VERSION