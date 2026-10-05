#!/usr/bin/env bash
# Flags suspicious AI price cache rows. Reads the rows as JSON on stdin:
#   [{cache_key, low, typical, high, searched, created_at}, ...]
# Prints only keys and numbers (the repo is PUBLIC). Exit 1 when anything is flagged.
#
# Rules (each one is a bug we have actually shipped):
#  kind   - the key's kind (auto/moto/home) disagrees with its job type
#           ("auto:moto.tune_up": a bike job priced with the car prompt, 2026-10-05)
#  split  - one job type under one metro has bands >4x apart (the same job cached
#           twice with different answers)
#  shape  - low > typical > high, or high > 8x low
set -euo pipefail
out=$(jq -r '
  def num: tonumber? // 0;
  # it2:<metro>:[kind:]<jobid or words>[|facts]
  def parts: (.cache_key | ltrimstr("it2:") | split(":")) as $p
    | {metro: $p[0], rest: ($p[1:])};
  [ .[] | . + parts
    | . as $r
    | ($r.rest | if (.[0] == "auto" or .[0] == "moto") then .[0] else "home" end) as $kind
    | ($r.rest | if (.[0] == "auto" or .[0] == "moto") then .[1:] else . end | join(":") | split("|")[0]) as $job
    | {key: $r.cache_key, metro: $r.metro, kind: $kind, job: $job,
       low: ($r.low|num), typ: ($r.typical|num), high: ($r.high|num),
       base: (($r.cache_key | contains("|")) | not)} ] as $rows
  | (
    # kind vs job type
    ($rows[] | select(.job | test("^[a-z]+\\.[a-z_]+$"))
      | select(
          (.kind == "moto" and (.job | startswith("moto.") | not)) or
          (.kind == "auto" and (.job | startswith("auto.") | not)) or
          (.kind == "home" and (.job | test("^(moto|auto)\\.")))
        )
      | "kind   \(.key)  (kind \(.kind) vs job \(.job))"),
    # same job, wildly different answers (base rows only; facts legitimately move price)
    ( $rows | map(select(.base and (.job | test("^[a-z]+\\.[a-z_]+$")))) | group_by(.metro + .kind + .job)[]
      | select(length > 1) | select((map(.typ) | max) > 4 * ((map(.typ) | min) + 1))
      | "split  \(.[0].metro):\(.[0].kind):\(.[0].job)  typicals \(map(.typ) | join(" / "))" ),
    ( $rows[] | select(.typ > 0 and (.low > .typ or .typ > .high or .high > 8 * (.low + 1)))
      | "shape  \(.key)  $\(.low)-$\(.high) typ $\(.typ)" )
  )
'
)
if [ -n "$out" ]; then
  echo "Suspicious price cache rows:"; echo "$out"; exit 1
fi
echo "Price cache audit: clean"
