#!/bin/bash
#
# Extract a root CA cert from the Windows cert store to a PEM file.
# Bash equivalent of the classic PowerShell "iterate Cert:\LocalMachine\Root
# and Export-Certificate" recipe. Works on machines where PowerShell script
# execution is blocked by policy — this uses certutil.exe (a Windows built-in)
# and standard bash, callable from Git Bash or MSYS2 UCRT64.
#
# Enumerates all Root store certs (LocalMachine + CurrentUser), optionally
# filters by a Subject pattern, then presents an interactive picker (fzf if
# available, numbered menu fallback) so you can confirm the correct cert
# before extraction. Extraction is by SHA-1 fingerprint (always unique), so
# it never silently picks the wrong cert even if the pattern matches many.
#
# Usage:
#   ./extract-corp-ca.sh [OUT_PATH]
#
# Env vars (all optional):
#   CORP_CA_PATTERN  Case-insensitive extended-regex filter on Subject line.
#                    If unset or matches nothing, the picker shows all certs.
#                    Examples:
#                      CORP_CA_PATTERN='MyOrg'
#                      CORP_CA_PATTERN='MyOrg|LegacyName'
#   YES              If set to 1 AND the filter narrows to exactly one match,
#                    extract without prompting. For scripting.
#
# Requires: certutil.exe (Windows built-in), bash, cygpath. fzf optional.
#
set -euo pipefail

OUT="${1:-$HOME/.local/share/corp-ca.cer}"
PATTERN="${CORP_CA_PATTERN:-}"
AUTO_YES="${YES:-0}"

mkdir -p "$(dirname "$OUT")"

if ! command -v certutil.exe >/dev/null 2>&1; then
  echo "certutil.exe not on PATH. Requires Windows + Git Bash or MSYS2." >&2
  exit 1
fi

# Enumerate certs from one store. Emits tab-separated:
#   SHA1<TAB>Subject<TAB>Scope<TAB>NotAfter
enumerate_certs() {
  local flag="$1" scope="$2"
  certutil.exe -store $flag Root 2>/dev/null | tr -d '\r' | awk -v scope="$scope" '
    function emit() {
      if (sha1 != "" && subject != "") {
        print sha1 "\t" subject "\t" scope "\t" not_after
      }
    }
    /^================ Certificate/ {
      emit()
      sha1=""; subject=""; not_after=""
      next
    }
    /^Subject:/           { sub(/^Subject: */, ""); subject = $0 }
    /^ *NotAfter:/        { sub(/^ *NotAfter: */, ""); not_after = $0 }
    /^Cert Hash\(sha1\):/ { sha1 = $NF }
    END { emit() }
  '
}

echo "Enumerating Root store certs (LocalMachine + CurrentUser)..." >&2
certs=$(
  {
    enumerate_certs ""      "LocalMachine"
    enumerate_certs "-user" "CurrentUser"
  } | sort -u
)

if [ -z "$certs" ]; then
  echo "No certs found in the Root store." >&2
  exit 1
fi

# Apply pattern filter if provided
if [ -n "$PATTERN" ]; then
  filtered=$(echo "$certs" | grep -iE "$PATTERN" || true)
  if [ -z "$filtered" ]; then
    echo "Warning: pattern '$PATTERN' matched no certs. Showing all." >&2
    filtered="$certs"
  fi
else
  filtered="$certs"
fi

match_count=$(printf '%s\n' "$filtered" | grep -c '^')

# Extract without prompting if unique filter match + YES=1
if [ "$match_count" = "1" ] && [ "$AUTO_YES" = "1" ] && [ -n "$PATTERN" ]; then
  selected="$filtered"
else
  # Interactive selection. Prefer fzf; fall back to numbered `select`.
  if command -v fzf >/dev/null 2>&1; then
    # Pre-format a display column with short SHA + subject + scope + expiry.
    # Keep the full record tab-separated after it for post-selection lookup.
    display=$(echo "$filtered" | awk -F'\t' '{
      short = substr($1, 1, 8)
      printf "[%s] %-70s (%s, exp: %s)\t%s\t%s\t%s\t%s\n",
        short, $2, $3, $4, $1, $2, $3, $4
    }')
    selected_line=$(echo "$display" | fzf \
      --with-nth=1 --delimiter=$'\t' \
      --header="Select CA cert to extract to $OUT  |  Enter=pick, Esc=cancel" \
      --height=50% --reverse --border --no-info) || true
    if [ -z "$selected_line" ]; then
      echo "Cancelled." >&2
      exit 1
    fi
    # Rebuild the record from fields 2..5 of the fzf-selected line
    selected=$(echo "$selected_line" | cut -f2-5)
  else
    # No fzf — numbered menu via read.
    mapfile -t rows < <(printf '%s\n' "$filtered")
    echo "" >&2
    i=1
    for row in "${rows[@]}"; do
      subject=$(printf '%s' "$row" | cut -f2)
      scope=$(  printf '%s' "$row" | cut -f3)
      exp=$(    printf '%s' "$row" | cut -f4)
      printf "  %2d) %-70s [%s]  exp: %s\n" "$i" "$subject" "$scope" "$exp" >&2
      i=$((i+1))
    done
    echo "" >&2
    read -rp "Select (1-${#rows[@]}, or 0 to cancel): " choice
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#rows[@]}" ]; then
      echo "Cancelled." >&2
      exit 1
    fi
    selected="${rows[$((choice-1))]}"
  fi
fi

sha1=$(   printf '%s' "$selected" | cut -f1)
subject=$(printf '%s' "$selected" | cut -f2)
scope=$(  printf '%s' "$selected" | cut -f3)

echo "" >&2
echo "Extracting: $subject" >&2
echo "  SHA-1:    $sha1" >&2
echo "  Scope:    $scope" >&2
echo "  Output:   $OUT" >&2

scope_flag=""
[ "$scope" = "CurrentUser" ] && scope_flag="-user"

tmpder=$(mktemp -t corp-ca.XXXXXX.der)
tmppem=$(mktemp -t corp-ca.XXXXXX.pem)
trap 'rm -f "$tmpder" "$tmppem"' EXIT

# certutil refuses to overwrite existing outfiles (ERROR_FILE_EXISTS 0x80070050).
# mktemp creates the files atomically to reserve unique paths — delete them so
# certutil sees empty slots and can write fresh.
rm -f "$tmpder" "$tmppem"

# Extract by SHA-1 (unambiguous, always exactly one match if the hash exists)
if ! certutil.exe -store $scope_flag -silent Root "$sha1" \
      "$(cygpath -w "$tmpder")" >/dev/null 2>&1; then
  echo "certutil failed to extract cert with SHA-1 $sha1 from $scope Root" >&2
  exit 1
fi
if [ ! -s "$tmpder" ]; then
  echo "Extraction produced an empty DER file. Something went wrong." >&2
  exit 1
fi

# DER -> PEM. certutil -encode adds a Windows-format wrapper; strip it and
# keep only the actual PEM block so downstream tools (curl, openssl, gpg,
# update-ca-trust) don't choke on it. Normalize CRLF -> LF.
certutil.exe -encode "$(cygpath -w "$tmpder")" "$(cygpath -w "$tmppem")" >/dev/null
sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' "$tmppem" \
  | tr -d '\r' > "$OUT"

if [ ! -s "$OUT" ]; then
  echo "Output file is empty after PEM extraction. Check $tmppem." >&2
  exit 1
fi

echo "" >&2
echo "Done. Wrote $(wc -l < "$OUT") lines to $OUT" >&2
