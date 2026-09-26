#!/usr/bin/env bash
# charts/tpg-instance rendering of the Round 12 values (design decisions D63 to D65):
#   exposure        serviceType and the Azure load balancer annotations; an empty
#                   map is never rendered (F7); instance.serviceType is refused
#   caBundle        written with enableSSL: true, and only then; enableSSL: true
#                   without a bundle fails the render
#   network policy  none renders nothing; baseline renders NetworkPolicy
#                   tpg-ingress and CiliumNetworkPolicy tpg-egress; a rule is
#                   rendered only for a non-empty input, and no peer list is
#                   empty (an empty peer list allows every source: F9)
# Requires: helm (v3 or v4), yq (mikefarah), python3 with PyYAML; skipped without them.
# shellcheck disable=SC2015
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
for t in helm yq; do command -v "$t" >/dev/null || { echo "SKIP tests/chart: $t not installed" >&2; exit 0; }; done
python3 -c "import yaml" 2>/dev/null || { echo "SKIP tests/chart: python3 PyYAML not installed" >&2; exit 0; }
yq --version 2>&1 | grep -q mikefarah || { echo "SKIP tests/chart: yq is not mikefarah yq v4" >&2; exit 0; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()  { printf 'ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1"; [[ -z "${2:-}" ]] || printf '%s\n' "$2" | sed 's/^/       | /' | tail -12; FAIL=$((FAIL + 1)); }
render() {  # render VALUES_YAML -> $OUT (rendered manifests) and $RC
  printf 'cluster: {name: c1}\ninstance: {name: i1, postgresVersion: postgres-17.6}\nbackup: {container: pg-backups-c1}\n' > "$TMP/base.yaml"
  printf '%s\n' "$1" > "$TMP/v.yaml"
  RC=0
  OUT="$(helm template i1 "$ROOT/charts/tpg-instance" -f "$ROOT/clusters/_template/cluster.yaml" \
    -f "$ROOT/clusters/_template/instance.yaml" -f "$TMP/base.yaml" -f "$TMP/v.yaml" --namespace pg-i1 2>&1)" || RC=$?
}
pg() { yq "select(.kind == \"Postgres\") | $1" <<<"$OUT"; }
f9() {  # every NetworkPolicy ingress rule has a non-empty from, and no peer is all
        # empty selectors ({namespaceSelector: {}} alone would admit every pod of
        # every namespace); {podSelector: {}} alone is the instance namespace itself
  pycheck 'all(r.get("from") and all(p == {"podSelector": {}} or any(p.values()) for p in r["from"])
           for r in K("NetworkPolicy")["spec"]["ingress"])'
}

pycheck() {  # pycheck PYTHON_EXPR: true when the expression holds; K(kind) is the rendered object of that kind
  python3 -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
def K(kind):
    return next(d for d in docs if d.get("kind") == kind)
def egress(): return K("CiliumNetworkPolicy")["spec"]["egress"]
def ports(rule): return [p["port"] for p in rule["toPorts"][0]["ports"]]
sys.exit(0 if eval("(" + sys.argv[1] + ")") else 1)
' "$1" <<<"$OUT" 2>/dev/null
}

# ---- exposure
render ''
[[ "$(pg '.spec.serviceType')" == "ClusterIP" && "$(pg '.spec | has("serviceAnnotations")')" == "false" \
   && "$(pg '.spec | has("readOnlyServiceType")')" == "false" ]] \
  && ok "default: ClusterIP, no annotations, no readOnlyServiceType (existing specs unchanged)" || bad "default" "$OUT"
render 'instance: {exposure: internalLoadBalancer, internalLoadBalancerSubnet: apps-subnet, allowedSourceRanges: [10.0.0.0/8, 192.168.0.0/16]}'
pg '.spec' | yq -e '.serviceType == "LoadBalancer"
  and .serviceAnnotations["service.beta.kubernetes.io/azure-load-balancer-internal"] == "true"
  and .serviceAnnotations["service.beta.kubernetes.io/azure-load-balancer-internal-subnet"] == "apps-subnet"
  and .serviceAnnotations["service.beta.kubernetes.io/azure-allowed-ip-ranges"] == "10.0.0.0/8,192.168.0.0/16"' >/dev/null \
  && ok "internalLoadBalancer: internal annotation, subnet and allowed ranges" || bad "internal" "$(pg '.spec')"
render 'instance: {exposure: loadBalancer, serviceAnnotations: {service.beta.kubernetes.io/azure-dns-label-name: orders}, readOnlyExposure: loadBalancer}'
pg '.spec' | yq -e '.serviceType == "LoadBalancer" and .readOnlyServiceType == "LoadBalancer"
  and (.serviceAnnotations | has("service.beta.kubernetes.io/azure-load-balancer-internal") | not)
  and .serviceAnnotations["service.beta.kubernetes.io/azure-dns-label-name"] == "orders"
  and (has("readOnlyServiceAnnotations") | not)' >/dev/null \
  && ok "loadBalancer: public, extra annotations kept, no empty read-only annotations" || bad "public" "$(pg '.spec')"
render 'instance: {exposure: nodePort}'
[[ "$RC" -ne 0 ]] && grep -q "must be clusterIP, internalLoadBalancer or loadBalancer" <<<"$OUT" && ok "an unknown exposure fails the render" || bad "unknown exposure" "$OUT"
render 'instance: {serviceType: LoadBalancer}'
[[ "$RC" -ne 0 ]] && grep -q "instance.serviceType is replaced by instance.exposure" <<<"$OUT" && ok "instance.serviceType fails with the replacement named" || bad "serviceType" "$OUT"

# ---- caBundle
render 'backup: {enableSSL: true}'
[[ "$RC" -ne 0 ]] && grep -q "caBundle is empty" <<<"$OUT" && ok "enableSSL: true without caBundle fails the render" || bad "no bundle" "$OUT"
render 'backup: {enableSSL: true, caBundle: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"}'
pycheck 'K("PostgresBackupLocation")["spec"]["storage"]["azure"]["enableSSL"] is True and K("PostgresBackupLocation")["spec"]["storage"]["azure"]["caBundle"].startswith("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----")' \
  && ok "enableSSL: true writes the bundle" || bad "bundle" "$(yq 'select(.kind == "PostgresBackupLocation")' <<<"$OUT")"
render 'backup: {enableSSL: false, caBundle: "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"}'
pycheck 'K("PostgresBackupLocation")["spec"]["storage"]["azure"]["enableSSL"] is False and "caBundle" not in K("PostgresBackupLocation")["spec"]["storage"]["azure"]' \
  && ok "enableSSL: false writes no caBundle" || bad "no ca with ssl false" "$OUT"

# ---- network policy
render ''
[[ -z "$(yq 'select(.kind == "NetworkPolicy" or .kind == "CiliumNetworkPolicy") | .kind' <<<"$OUT")" ]] \
  && ok "policy none: no policy objects" || bad "none" "$OUT"
render 'network: {policy: baseline}'
[[ "$(yq 'select(.kind == "NetworkPolicy") | .spec.ingress | length' <<<"$OUT")" == "3" ]] && f9 \
  && ok "baseline: ingress rules for the namespace, the operator and metrics only, no empty peer list" || bad "baseline ingress" "$OUT"
pycheck 'any(r.get("toEntities") == ["kube-apiserver"] for r in egress())
  and any(r.get("toEntities") == ["world"] and ports(r) == ["443", "80"] for r in egress())
  and not any("toFQDNs" in r for r in egress())' \
  && ok "baseline: API server, and backup egress to any address on 443 and 80 (enableSSL false, no ACNS)" || bad "baseline egress" "$(yq 'select(.kind == "CiliumNetworkPolicy")' <<<"$OUT")"
render 'network: {policy: baseline, acns: true}
backup: {enableSSL: true, caBundle: "x"}'
pycheck 'any(r.get("toFQDNs") == [{"matchPattern": "*.blob.core.windows.net"}] and ports(r) == ["443"] for r in egress())
  and any(r.get("toPorts", [{}])[0].get("rules", {}).get("dns") == [{"matchPattern": "*"}] for r in egress())
  and not any(r.get("toEntities") == ["world"] for r in egress())' \
  && ok "ACNS: backup egress by FQDN on 443 only (enableSSL true), with the DNS proxy rule" || bad "acns" "$(yq 'select(.kind == "CiliumNetworkPolicy")' <<<"$OUT")"
render 'network: {policy: baseline, ingressFromNamespaces: [app], ingressFromPodLabels: {role: api}, ingressFromCidrs: [10.1.0.0/16], egressToCidrs: [10.2.0.0/24], egressToFqdns: [api.example.com, "*.example.org"]}
instance: {exposure: loadBalancer, allowedSourceRanges: [10.1.0.0/16]}'
pycheck 'K("NetworkPolicy")["spec"]["ingress"][3] == {"from": [
    {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "app"}}, "podSelector": {"matchLabels": {"role": "api"}}},
    {"ipBlock": {"cidr": "10.1.0.0/16"}}, {"ipBlock": {"cidr": "168.63.129.16/32"}}],
  "ports": [{"protocol": "TCP", "port": 5432}]}' && f9 \
  && ok "client rules: namespace with pod labels, CIDR, and the Azure health probe for a load balancer" || bad "client rules" "$(yq 'select(.kind == "NetworkPolicy")' <<<"$OUT")"
pycheck 'any(r.get("toCIDR") == ["10.2.0.0/24"] for r in egress())
  and any(r.get("toFQDNs") == [{"matchName": "api.example.com"}, {"matchPattern": "*.example.org"}] for r in egress())' \
  && ok "egress rules: toCIDR and toFQDNs (matchName and matchPattern)" || bad "egress rules" "$(yq 'select(.kind == "CiliumNetworkPolicy")' <<<"$OUT")"
render 'network: {policy: baseline, ingressFromNamespaces: [], ingressFromPodLabels: {}, ingressFromCidrs: [], egressToCidrs: [], egressToFqdns: [], monitoringNamespaces: []}'
[[ "$(yq 'select(.kind == "NetworkPolicy") | .spec.ingress | length' <<<"$OUT")" == "2" ]] && f9 \
  && pycheck 'not any("toFQDNs" in r or ("toCIDR" in r and r["toCIDR"] != ["169.254.10.0/24"]) for r in egress())' \
  && ok "empty rule lists and maps render no rule at all (F9)" || bad "empty lists" "$OUT"
render 'network: {policy: baseline, ingressFromPodLabels: {role: api}}'
pycheck 'K("NetworkPolicy")["spec"]["ingress"][3]["from"] == [{"namespaceSelector": {}, "podSelector": {"matchLabels": {"role": "api"}}}]' \
  && ok "pod labels without namespaces: those pods in any namespace" || bad "labels only" "$(yq 'select(.kind == "NetworkPolicy")' <<<"$OUT")"

echo
echo "chart: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
