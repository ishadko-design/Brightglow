#!/usr/bin/env bash
# Live check of the deployed `pricing` function: real requests, real answers.
# Fails (exit 1) when a request comes back from the formula instead of the
# local AI estimate, or with a price outside a sane band for that job.
#
# Env: SUPABASE_URL, SUPABASE_ANON_KEY, APP_TOKEN (the function's x-app-token).
set -euo pipefail
: "${SUPABASE_URL:?}" "${SUPABASE_ANON_KEY:?}"

fail=0
# name | json body | min typical | max typical
check() {
  local name="$1" body="$2" min="$3" max="$4"
  local out
  out=$(curl -sS --max-time 90 -X POST "$SUPABASE_URL/functions/v1/pricing" \
    -H "Content-Type: application/json" \
    -H "apikey: $SUPABASE_ANON_KEY" \
    -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
    ${APP_TOKEN:+-H "x-app-token: $APP_TOKEN"} \
    -d "$body") || { echo "FAIL $name: request error"; fail=1; return; }
  local grounded low typical high label
  grounded=$(jq -r '.range.grounded // false' <<<"$out")
  low=$(jq -r '.range.all_in_low // empty' <<<"$out")
  typical=$(jq -r '.range.all_in_typical // empty' <<<"$out")
  high=$(jq -r '.range.all_in_high // empty' <<<"$out")
  label=$(jq -r '.range.label // .display // ""' <<<"$out")
  printf '%-28s grounded=%-5s $%s–$%s (typ $%s)  %s\n' "$name" "$grounded" "${low%.*}" "${high%.*}" "${typical%.*}" "$label"
  if [[ "$grounded" != "true" ]]; then
    echo "  FAIL: answered by the formula, not the local AI estimate"; fail=1
  elif [[ -z "$typical" ]] || (( ${typical%.*} < min || ${typical%.*} > max )); then
    echo "  FAIL: typical outside \$$min–\$$max"; fail=1
  fi
}

# The jobs users reported wrong, in their own words and places.
check "moto oil change (SF)" \
  '{"category":"Repair","description":"Oil change on triumph thruxton 1200r","zip":"94110","vehicle":"moto","city":"San Francisco, CA"}' 100 400
check "sauna install (SF)" \
  '{"category":"Electrical","description":"Install sauna with electric 9kw heater, new circuit needed","zip":"94110","city":"San Francisco, CA"}' 3000 40000
check "sauna circuit only (Daly City)" \
  '{"category":"Electrical","description":"New 50A circuit for my existing outdoor sauna, full circuit wiring","zip":"94015","city":"Daly City, CA"}' 1500 8000

exit $fail
