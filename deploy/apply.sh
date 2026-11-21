#!/bin/bash
set -euo pipefail
export HOME=/root
export KUBECONFIG=/root/.kube/config

kubectl apply -f k8s/namespace.yaml

for SVC in intsvc1 intsvc2 intsvc3 intsvc4 corpsvc1 corpsvc2 extsvc1 extsvc2; do
  case "$SVC" in
    intsvc1|corpsvc1) DS=intsvc3 ;;
    intsvc2|corpsvc2) DS=intsvc4 ;;
    intsvc3) DS=extsvc1 ;;
    intsvc4) DS=extsvc2 ;;
    *) DS="" ;;
  esac
  URL=""; [ -n "$DS" ] && URL="http://${DS}:8080/"
  sed "s|__NAME__|${SVC}|g; s|__DOWNSTREAM__|${URL}|g" k8s/service.tmpl.yaml > "/tmp/${SVC}.yaml"
  if grep -q "__" "/tmp/${SVC}.yaml"; then echo "Unreplaced tokens in ${SVC}"; exit 1; fi
  kubectl apply -f "/tmp/${SVC}.yaml"
done

kubectl apply -f k8s/routes.yaml

for SVC in intsvc1 intsvc2 intsvc3 intsvc4 corpsvc1 corpsvc2 extsvc1 extsvc2; do
  kubectl rollout status deployment/"${SVC}" -n apps --timeout=300s
done
kubectl get pods -n apps
