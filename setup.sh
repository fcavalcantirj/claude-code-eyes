#!/bin/bash
# claude-code-eyes setup -- one command from install to working.
#
# Usage:
#   setup.sh                     interactive: asks for the camera URL (blank = scan the LAN)
#   setup.sh --url URL           non-interactive; --type/--auth/--local optional
#   setup.sh --scan              just scan the LAN for an IP Webcam and print matches
#   setup.sh --show              show where the config is / would be written
#
# Options:
#   --type ipwebcam|camera-streamer|url   (default: ipwebcam)
#   --url  URL                            camera URL (interpreted per --type)
#   --auth user:pass                      optional HTTP basic auth
#   --local                               write ./.cce.env instead of the global config
#
# Writes the same config snap.sh reads; contains no secrets beyond what you provide.
set -euo pipefail

# Absolute path to the snap.sh sitting beside this script -- excludedCommands is
# matched exact/prefix, so the advice must name the real invocation, not "snap.sh".
SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || true)"
SNAP_PATH="${SELF_DIR:-.}/snap.sh"

TYPE=""; URL=""; AUTH=""; TARGET="global"; ACTION="setup"
while [ $# -gt 0 ]; do
  case "$1" in
    --type)  TYPE="${2:-}"; shift 2 ;;
    --url)   URL="${2:-}"; shift 2 ;;
    --auth)  AUTH="${2:-}"; shift 2 ;;
    --local) TARGET="local"; shift ;;
    --global) TARGET="global"; shift ;;
    --scan)  ACTION="scan"; shift ;;
    --show)  ACTION="show"; shift ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

XDG="${XDG_CONFIG_HOME:-$HOME/.config}"
GLOBAL_CFG="$XDG/claude-code-eyes/config"
LOCAL_CFG="./.cce.env"

# --- CRLF guard --------------------------------------------------------------
# A Windows-saved or autocrlf-converted snap.sh dies before running anything:
#   snap.sh: line N: $'\r': command not found
#   snap.sh: line N: set: pipefail: invalid option name
# snap.sh cannot report this itself (bash is already dead), so check it here.
crlf_check() {
  local snap="${SELF_DIR:-.}/snap.sh" crs
  [ -f "$snap" ] || return 0
  crs="$(tr -cd '\r' < "$snap" | wc -c | tr -d ' ')"
  [ "$crs" = "0" ] && return 0
  echo "WARNING: $snap has CRLF (Windows) line endings -- $crs carriage returns." >&2
  echo "  bash will fail on it with \"set: pipefail: invalid option name\" before it" >&2
  echo "  ever reaches your camera. Fix it with either of:" >&2
  echo "      perl -pi -e 's/\\r\$//' \"$snap\"" >&2
  echo "      sed -i'' -e 's/\\r\$//' \"$snap\"" >&2
  echo "  Then re-clone with .gitattributes present, or set: git config core.autocrlf input" >&2
  return 1
}

# --- probe one URL: 0 if it returns a JPEG/PNG -------------------------------
is_image_url() {                   # $1=url  $2=auth(optional)  $3=connect-timeout
  local u="$1" a="${2:-}" ct="${3:-2}" tmp sig args
  tmp="$(mktemp)"
  args=(-sf --connect-timeout "$ct" --max-time 8)
  [ -n "$a" ] && args=("${args[@]}" -u "$a")
  if curl "${args[@]}" "$u" -o "$tmp" 2>/dev/null; then
    sig="$(od -An -tx1 -N4 "$tmp" 2>/dev/null | tr -d ' \n')"
    rm -f "$tmp"
    case "$sig" in ffd8ff*|89504e47) return 0 ;; esac
  fi
  rm -f "$tmp"; return 1
}

# --- endpoint for a (type,url) pair, mirroring snap.sh -----------------------
endpoint_for() {                   # $1=type $2=url
  local base="${2%/}"
  case "$1" in
    ipwebcam)        printf '%s\n' "$base/shot.jpg" ;;
    camera-streamer) printf '%s\n' "$base/snapshot" ;;
    *)               printf '%s\n' "$2" ;;
  esac
}

# --- host:port of a URL, mirroring snap.sh -----------------------------------
host_port() {                      # "http://u:p@1.2.3.4:8080/shot.jpg" -> "1.2.3.4:8080"
  local u="${1#*://}"
  u="${u##*@}"
  printf '%s\n' "${u%%/*}"
}

# --- Claude Code Bash sandbox ---------------------------------------------------
# Verified against Claude Code 2.1.236: the sandbox blocks private/LAN addresses
# below its proxy, and sandbox.network.allowedDomains cannot admit them ("Public
# domain names are required"). A LAN camera therefore needs the capture command
# excluded from the sandbox; only a public host is fixed by the allowlist.
is_private_host() {                # $1=host[:port]
  local h="${1%%:*}"
  case "$h" in
    localhost|*.local|*.internal|*.localdomain) return 0 ;;
    10.*|127.*|169.254.*|192.168.*)             return 0 ;;
    172.1[6-9].*|172.2[0-9].*|172.3[01].*)      return 0 ;;
  esac
  return 1
}

sandbox_hint() {                   # $1=endpoint
  local hp; hp="$(host_port "$1")"
  echo
  echo "Claude Code runs Bash in a sandbox. If Claude cannot reach the camera but your"
  echo "own terminal can, that is why. Add to ~/.claude/settings.json, then restart:"
  echo
  if is_private_host "$hp"; then
    echo "    { \"sandbox\": { \"excludedCommands\": [\"bash $SNAP_PATH\"] } }"
    echo
    echo "$hp is a private/LAN address; the network allowlist cannot admit those"
    echo "(it requires public domain names), so the capture must run outside the sandbox."
    echo "The path must match how it is invoked -- matching is exact/prefix, not fuzzy."
    echo "You can also just approve Claude's offer to retry the command outside the"
    echo "sandbox; that works with no config change."
  else
    echo "    { \"sandbox\": { \"network\": { \"allowedDomains\": [\"$hp\"] } } }"
    echo
    echo "IPs must be listed EXACTLY -- wildcards never match an IP."
  fi
  echo "Inspect the active policy with /sandbox. https://code.claude.com/docs/en/sandboxing"
}

# --- local /24 prefix (best effort) ------------------------------------------
lan_prefix() {                     # echoes e.g. 192.168.0
  local ip=""
  case "$(uname -s)" in
    Darwin) ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)" ;;
    *)      ip="$(hostname -I 2>/dev/null | awk '{print $1}')" ;;
  esac
  [ -n "$ip" ] || return 1
  printf '%s\n' "${ip%.*}"
}

# --- scan the /24 on :8080 for an IP Webcam /shot.jpg ------------------------
scan_lan() {                       # prints found base URLs, one per line
  local prefix n
  prefix="$(lan_prefix)" || { echo "could not determine your LAN subnet" >&2; return 1; }
  echo "scanning ${prefix}.1-254 on port 8080 for an IP Webcam ..." >&2
  local out; out="$(mktemp)"
  n=1
  while [ "$n" -le 254 ]; do
    ( is_image_url "http://${prefix}.${n}:8080/shot.jpg" "" 1 && printf '%s\n' "http://${prefix}.${n}:8080" >> "$out" ) &
    [ $(( n % 48 )) -eq 0 ] && wait
    n=$(( n + 1 ))
  done
  wait
  sort -u "$out"; rm -f "$out"
}

write_config() {                   # $1=type $2=url $3=auth $4=target
  local t="$1" u="$2" a="$3" tgt="$4" file
  if [ "$tgt" = "local" ]; then file="$LOCAL_CFG"; else file="$GLOBAL_CFG"; mkdir -p "$(dirname "$file")"; fi
  {
    echo "CCE_CAM_TYPE=$t"
    echo "CCE_CAM_URL=$u"
    [ -n "$a" ] && echo "CCE_CAM_AUTH=$a"
  } > "$file"
  chmod 600 "$file"
  printf '%s\n' "$file"
}

# --- actions -----------------------------------------------------------------
crlf_check || true                 # warn loudly, but never block the user
if [ "$ACTION" = "show" ]; then
  echo "global config: $GLOBAL_CFG $( [ -f "$GLOBAL_CFG" ] && echo '(exists)' || echo '(not set)')"
  echo "local  config: $LOCAL_CFG $( [ -f "$LOCAL_CFG" ] && echo '(exists)' || echo '(not set)')"
  exit 0
fi

if [ "$ACTION" = "scan" ]; then
  matches="$(scan_lan || true)"
  if [ -n "$matches" ]; then
    echo "found IP Webcam(s):"; printf '%s\n' "$matches"
  else
    echo "no IP Webcam found on the LAN (is the app's server running?)."
  fi
  exit 0
fi

# setup (interactive if --url not given)
if [ -z "$URL" ]; then
  printf 'Camera URL (e.g. http://192.168.0.42:8080), or blank to scan the LAN: ' >&2
  IFS= read -r URL || true
  if [ -z "$URL" ]; then
    matches="$(scan_lan || true)"
    if [ -n "$matches" ]; then
      echo "found:" >&2; printf '%s\n' "$matches" | nl -w2 -s') ' >&2
      printf 'pick a number (or paste a URL): ' >&2; IFS= read -r pick || true
      case "$pick" in
        ''|*[!0-9]*) URL="$pick" ;;
        *) URL="$(printf '%s\n' "$matches" | sed -n "${pick}p")" ;;
      esac
    fi
    [ -n "$URL" ] || { echo "no camera URL provided; nothing written." >&2; exit 1; }
  fi
  if [ -z "$TYPE" ]; then
    printf 'Type [ipwebcam]/camera-streamer/url: ' >&2; IFS= read -r TYPE || true
  fi
  if [ -z "$AUTH" ]; then
    printf 'Basic auth user:pass (blank for none): ' >&2; IFS= read -r AUTH || true
  fi
fi

TYPE="${TYPE:-ipwebcam}"
case "$TYPE" in ipwebcam|camera-streamer|url) ;; *) echo "invalid --type '$TYPE'" >&2; exit 2 ;; esac

file="$(write_config "$TYPE" "$URL" "$AUTH" "$TARGET")"
echo "wrote $file (mode 600): CCE_CAM_TYPE=$TYPE, CCE_CAM_URL=$URL, auth=$([ -n "$AUTH" ] && echo set || echo none)"

ep="$(endpoint_for "$TYPE" "$URL")"
printf 'verifying %s ... ' "$ep"
if is_image_url "$ep" "$AUTH" 3; then
  echo "OK -- got a live frame. You're set: ask Claude \"are you seeing this?\""
  # report zoom/focus support, so the user knows whether --zoom is available
  if [ "$TYPE" = "ipwebcam" ]; then
    steps="$(curl -sf -m 6 ${AUTH:+-u "$AUTH"} "${URL%/}/status.json?show_avail=1" 2>/dev/null \
             | grep -o '"zoom":\[[^]]*\]' | grep -o '[0-9][0-9]*' | wc -l | tr -d ' ')"
    if [ -n "$steps" ] && [ "$steps" -gt 1 ]; then
      echo "  zoom + focus available ($steps zoom steps): try  snap.sh --zoom 4  /  snap.sh --focus"
    else
      echo "  this camera reports no zoom steps; --zoom will capture at current settings"
    fi
  fi
else
  echo "no frame right now."
  echo "  The config is saved and correct; the camera just isn't reachable this moment"
  echo "  (start the phone's IP Webcam server / check the IP). It'll work once it's up."
fi
sandbox_hint "$ep"
