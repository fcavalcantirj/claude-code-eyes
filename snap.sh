#!/bin/bash
# claude-code-eyes: grab current frame(s) from a snapshot-capable camera and
# print the JPEG/PNG path(s), one per line, for Claude to Read.
#
# Usage: snap.sh [count] [interval_seconds]
#   snap.sh        -> 1 frame now
#   snap.sh 3 2    -> 3 frames, 2s apart (watch mode)
#
# Config (highest precedence first):
#   1. Environment variables already exported in the shell
#   2. ./.cce.env                                (current working directory)
#   3. $XDG_CONFIG_HOME/claude-code-eyes/config  (default ~/.config/...)
#   Config files only FILL empty variables; exported env always wins.
#
# Keys:
#   CCE_CAM_URL    camera URL (meaning depends on CCE_CAM_TYPE)
#   CCE_CAM_AUTH   optional HTTP basic auth "user:pass"
#   CCE_CAM_TYPE   ipwebcam | camera-streamer | url   (default: url)
#
# Backends:
#   ipwebcam         GET  $CCE_CAM_URL/shot.jpg   (Android "IP Webcam" app)
#   camera-streamer  GET  $CCE_CAM_URL/snapshot   (Raspberry Pi camera-streamer)
#   url              GET  $CCE_CAM_URL            (verbatim; full snapshot URL)
#
# Portable: macOS bash 3.2 and Linux. Runs from any directory.

set -euo pipefail

# The security boundary: config files may set ONLY these keys. This allowlist is
# load-bearing -- it is checked below BEFORE the value ever reaches eval/printf,
# so a .cce.env cannot inject arbitrary variables (and cannot execute code, since
# the loader never `source`s the file). Do not move or remove this check.
CCE_KEYS="CCE_CAM_URL CCE_CAM_AUTH CCE_CAM_TYPE"

# precedence-respecting config loader (bash 3.2 safe; no `source`, no code exec)
load_config_file() {
  local file="$1" line key val cur
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"                 # ltrim
    case "$line" in ''|\#*) continue ;; esac                # blank / comment
    case "$line" in
      export[[:space:]]*) line="${line#export}"             # tolerate `export K=V`
                          line="${line#"${line%%[![:space:]]*}"}" ;;
    esac
    case "$line" in *=*) ;; *) continue ;; esac             # need a KEY=VALUE
    key="${line%%=*}"; val="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"; key="${key%"${key##*[![:space:]]}"}"
    # allowlist gate -- only recognized keys pass; everything else is ignored
    case " $CCE_KEYS " in *" $key "*) ;; *) continue ;; esac
    case "$val" in                                          # strip one quote pair
      \"*\") val="${val#\"}"; val="${val%\"}" ;;
      \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    eval "cur=\${$key:-}"                                    # key is allowlisted
    [ -n "$cur" ] && continue                               # exported env wins
    printf -v "$key" '%s' "$val"                            # fill the gap
  done < "$file"
}

load_config_file "./.cce.env"
XDG="${XDG_CONFIG_HOME:-$HOME/.config}"
load_config_file "$XDG/claude-code-eyes/config"

CCE_CAM_TYPE="${CCE_CAM_TYPE:-url}"
case "$CCE_CAM_TYPE" in
  ipwebcam|camera-streamer|url) ;;
  *) echo "ERROR: unknown CCE_CAM_TYPE='$CCE_CAM_TYPE' (valid: ipwebcam, camera-streamer, url)" >&2
     exit 2 ;;
esac

if [ -z "${CCE_CAM_URL:-}" ]; then
  echo "ERROR: no CCE_CAM_URL configured for CCE_CAM_TYPE=$CCE_CAM_TYPE." >&2
  echo "  Set env CCE_CAM_URL, or add it to ./.cce.env or $XDG/claude-code-eyes/config" >&2
  echo "  (checked: shell env, ./.cce.env, $XDG/claude-code-eyes/config)" >&2
  exit 1
fi

base="${CCE_CAM_URL%/}"                                     # strip one trailing /
case "$CCE_CAM_TYPE" in
  ipwebcam)        ENDPOINT="$base/shot.jpg" ;;
  camera-streamer) ENDPOINT="$base/snapshot" ;;
  url)             ENDPOINT="$CCE_CAM_URL" ;;               # verbatim contract
esac

COUNT="${1:-1}"; INTERVAL="${2:-2}"
case "$COUNT"    in ''|*[!0-9]*) echo "ERROR: count must be a positive integer" >&2; exit 2 ;; esac
case "$INTERVAL" in ''|*[!0-9]*) echo "ERROR: interval must be an integer (seconds)" >&2; exit 2 ;; esac
[ "$COUNT" -ge 1 ] || { echo "ERROR: count must be >= 1" >&2; exit 2; }

OUT_DIR="${TMPDIR:-/tmp}/claude-code-eyes"; mkdir -p "$OUT_DIR"

# empty-array-under-set-u guard (bash 3.2 safe) -- see AUTH_ARGS expansion below
AUTH_ARGS=()
[ -n "${CCE_CAM_AUTH:-}" ] && AUTH_ARGS=(-u "$CCE_CAM_AUTH")

img_ext() {                        # echoes jpg|png, or "" if not an image
  local f="$1" sig
  [ -s "$f" ] || { echo ""; return 0; }
  sig="$(od -An -tx1 -N4 "$f" 2>/dev/null | tr -d ' \n')"
  case "$sig" in
    ffd8ff*)  echo jpg ;;
    89504e47) echo png ;;
    *)        echo "" ;;
  esac
}

grab_one() {                       # $1=path prefix; prints final path on success
  local prefix="$1" tmp="$1.part" ext
  curl -sf --connect-timeout 4 --max-time 15 \
       ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} "$ENDPOINT" -o "$tmp" || return 1
  ext="$(img_ext "$tmp")"
  if [ -z "$ext" ]; then
    rm -f "$tmp"
    echo "ERROR: endpoint returned non-image content (type=$CCE_CAM_TYPE, url=$ENDPOINT)." >&2
    return 2
  fi
  mv "$tmp" "$prefix.$ext"
  printf '%s\n' "$prefix.$ext"
}

i=1
while [ "$i" -le "$COUNT" ]; do
  prefix="$OUT_DIR/frame-$(date +%H%M%S)-$$-$i"
  if out="$(grab_one "$prefix")"; then
    printf '%s\n' "$out"
  else
    rc=$?
    if [ "$rc" -ne 2 ]; then       # rc 2 already printed its own message
      echo "ERROR: camera not reachable (type=$CCE_CAM_TYPE, url=$ENDPOINT, auth=$([ -n "${CCE_CAM_AUTH:-}" ] && echo set || echo none))." >&2
      echo "  Likely: camera app/server not running, IP or port changed, or not on the same network." >&2
    fi
    exit 1
  fi
  [ "$i" -lt "$COUNT" ] && sleep "$INTERVAL"
  i=$((i + 1))
done
exit 0
