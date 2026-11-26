#!/bin/bash
set -euo pipefail
export HOME=/root
export KUBECONFIG=/root/.kube/config

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/ingress-gw.yaml

# Client credentials for the two services that call the public outsvc (Secrets Manager -> k8s secret)
source deploy/portal.env
CLIENTS=$(aws secretsmanager get-secret-value --secret-id "cognito/poc/external-clients" --region us-west-2 --query SecretString --output text)
for S in intsvc1 intsvc2; do
  case "$S" in intsvc1) SC="ext-api/outsvc1.invoke" ;; intsvc2) SC="ext-api/outsvc2.invoke" ;; esac
  CID=$(echo "$CLIENTS" | python3 -c "import sys,json;print(json.load(sys.stdin)['$S']['client_id'])")
  CSEC=$(echo "$CLIENTS" | python3 -c "import sys,json;print(json.load(sys.stdin)['$S']['client_secret'])")
  kubectl -n apps create secret generic "client-${S}" \
    --from-literal=CLIENT_ID="$CID" --from-literal=CLIENT_SECRET="$CSEC" \
    --from-literal=TOKEN_URL="https://${EXT_DOMAIN}/oauth2/token" --from-literal=SCOPE="$SC" \
    --dry-run=client -o yaml | kubectl apply -f -
done

for SVC in extsvc1 extsvc2 intsvc1 intsvc2 corpsvc1 corpsvc2 outsvc1 outsvc2; do
  case "$SVC" in
    extsvc1|corpsvc1) DS=intsvc1 ;;
    extsvc2|corpsvc2) DS=intsvc2 ;;
    intsvc1) DS=outsvc1 ;;
    intsvc2) DS=outsvc2 ;;
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
  "openid ext-api/extsvc1.invoke ext-api/extsvc2.invoke" "/success/extsvc-list/" \
  '[{"label":"extsvc1","path":"/api/extsvc1"},{"label":"extsvc2","path":"/api/extsvc2"}]'

render_portal corp "$CORP_CLIENT_ID" "$CORP_DOMAIN" "Corporate portal" \
  "openid corp-api/corpsvc1.invoke corp-api/corpsvc2.invoke" "/success/corpsvc-list/" \
  '[{"label":"corpsvc1","path":"/api/corpsvc1"},{"label":"corpsvc2","path":"/api/corpsvc2"}]'

kubectl apply -f k8s/routes.yaml
kubectl apply -f k8s/policy.yaml

# outsvc token check at the public gateway (Cognito keys fetched by the workflow)
EXT_JWKS=$(cat deploy/ext-jwks.json)
sed "s|__EXT_ISSUER__|${EXT_ISSUER}|g; s|__EXT_JWKS__|${EXT_JWKS}|g" k8s/auth-pub.tmpl.yaml > /tmp/auth-pub.yaml
if grep -q "__EXT_" /tmp/auth-pub.yaml; then echo "Unreplaced tokens in auth-pub"; exit 1; fi
kubectl apply -f /tmp/auth-pub.yaml

# intsvc1/2: caller identity + valid token (ext or corp)
CORP_JWKS=$(cat deploy/corp-jwks.json)
sed "s|__EXT_ISSUER__|${EXT_ISSUER}|g; s|__EXT_JWKS__|${EXT_JWKS}|g; s|__CORP_ISSUER__|${CORP_ISSUER}|g; s|__CORP_JWKS__|${CORP_JWKS}|g; s|__EXT_CLIENT_ID__|${EXT_CLIENT_ID}|g; s|__CORP_CLIENT_ID__|${CORP_CLIENT_ID}|g" \
  k8s/auth-mesh.tmpl.yaml > /tmp/auth-mesh.yaml
if grep -q "__EXT_\|__CORP_" /tmp/auth-mesh.yaml; then echo "Unreplaced tokens in auth-mesh"; exit 1; fi
kubectl apply -f /tmp/auth-mesh.yaml

# Egress path (x-origin ext -> egress gateway -> public outsvc) and Cognito token host
sed "s|__EXT_DOMAIN__|${EXT_DOMAIN}|g" k8s/egress.tmpl.yaml > /tmp/egress.yaml
if grep -q "__EXT_" /tmp/egress.yaml; then echo "Unreplaced tokens in egress"; exit 1; fi
kubectl apply -f /tmp/egress.yaml

# Public ALB for outsvc (cert imported to ACM earlier, ARN from SSM via portal.env)
sed "s|__OUTSVC_CERT_ARN__|${OUTSVC_CERT_ARN}|g" k8s/ingress-pub.yaml > /tmp/ingress-pub.yaml
if grep -q "__" /tmp/ingress-pub.yaml; then echo "Unreplaced tokens in ingress-pub"; exit 1; fi
kubectl apply -f /tmp/ingress-pub.yaml

for SVC in portal-ext portal-corp extsvc1 extsvc2 intsvc1 intsvc2 corpsvc1 corpsvc2 outsvc1 outsvc2; do
  kubectl rollout status deployment/"${SVC}" -n apps --timeout=300s
done
kubectl get pods -n apps

echo "=== Porkbun CNAME targets ==="
for i in $(seq 1 30); do
  ALB=$(kubectl get ingress outsvc -A -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -z "$ALB" ] && ALB=$(kubectl get ingress -A -o jsonpath='{.items[?(@.metadata.name=="outsvc")].status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  [ -n "$ALB" ] && break
  sleep 10
done
echo "outapi.windevopscloud.com -> ${ALB:-not ready yet}"
kubectl get ingress -A