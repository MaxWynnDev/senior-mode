#!/usr/bin/env bash
# senior-mode stack detector. Scores every profile under stacks/ against a
# repository and prints the ranked evidence, so an agent (or a human) can
# pick a profile from facts instead of guesses.
#
#   bash stacks/detect.sh [--json] [<repo-dir>]      (default: cwd)
#   bash stacks/detect.sh --list                       the picker: every profile with its card
#
# Each profile declares its signals in stacks/<name>/detect.txt, one per
# line, bash-parsable, no JSON tooling required:
#
#   file   <weight>  <relative path>              path exists
#   glob   <weight>  <glob relative to repo>      any match exists (one level of * only)
#   grep   <weight>  <relative path>  <regex>     file exists AND matches (extended regex, case-insensitive)
#   #      comment
#
# Output (text mode):
#   one line per profile with a non-zero score, best first, with the
#   signals that fired; then a verdict line:
#     DETECTED: <name> (score N, confidence high|medium)   best score >= 20
#     CANDIDATES: <a>, <b>                                  best score < 20 but > 0
#     UNKNOWN: manifests present, no profile matched         some manifest exists
#     GREENFIELD: no manifest found                          nothing to detect from
#   Confidence is high when the best score beats the runner-up by 15+.
#
# Exit code: 0 always (detection is advice, not a gate). Fails open on a
# malformed detect.txt line (the line is skipped and noted).

set -u

JSON=no
DIR=""
for a in "$@"; do
  case "$a" in
    --json) JSON=yes ;;
    --list)
      # The picker: one card per profile, from profile.json (single-line string fields only).
      STACKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
      field() { sed -n "s/^[[:space:]]*\"$2\"[[:space:]]*:[[:space:]]*\"\(.*\)\",\{0,1\}[[:space:]]*$/\1/p" "$1" | head -1; }
      echo "senior-mode stack profiles (install with: bash install.sh --stack <name> <repo>)"
      echo
      for pdir in "$STACKS"/*/; do
        pj="$pdir/profile.json"; [ -f "$pj" ] || continue
        printf '  %-26s %s\n' "$(basename "$pdir")" "$(field "$pj" title)"
        printf '  %-26s for: %s\n' "" "$(field "$pj" recommended_for)"
        printf '  %-26s not: %s\n\n' "" "$(field "$pj" not_for)"
      done
      echo "  none                       adapt the core to the project without a profile (STACK.md)"
      exit 0 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) DIR="$a" ;;
  esac
done
DIR="${DIR:-$PWD}"
DIR="$(cd "$DIR" 2>/dev/null && pwd)" || { echo "detect: no such directory" >&2; exit 0; }
STACKS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

MANIFESTS="package.json pyproject.toml requirements.txt setup.py Pipfile go.mod Cargo.toml Gemfile composer.json mix.exs pom.xml build.gradle build.gradle.kts Package.swift pubspec.yaml Gemfile.lock deno.json bun.lockb"

has_manifest=no
for m in $MANIFESTS; do [ -e "$DIR/$m" ] && has_manifest=yes && break; done

names=(); scores=(); evidence=()
for pdir in "$STACKS"/*/; do
  name=$(basename "$pdir")
  [ -f "$pdir/detect.txt" ] || continue
  score=0; ev=""
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [ -z "$line" ] && continue
    kind=${line%% *}; rest=${line#* }; rest="${rest#"${rest%%[![:space:]]*}"}"
    w=${rest%% *}; rest=${rest#* }; rest="${rest#"${rest%%[![:space:]]*}"}"
    case "$w" in ''|*[!0-9]*) ev="$ev; skipped malformed line: $line"; continue ;; esac
    case "$kind" in
      file)
        if [ -e "$DIR/$rest" ]; then score=$((score + w)); ev="$ev; $rest exists"; fi ;;
      glob)
        # shellcheck disable=SC2086
        for hit in $DIR/$rest; do
          if [ -e "$hit" ]; then score=$((score + w)); ev="$ev; ${hit#$DIR/} exists"; break; fi
        done ;;
      grep)
        f=${rest%% *}; pat=${rest#* }; pat="${pat#"${pat%%[![:space:]]*}"}"
        if [ -f "$DIR/$f" ] && grep -qiE -- "$pat" "$DIR/$f" 2>/dev/null; then
          score=$((score + w)); ev="$ev; $f matches /$pat/"
        fi ;;
      *) ev="$ev; skipped unknown signal: $kind" ;;
    esac
  done < "$pdir/detect.txt"
  if [ "$score" -gt 0 ]; then
    names+=("$name"); scores+=("$score"); evidence+=("${ev#; }")
  fi
done

# sort indices by score desc (small n; simple selection sort)
n=${#names[@]}
order=()
for ((i=0;i<n;i++)); do order+=("$i"); done
for ((i=0;i<n;i++)); do
  for ((j=i+1;j<n;j++)); do
    if [ "${scores[${order[$j]}]}" -gt "${scores[${order[$i]}]}" ]; then t=${order[$i]}; order[$i]=${order[$j]}; order[$j]=$t; fi
  done
done

best=""; best_score=0; second_score=0
if [ "$n" -gt 0 ]; then best=${names[${order[0]}]}; best_score=${scores[${order[0]}]}; fi
if [ "$n" -gt 1 ]; then second_score=${scores[${order[1]}]}; fi

if [ "$n" -eq 0 ]; then
  if [ "$has_manifest" = yes ]; then verdict=UNKNOWN; else verdict=GREENFIELD; fi
elif [ "$best_score" -ge 20 ]; then
  verdict=DETECTED
else
  verdict=CANDIDATES
fi
if [ $((best_score - second_score)) -ge 15 ]; then confidence=high; else confidence=medium; fi

if [ "$JSON" = yes ]; then
  esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
  printf '{"dir":"%s","verdict":"%s","best":"%s","confidence":"%s","candidates":[' "$(esc "$DIR")" "$verdict" "$(esc "$best")" "$confidence"
  first=yes
  for i in "${order[@]}"; do
    [ "$first" = yes ] || printf ','
    first=no
    printf '{"name":"%s","score":%s,"evidence":"%s"}' "${names[$i]}" "${scores[$i]}" "$(esc "${evidence[$i]}")"
  done
  printf ']}\n'
  exit 0
fi

echo "senior-mode stack detection: $DIR"
if [ "$n" -eq 0 ]; then
  echo "  (no profile signals fired)"
else
  for i in "${order[@]}"; do
    printf '  %-28s score %-4s %s\n' "${names[$i]}" "${scores[$i]}" "${evidence[$i]}"
  done
fi
case "$verdict" in
  DETECTED)   echo "DETECTED: $best (score $best_score, confidence $confidence)" ;;
  CANDIDATES) list=""; for i in "${order[@]}"; do list="$list, ${names[$i]}"; done; echo "CANDIDATES: ${list#, } (weak signals; confirm with the user or adapt without a profile)" ;;
  UNKNOWN)    echo "UNKNOWN: manifests present, no profile matched. Adapt the core to this stack (STACK.md) or write a profile." ;;
  GREENFIELD) echo "GREENFIELD: no manifest found. Present the picker (stacks/README.md) and let the user choose." ;;
esac
exit 0
