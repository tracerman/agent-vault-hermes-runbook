#!/usr/bin/env bash
# Verify a broker service rule BEFORE swapping any real credential.
#
# Sends your placeholder through the broker, then repeats with a deliberately
# unconfigured one. Comparing the two is the whole point: a single result tells
# you nothing, because a working call and a passthrough call can look alike.
#
# Usage:
#   ./test-service.sh <url> <header-name> <placeholder> [method] [body]
#
# Examples:
#   ./test-service.sh https://api.exa.ai/search x-api-key __exa_api_key__ POST '{}'
#   ./test-service.sh https://api.github.com/user Authorization "Bearer __github_token__"
#
# Env:
#   AGENT_VAULT_TOKEN   required, av_agt_...
#   AGENT_VAULT_CA      path to mitm-ca.pem (default ./agent-vault-ca/mitm-ca.pem)
#   AGENT_VAULT_HOST    broker host:port (default agent-vault:14322)
#   DOCKER_NETWORK      network to run curl on (default broker-net)

set -u

URL="${1:?usage: test-service.sh <url> <header-name> <placeholder> [method] [body]}"
HEADER="${2:?missing header name}"
PLACEHOLDER="${3:?missing placeholder}"
METHOD="${4:-GET}"
BODY="${5:-{\}}"

: "${AGENT_VAULT_TOKEN:?set AGENT_VAULT_TOKEN}"
CA="${AGENT_VAULT_CA:-./agent-vault-ca/mitm-ca.pem}"
BROKER="${AGENT_VAULT_HOST:-agent-vault:14322}"
NET="${DOCKER_NETWORK:-broker-net}"

[ -f "$CA" ] || { echo "CA not found at $CA" >&2; exit 1; }
CA_ABS="$(cd "$(dirname "$CA")" && pwd)/$(basename "$CA")"

probe() {
  local value="$1"
  local args=(-s -o /dev/null -m 30 -w '%{http_code}'
              --proxy "http://${AGENT_VAULT_TOKEN}@${BROKER}"
              --cacert /ca.pem
              -H "${HEADER}: ${value}")
  if [ "$METHOD" != "GET" ]; then
    args+=(-X "$METHOD" -H "Content-Type: application/json" -d "$BODY")
  fi
  docker run --rm --network "$NET" -v "${CA_ABS}:/ca.pem:ro" \
    curlimages/curl:latest "${args[@]}" "$URL" 2>/dev/null
}

echo "url:         $URL"
echo "header:      $HEADER"
echo
CONFIGURED="$(probe "$PLACEHOLDER")"
CONTROL="$(probe "__definitely_not_configured__")"
echo "  configured ($PLACEHOLDER) -> $CONFIGURED"
echo "  control    (unconfigured)              -> $CONTROL"
echo

if [ "$CONFIGURED" = "$CONTROL" ]; then
  case "$CONFIGURED" in
    401|403)
      echo "FAIL: rule is not matching."
      echo "  Check, in this order: host pattern, placeholder string (exact"
      echo "  match, case-sensitive), surface (tick exactly one)."
      ;;
    502)
      echo "FAIL: rule matches but the credential name does not resolve."
      echo "  The service references a credential that is not in the vault"
      echo "  under that exact name."
      ;;
    *)
      echo "INCONCLUSIVE: this endpoint returns $CONFIGURED regardless of auth."
      echo "  Many /v1/models endpoints are unauthenticated. Pick an endpoint"
      echo "  that actually requires a credential."
      ;;
  esac
  exit 1
fi

echo "PASS: substitution is firing."
echo "  A non-200 configured result (400/405/422) is fine: it means the"
echo "  request authenticated and the body was wrong, which is expected here."
