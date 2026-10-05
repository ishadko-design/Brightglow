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
  local out t0 secs
  t0=$(date +%s.%N)
  out=$(curl -sS --max-time 90 -X POST "$SUPABASE_URL/functions/v1/pricing" \
    -H "Content-Type: application/json" \
    -H "apikey: $SUPABASE_ANON_KEY" \
    -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
    ${APP_TOKEN:+-H "x-app-token: $APP_TOKEN"} \
    -d "$body") || { echo "FAIL $name: request error"; fail=1; return; }
  secs=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')
  local grounded low typical high label
  grounded=$(jq -r '.range.grounded // false' <<<"$out")
  low=$(jq -r '.range.all_in_low // empty' <<<"$out")
  typical=$(jq -r '.range.all_in_typical // empty' <<<"$out")
  high=$(jq -r '.range.all_in_high // empty' <<<"$out")
  label=$(jq -r '.range.label // .display // ""' <<<"$out")
  printf '%-28s %5ss  grounded=%-5s $%s–$%s (typ $%s)  %s\n' "$name" "$secs" "$grounded" "${low%.*}" "${high%.*}" "${typical%.*}" "$label"
  if [[ "$grounded" != "true" ]]; then
    echo "  FAIL: answered by the formula, not the local AI estimate"; fail=1
  elif [[ -z "$typical" ]] || (( ${typical%.*} < min || ${typical%.*} > max )); then
    echo "  FAIL: typical outside \$$min–\$$max"; fail=1
  fi
}

# The jobs users reported wrong, in their own words and places.
check "moto oil change (SF)" \
  '{"category":"Repair","description":"Oil change on triumph thruxton 1200r","zip":"94110","vehicle":"moto","city":"San Francisco, CA"}' 100 400
# Floor 2500: a sauna install priced as the circuit alone runs ~$1.5–2.2k
# typical; the AI's own install-only estimate (owned unit) is ~$2.9k.
check "sauna install (SF)" \
  '{"category":"Electrical","description":"Install sauna with electric 9kw heater, new circuit needed","zip":"94110","city":"San Francisco, CA"}' 2500 40000
check "sauna circuit only (Daly City)" \
  '{"category":"Electrical","description":"New 50A circuit for my existing outdoor sauna, full circuit wiring","zip":"94015","city":"Daly City, CA"}' 1500 8000
# The FIRST number a user sees comes from the fast phase — it must be quick.
check "flat roof patch, fast (SF)" \
  '{"category":"Roofing","description":"Patch my flat roof","zip":"94110","city":"San Francisco, CA","fast":true}' 250 3000
check "flat roof patch (SF)" \
  '{"category":"Roofing","description":"Patch flat roof","zip":"94110","city":"San Francisco, CA"}' 250 3000
# Auto jobs go through the same one-job path (rear quarter panel, glass).
check "rear quarter panel dent (SF)" \
  '{"category":"Body & Paint","description":"Rear quarter panel dent repair","zip":"94110","vehicle":"car","city":"San Francisco, CA"}' 300 4500
check "moto 16k service (Daly City)" \
  '{"category":"Repair","description":"Triumph thruxton 1200r regular maintenance for 16k miles, full inspection, oil and filter change","zip":"94015","vehicle":"moto","city":"Daly City, CA"}' 350 1500
check "windshield chip (SF)" \
  '{"category":"Glass","description":"Windshield chip repair","zip":"94110","vehicle":"car","city":"San Francisco, CA"}' 50 600

# Same job, different words -> ONE cached price (the cache keys on the
# taxonomy job, not the phrasing; 2026-10-03).
same_job() {
  local a="$1" b="$2" ta tb
  ta=$(curl -sS --max-time 90 -X POST "$SUPABASE_URL/functions/v1/pricing" -H "Content-Type: application/json" \
    -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $SUPABASE_ANON_KEY" ${APP_TOKEN:+-H "x-app-token: $APP_TOKEN"} \
    -d "$a" | jq -r '.range.all_in_typical // empty')
  tb=$(curl -sS --max-time 90 -X POST "$SUPABASE_URL/functions/v1/pricing" -H "Content-Type: application/json" \
    -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $SUPABASE_ANON_KEY" ${APP_TOKEN:+-H "x-app-token: $APP_TOKEN"} \
    -d "$b" | jq -r '.range.all_in_typical // empty')
  if [[ -n "$ta" && "$ta" == "$tb" ]]; then
    echo "same job, same price: typ \$${ta%.*}"
  else
    echo "FAIL same job, different prices: \$${ta%.*} vs \$${tb%.*}"; fail=1
  fi
}
same_job '{"category":"Roofing","description":"Patch flat roof","zip":"94110","city":"San Francisco, CA","fast":true}' \
         '{"category":"Roofing","description":"Patch my flat roof","zip":"94110","city":"San Francisco, CA","fast":true}'

exit $fail
