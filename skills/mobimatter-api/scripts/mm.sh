#!/usr/bin/env bash
# Read-only MobiMatter API access for agents, plus spec refresh.
#
# Every subcommand issues a GET. There is no code path in this script that
# issues POST, PUT, PATCH or DELETE. Order creation, completion, cancellation
# and refunds all move merchant wallet money and belong in the integration
# code a developer runs, never in an agent's hands.
set -euo pipefail

API_BASE="${MOBIMATTER_API_BASE:-https://api.mobimatter.com/mobimatter}"
DOCS_BASE="${MOBIMATTER_DOCS_BASE:-https://docs.mobimatter.com}"
REF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../references" && pwd)"

die() { printf '%s\n' "$*" >&2; exit 1; }

require_creds() {
  [ -n "${MOBIMATTER_API_KEY:-}" ] && [ -n "${MOBIMATTER_MERCHANT_ID:-}" ] && return 0
  die "MOBIMATTER_API_KEY and MOBIMATTER_MERCHANT_ID must be set in the environment.

  export MOBIMATTER_API_KEY=...
  export MOBIMATTER_MERCHANT_ID=...

Get both from the Partner Portal API section. Do not paste the key as an
argument or into chat: it would land in shell history and the transcript."
}

# GET <path-with-query>
get() {
  require_creds
  curl -sS --fail-with-body -X GET "${API_BASE}$1" \
    -H "api-key: ${MOBIMATTER_API_KEY}" \
    -H "merchantId: ${MOBIMATTER_MERCHANT_ID}" \
    -H 'Accept: application/json'
  printf '\n'
}

need() { [ -n "${1:-}" ] || die "$2"; }

# Appends "key=value" to a query string when value is non-empty.
qs=""
add_q() { [ -n "${2:-}" ] && qs="${qs}${qs:+&}$1=$2"; return 0; }

cmd_products() {
  # Optional filters, all server-side. Note: none of these are paging
  # parameters -- the API returns the merchant's whole catalogue.
  local productId="" country="" region="" provider="" category="" familyId=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --product-id=*) productId="${1#*=}" ;;
      --country=*)    country="${1#*=}" ;;
      --region=*)     region="${1#*=}" ;;
      --provider=*)   provider="${1#*=}" ;;
      --category=*)   category="${1#*=}" ;;
      --family-id=*)  familyId="${1#*=}" ;;
      *) die "products: unknown option '$1'" ;;
    esac
    shift
  done
  add_q productId "$productId"; add_q country "$country"; add_q region "$region"
  add_q provider "$provider";   add_q category "$category"; add_q familyId "$familyId"
  get "/api/v2/products${qs:+?$qs}"
}

cmd_product_networks() {
  need "${1:-}" "usage: mm.sh product-networks <productId>"
  get "/api/v2/products/$1/networks"
}

cmd_order() {
  need "${1:-}" "usage: mm.sh order <orderId> [--with-product-details]"
  local q=""
  [ "${2:-}" = "--with-product-details" ] && q="?returnProductDetails=true"
  get "/api/v2/order/$1$q"
}

cmd_order_by_iccid() {
  need "${1:-}" "usage: mm.sh order-by-iccid <iccid>"
  get "/api/v2/order?iccid=$1"
}

cmd_linked() {
  need "${1:-}" "usage: mm.sh linked <rootOrderId> [--completed-only|--completed-with-refunded]"
  local q=""
  case "${2:-}" in
    --completed-only)          q="?completedOnly=true" ;;
    --completed-with-refunded) q="?completedWithRefunded=true" ;;
    "") ;;
    *) die "linked: unknown option '$2'" ;;
  esac
  get "/api/v2/order/$1/linked$q"
}

cmd_usage() {
  need "${1:-}" "usage: mm.sh usage <orderId>"
  # Reaches through to the upstream provider. Do not loop this.
  get "/api/v2/provider/usage/$1"
}

cmd_esim_info() {
  need "${1:-}" "usage: mm.sh esim-info <orderId> [--with-location]"
  # skipLocation defaults to true here: the location lookup is extra work
  # for data most callers never read.
  local skip="true"
  [ "${2:-}" = "--with-location" ] && skip="false"
  get "/api/v2/provider/info/$1?skipLocation=$skip"
}

cmd_balance() { get "/api/v2/merchant/balance"; }

cmd_refund_eligibility() {
  need "${1:-}" "usage: mm.sh refund-eligibility <orderId>"
  get "/api/v2/order/$1/refund/eligibility"
}

# Fetches the published specs. docs.mobimatter.com is the correct source:
# it carries post-processing (merchantId marked required) that the upstream
# API schema endpoint does not.
cmd_spec_refresh() {
  local ok=0
  for pair in "swagger.yaml:swagger.live.yaml" "restricted_apis.json:restricted.live.json"; do
    local remote="${pair%%:*}" local_name="${pair##*:}"
    if curl -sS --fail -o "${REF_DIR}/${local_name}" "${DOCS_BASE}/${remote}"; then
      printf 'fetched %s -> references/%s\n' "${DOCS_BASE}/${remote}" "${local_name}"
      ok=$((ok + 1))
    else
      printf 'FAILED to fetch %s\n' "${DOCS_BASE}/${remote}" >&2
    fi
  done
  if [ "$ok" -eq 2 ]; then
    printf 'SOURCE: live (docs.mobimatter.com)\n'
  else
    printf 'SOURCE: bundled snapshot -- references/swagger.snapshot.yaml and restricted.snapshot.json.\n'
    printf 'These may be stale. Say so in your report to the user.\n'
  fi
}

usage() {
  cat <<'EOF'
mm.sh -- read-only MobiMatter API access. Every subcommand is a GET.

  products [--product-id=X] [--country=AE] [--region=Asia] [--provider=3]
           [--category=esim_realtime|esim_addon|esim_replacement|esim_delayed]
           [--family-id=5]
  product-networks <productId>
  order <orderId> [--with-product-details]
  order-by-iccid <iccid>
  linked <rootOrderId> [--completed-only|--completed-with-refunded]
  usage <orderId>                    # upstream provider call -- never loop
  esim-info <orderId> [--with-location]
  balance
  refund-eligibility <orderId>
  spec-refresh                       # pull published specs, report the source

Credentials come from MOBIMATTER_API_KEY and MOBIMATTER_MERCHANT_ID.

Writes are deliberately absent: creating, completing, cancelling and refunding
orders move real money and belong in generated code, not in an agent session.
EOF
}

case "${1:-}" in
  products)            shift; cmd_products "$@" ;;
  product-networks)    shift; cmd_product_networks "$@" ;;
  order)               shift; cmd_order "$@" ;;
  order-by-iccid)      shift; cmd_order_by_iccid "$@" ;;
  linked)              shift; cmd_linked "$@" ;;
  usage)               shift; cmd_usage "$@" ;;
  esim-info)           shift; cmd_esim_info "$@" ;;
  balance)             shift; cmd_balance "$@" ;;
  refund-eligibility)  shift; cmd_refund_eligibility "$@" ;;
  spec-refresh)        shift; cmd_spec_refresh "$@" ;;
  -h|--help|help|"")   usage ;;
  *) die "unknown subcommand '$1'. Run mm.sh --help." ;;
esac
