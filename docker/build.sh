#!/bin/bash

for i in "$@"; do
  docker build -t weibeld/k8s-conncheck-"$i" "$(dirname "${BASH_SOURCE[0]}")/$i"
done

