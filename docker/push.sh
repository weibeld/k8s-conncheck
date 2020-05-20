#!/bin/bash

for i in "$@"; do
  docker push weibeld/k8s-conncheck-"$i"
done
