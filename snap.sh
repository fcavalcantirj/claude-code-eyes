#!/bin/bash
# claude-code-eyes: grab current frame(s) from a snapshot-capable camera and
# print the JPEG/PNG path(s), one per line, for Claude to Read.
#
# Usage: snap.sh [--zoom N] [--focus] [count] [interval_seconds]
#   snap.sh              -> 1 frame now
#   snap.sh 3 2          -> 3 frames, 2s apart (watch mode)
#   snap.sh --zoom 4     -> zoom 4x, capture, then restore the previous zoom
#   snap.sh --focus      -> trigger autofocus, then capture
#
# --zoom / --focus need CCE_CAM_TYPE=ipwebcam (Android "IP Webcam"). Other
# backends say so and still capture. N is a magnification from 1 to 10.
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
#   CCE_OUT_DIR    where frames are written (default: ./.claude-code-eyes)
#
# Frames go under the WORKING DIRECTORY, not $TMPDIR, on purpose: Claude Code's
# Bash sandbox gives sandboxed commands a different $TMPDIR than the (unsandboxed)
# Read tool sees, so a $TMPDIR path printed here can be unreadable there. The
# working directory is the one location both agree on.
# See https://code.claude.com/docs/en/sandboxing
#
# Backends:
#   ipwebcam         GET  $CCE_CAM_URL/shot.jpg   (Android "IP Webcam" app)
#   camera-streamer  GET  $CCE_CAM_URL/snapshot   (Raspberry Pi camera-streamer)
#   url              GET  $CCE_CAM_URL            (verbatim; full snapshot URL)
#
# Portable: macOS bash 3.2 and Linux. Runs from any directory.

set -euo pipefail

# Absolute path to this script. The sandbox advice below has to name the command
# the way it is ACTUALLY invoked: Claude Code matches excludedCommands with
#   prefix: cmd === entry || cmd.startsWith(entry + " ")      exact: cmd === entry
# so a bare "bash snap.sh" never matches "bash /path/to/snap.sh". Using the
# absolute path as a prefix also covers watch mode ("... snap.sh 3 2").
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
if [ -n "$SELF_DIR" ]; then SELF="$SELF_DIR/$(basename "$0")"; else SELF="$0"; fi

# The security boundary: config files may set ONLY these keys. This allowlist is
# load-bearing -- it is checked below BEFORE the value ever reaches eval/printf,
# so a .cce.env cannot inject arbitrary variables (and cannot execute code, since
# the loader never `source`s the file). Do not move or remove this check.
CCE_KEYS="CCE_CAM_URL CCE_CAM_AUTH CCE_CAM_TYPE CCE_OUT_DIR"

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

ZOOM=""; DO_FOCUS=0; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --zoom)  ZOOM="${2:-}"; shift 2 ;;
    --focus) DO_FOCUS=1; shift ;;
    --)      shift; break ;;
    -*)      echo "ERROR: unknown option '$1' (valid: --zoom N, --focus)" >&2; exit 2 ;;
    *)       POS[${#POS[@]}]="$1"; shift ;;
  esac
done
set -- ${POS[@]+"${POS[@]}"}

# --zoom takes a magnification (1..10), not raw device units. The device scale is
# 100..1000 where 100 = 1x, so units = N*100, then snapped to an allowed step.
ZOOM_UNITS=""
if [ -n "$ZOOM" ]; then
  case "$ZOOM" in
    ''|*[!0-9.]*|*.*.*) echo "ERROR: --zoom takes a number from 1 to 10 (got '$ZOOM')" >&2; exit 2 ;;
  esac
  ZOOM_UNITS="$(awk -v z="$ZOOM" 'BEGIN{printf "%d", z*100}')"
  if [ "$ZOOM_UNITS" -lt 100 ] || [ "$ZOOM_UNITS" -gt 1000 ]; then
    echo "ERROR: --zoom must be between 1 and 10 (got '$ZOOM')" >&2; exit 2
  fi
fi

COUNT="${1:-1}"; INTERVAL="${2:-2}"
case "$COUNT"    in ''|*[!0-9]*) echo "ERROR: count must be a positive integer" >&2; exit 2 ;; esac
case "$INTERVAL" in ''|*[!0-9]*) echo "ERROR: interval must be an integer (seconds)" >&2; exit 2 ;; esac
[ "$COUNT" -ge 1 ] || { echo "ERROR: count must be >= 1" >&2; exit 2; }

OUT_DIR="${CCE_OUT_DIR:-$PWD/.claude-code-eyes}"; mkdir -p "$OUT_DIR"

# empty-array-under-set-u guard (bash 3.2 safe) -- see AUTH_ARGS expansion below
AUTH_ARGS=()
[ -n "${CCE_CAM_AUTH:-}" ] && AUTH_ARGS=(-u "$CCE_CAM_AUTH")

# --- camera control ----------------------------------------------------------
# Verified against IP Webcam on a real phone, 2026-08-20:
#   /settings/zoom?set=V   absolute; V must be one of avail.zoom (100=1x .. 1000=max)
#   /ptz?zoom=P            PERCENT 0..100, NOT absolute -- ptz?zoom=200 slams to max
#   /focus /nofocus        momentary trigger; focusmode is unchanged
#   success = the response BODY contains "Ok" (the status code is 200 either way)
#   curvals.zoom LAGS the set by several seconds, so we poll instead of assuming
# Note: pydroid-ipcam documents /settings/ptz?zoom=N -- that 404s on the device.
ctrl_get() {                       # $1=path -> body on stdout, non-zero if unreachable
  curl -sf --connect-timeout 4 --max-time 10 \
       ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} "$base$1" 2>/dev/null
}

ctrl_ok() { ctrl_get "$1" | grep -q "Ok"; }

zoom_now()   { ctrl_get "/status.json" | grep -o '"zoom":"[0-9]*"' | head -1 | grep -o '[0-9][0-9]*'; }
zoom_avail() { ctrl_get "/status.json?show_avail=1" | grep -o '"zoom":\[[^]]*\]' | grep -o '[0-9][0-9]*'; }

nearest_zoom() {                   # $1=target units -> closest allowed step
  local t="$1" best="" bd=999999 v d
  for v in $(zoom_avail); do
    if [ "$t" -gt "$v" ]; then d=$((t - v)); else d=$((v - t)); fi
    if [ "$d" -lt "$bd" ]; then bd="$d"; best="$v"; fi
  done
  printf '%s\n' "$best"
}

set_zoom() {                       # $1=units; waits out the status lag
  local v="$1" i=0
  ctrl_ok "/settings/zoom?set=$v" || return 1
  while [ "$i" -lt 8 ]; do
    [ "$(zoom_now)" = "$v" ] && return 0
    sleep 1; i=$((i + 1))
  done
  return 0                         # applied; status just never caught up
}

ZOOM_ORIG=""
restore_zoom() {                   # never leave the camera zoomed for the next capture
  [ -n "$ZOOM_ORIG" ] || return 0
  ctrl_get "/settings/zoom?set=$ZOOM_ORIG" >/dev/null 2>&1 || true
  ZOOM_ORIG=""
}
trap restore_zoom EXIT INT TERM

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

RETRIES=3                          # phones (Android IP Webcam) refuse the first
                                   # connection while dozing; retry before giving up
host_port() {                      # "http://u:p@1.2.3.4:8080/shot.jpg" -> "1.2.3.4:8080"
  local u="${1#*://}"
  u="${u##*@}"
  printf '%s\n' "${u%%/*}"
}

proxy_set() {                      # a proxy is configured (the sandbox always sets one)
  [ -n "${HTTP_PROXY:-}${HTTPS_PROXY:-}${ALL_PROXY:-}" ] && return 0
  [ -n "${http_proxy:-}${https_proxy:-}${all_proxy:-}" ] && return 0
  return 1
}

# Why the HTTP status and not just "a proxy is set": inside Claude Code's sandbox a
# proxy is ALWAYS set, so its presence says nothing about why a request failed.
# Measured under a sandboxed session (Claude Code 2.1.236):
#   * a PUBLIC destination that is not allow-listed is refused by the proxy -> HTTP 403
#   * a PRIVATE/LAN destination is blocked below the proxy -> connection failure, no status
#   * an allow-listed camera that is merely asleep ALSO gives a connection failure
# So a connection failure is ambiguous and must never be reported as a sandbox verdict.
# The two blocks also need DIFFERENT fixes: sandbox.network.allowedDomains rejects
# private ranges outright ("Public domain names are required"), so a LAN camera can
# only be reached by excluding the capture command from the sandbox.
is_private_host() {                # $1=host[:port] -> 0 if RFC1918 / loopback / .local
  local h="${1%%:*}"
  case "$h" in
    localhost|*.local|*.internal|*.localdomain) return 0 ;;
    10.*|127.*|169.254.*|192.168.*)             return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*)      return 0 ;;
  esac
  return 1
}

sandbox_fix() {                    # $1=host:port -- print the remedy that actually works
  local hp="$1"
  if is_private_host "$hp"; then
    echo "  $hp is a private/LAN address. The sandbox blocks those below the proxy, and" >&2
    echo "  sandbox.network.allowedDomains cannot admit them (it requires public domains)." >&2
    echo "  Quickest: if Claude offers to retry the command outside the sandbox, approve it" >&2
    echo "  -- that captures the frame with no config change at all." >&2
    echo "  Permanent fix, in ~/.claude/settings.json:" >&2
    echo "      { \"sandbox\": { \"excludedCommands\": [\"bash $SELF\"] } }" >&2
    echo "  The path must match how it is invoked (matching is exact/prefix, not fuzzy);" >&2
    echo "  as a prefix this entry also covers watch mode." >&2
  else
    echo "  Fix: allow-list the camera in ~/.claude/settings.json, then restart Claude Code:" >&2
    echo "      { \"sandbox\": { \"network\": { \"allowedDomains\": [\"$hp\"] } } }" >&2
    echo "  IPs must be listed EXACTLY -- wildcards never match an IP." >&2
  fi
  echo "  Inspect the active policy with /sandbox. https://code.claude.com/docs/en/sandboxing" >&2
}

proxy_verdict() {                  # $1=header file -- echo the proxy's own reason, if any
  [ -f "${1:-}" ] || return 1
  grep -i -E '^(x-proxy-error|x-squid-error|proxy-agent|via|x-blocked-by):' "$1" 2>/dev/null \
    | tr -d '\r' | head -3
}

diagnose() {                       # $1=curl exit  $2=http status ("000")  $3=header file
  local rc="$1" code="$2" hdr="${3:-}" HP verdict
  HP="$(host_port "$ENDPOINT")"
  if [ "$code" = "403" ]; then
    echo "ERROR: $HP answered 403 Forbidden." >&2
    verdict="$(proxy_verdict "$hdr" || true)"
    if [ -n "$verdict" ]; then
      echo "  The refusal came from a proxy, which identified itself:" >&2
      printf '      %s\n' "$verdict" >&2
    fi
    if [ -n "$verdict" ] || proxy_set; then
      # Several different systems produce an identical 403 here. Name them rather
      # than assert one: a field report (2026-08-20) traced this exact shape to a
      # cloud device-bridge egress proxy, NOT to Claude Code's sandbox.
      echo "  A 403 in front of a camera usually means one of:" >&2
      echo "    1. a cloud or bridged session's egress proxy (its allowlist is the host's," >&2
      echo "       not yours -- a local settings change cannot open it), or" >&2
      echo "    2. a corporate/system proxy, or" >&2
      echo "    3. Claude Code's own Bash sandbox, if you run Claude Code locally, or" >&2
      echo "    4. the camera itself rejecting the request." >&2
      echo "  If (3) applies:" >&2
      sandbox_fix "$HP"
      echo "  If your session has no route to the LAN at all, no setting fixes it --" >&2
      echo "  fetch the snapshot from a browser running on the LAN host instead." >&2
    else
      echo "  No proxy is configured for this shell, so this 403 came from the camera:" >&2
      echo "  it is reachable but refused this request (type=$CCE_CAM_TYPE, url=$ENDPOINT)." >&2
      echo "  Check the path for this backend, and whether the camera wants auth" >&2
      echo "  (CCE_CAM_AUTH is $([ -n "${CCE_CAM_AUTH:-}" ] && echo set || echo unset))." >&2
    fi
  elif [ "$code" = "401" ]; then
    echo "ERROR: $HP returned 401 Unauthorized." >&2
    echo "  The camera wants HTTP basic auth. Set CCE_CAM_AUTH=user:pass" >&2
    echo "  (currently $([ -n "${CCE_CAM_AUTH:-}" ] && echo set || echo unset))." >&2
  elif [ "$code" != "000" ] && [ "$code" != "200" ]; then
    echo "ERROR: $HP returned HTTP $code (type=$CCE_CAM_TYPE, url=$ENDPOINT)." >&2
    echo "  The host answered, so it is reachable -- check the path for this backend." >&2
  else
    echo "ERROR: camera not reachable (type=$CCE_CAM_TYPE, url=$ENDPOINT, auth=$([ -n "${CCE_CAM_AUTH:-}" ] && echo set || echo none))." >&2
    echo "  Tried $RETRIES times, curl exit $rc -- no HTTP response at all." >&2
    echo "  Likely: camera app/server not running, phone asleep, IP or port changed," >&2
    echo "  or not on the same network." >&2
    if proxy_set; then
      echo "  This shell is sandboxed, which looks identical at this layer. If your own" >&2
      echo "  terminal CAN reach $HP but Claude cannot, it is the sandbox:" >&2
      sandbox_fix "$HP"
    fi
  fi
}

# grab_one() runs inside a command substitution (a subshell), so it cannot export
# state back to the caller -- it prints its own diagnosis to stderr (which is NOT
# captured) and returns non-zero. Only the captured path goes to stdout.
grab_one() {                       # $1=path prefix; prints final path on success
  local prefix="$1" tmp="$1.part" hdr="$1.hdr" ext attempt=1 code rc
  while :; do
    # no -f: let curl report the status instead of collapsing every 4xx into exit 22
    if code="$(curl -s -o "$tmp" -D "$hdr" -w '%{http_code}' --connect-timeout 4 --max-time 15 \
                    ${AUTH_ARGS[@]+"${AUTH_ARGS[@]}"} "$ENDPOINT" 2>/dev/null)"; then
      rc=0
    else
      rc=$?; code="000"
    fi
    [ "$rc" -eq 0 ] && [ "$code" = "200" ] && break
    # only a connection-level failure is worth retrying; an HTTP status is an answer
    if [ "$rc" -ne 0 ] && [ "$attempt" -lt "$RETRIES" ]; then
      attempt=$((attempt + 1)); sleep 1; continue
    fi
    rm -f "$tmp"
    diagnose "$rc" "$code" "$hdr"
    rm -f "$hdr"
    return 1
  done
  ext="$(img_ext "$tmp")"
  if [ -z "$ext" ]; then
    rm -f "$tmp"
    echo "ERROR: endpoint returned non-image content (type=$CCE_CAM_TYPE, url=$ENDPOINT)." >&2
    return 2
  fi
  rm -f "$hdr"
  mv "$tmp" "$prefix.$ext"
  printf '%s\n' "$prefix.$ext"
}

if [ -n "$ZOOM" ] || [ "$DO_FOCUS" -eq 1 ]; then
  if [ "$CCE_CAM_TYPE" != "ipwebcam" ]; then
    echo "NOTE: zoom/focus control needs CCE_CAM_TYPE=ipwebcam (this is $CCE_CAM_TYPE)." >&2
    echo "  Capturing at the camera's current settings instead." >&2
  else
    if [ "$DO_FOCUS" -eq 1 ]; then
      if ctrl_ok "/focus"; then sleep 1; else echo "NOTE: this camera refused /focus; capturing anyway." >&2; fi
    fi
    if [ -n "$ZOOM" ]; then
      target="$(nearest_zoom "$ZOOM_UNITS")"
      if [ -z "$target" ]; then
        echo "NOTE: this camera reports no zoom control; capturing at current settings." >&2
      else
        ZOOM_ORIG="$(zoom_now)"; [ -n "$ZOOM_ORIG" ] || ZOOM_ORIG=100
        if set_zoom "$target"; then
          echo "zoom ${ZOOM}x -> $target (was $ZOOM_ORIG); will restore after capture" >&2
        else
          echo "NOTE: this camera refused the zoom; capturing at current settings." >&2
          ZOOM_ORIG=""
        fi
      fi
    fi
  fi
fi

i=1
while [ "$i" -le "$COUNT" ]; do
  prefix="$OUT_DIR/frame-$(date +%H%M%S)-$$-$i"
  if out="$(grab_one "$prefix")"; then
    printf '%s\n' "$out"
  else
    exit 1                         # grab_one already explained the failure on stderr
  fi
  [ "$i" -lt "$COUNT" ] && sleep "$INTERVAL"
  i=$((i + 1))
done
exit 0
