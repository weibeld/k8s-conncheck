#!/bin/bash
docker build -t weibeld/k8s-conncheck-controller .
docker push weibeld/k8s-conncheck-controller
