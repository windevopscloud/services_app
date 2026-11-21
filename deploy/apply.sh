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

# Portals: static login pages. Cognito values come from SSM, written into portal.env by the workflow.
# shellcheck disable=SC1091
source deploy/portal.env

render_portal() {
  P="$1"; CLIENT_ID="$2"; DOMAIN="$3"; TITLE="$4"; SCOPE="$5"; REDIRECT="$6"; BUTTONS="$7"
  cat > "/tmp/config-${P}.js" <<CFG
window.PORTAL = {
  name: "${P}", title: "${TITLE}", clientId: "${CLIENT_ID}", cognitoDomain: "${DOMAIN}",
  scope: "${SCOPE}", redirectPath: "${REDIRECT}", buttons: ${BUTTONS}
};
CFG
  kubectl -n apps create configmap "portal-${P}-config" --from-file=config.js="/tmp/config-${P}.js" \
    --dry-run=client -o yaml | kubectl apply -f -
  sed "s|__P__|${P}|g" k8s/portal.tmpl.yaml > "/tmp/portal-${P}.yaml"
  if grep -q "__" "/tmp/portal-${P}.yaml"; then echo "Unreplaced tokens in portal-${P}"; exit 1; fi
  kubectl apply -f "/tmp/portal-${P}.yaml"
}

render_portal ext  "$EXT_CLIENT_ID"  "$EXT_DOMAIN"  "External portal" \
  "openid ext-api/intsvc1.invoke ext-api/intsvc2.invoke" "/success/intsvc-list/" \
  '[{"label":"intsvc1","path":"/api/intsvc1"},{"label":"intsvc2","path":"/api/intsvc2"}]'

render_portal corp "$CORP_CLIENT_ID" "$CORP_DOMAIN" "Corporate portal" \
  "openid corp-api/corpsvc1.invoke corp-api/corpsvc2.invoke" "/success/corpsvc-list/" \
  '[{"label":"corpsvc1","path":"/api/corpsvc1"},{"label":"corpsvc2","path":"/api/corpsvc2"}]'

kubectl apply -f k8s/routes.yaml
kubectl apply -f k8s/policy.yaml

# Public ALB for extsvc (cert imported to ACM earlier, ARN from SSM via portal.env)
sed "s|__EXTSVC_CERT_ARN__|${EXTSVC_CERT_ARN}|g" k8s/ingress-pub.yaml > /tmp/ingress-pub.yaml
if grep -q "__" /tmp/ingress-pub.yaml; then echo "Unreplaced tokens in ingress-pub"; exit 1; fi
kubectl apply -f /tmp/ingress-pub.yaml

for SVC in portal-ext portal-corp intsvc1 intsvc2 intsvc3 intsvc4 corpsvc1 corpsvc2 extsvc1 extsvc2; do
  kubectl rollout status deployment/"${SVC}" -n apps --timeout=300s
done
kubectl get pods -n apps
