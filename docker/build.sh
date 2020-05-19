#!/bin/bash
docker build -t weibeld/k8s-conncheck-"$1" "$(dirname "${BASH_SOURCE[0]}")/$1"
