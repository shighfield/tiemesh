#!/usr/bin/env bash
#
# build-on-pi.sh — copy the tiemesh sources to a Raspberry Pi and build them
# there with Free Pascal. This is the "compile from my desk, run on the Pi"
# workflow that avoids all cross-toolchain hassle (the Pi builds this in seconds).
#
# Usage:
#   ./build-on-pi.sh                 # copy + build
#   ./build-on-pi.sh --ble           # build with the Linux BLE transport (-dMESH_BLE)
#   ./build-on-pi.sh --run           # build, then launch it over SSH on the Pi
#   ./build-on-pi.sh --run --serial /dev/ttyUSB0
#
# Configure the Pi here, or override any of them from the environment, e.g.:
#   PI_HOST=raspberrypi.local PI_USER=pi ./build-on-pi.sh
#
set -euo pipefail

# ----- configuration (edit or override via environment) -----
PI_HOST="${PI_HOST:-dietpi}"              # hostname or IP of the Pi
PI_USER="${PI_USER:-dietpi}"              # login user on the Pi
PI_DIR="${PI_DIR:-~/tiemesh}"             # where sources live / build runs on the Pi
SERIAL="${SERIAL:-/dev/ttyACM0}"          # radio serial device on the Pi (for --run)

MAIN="tiemesh.pas"
REQUIRED_UNITS=(meshproto.pas meshtransport.pas meshclient.pas)
OPTIONAL_UNITS=(meshble.pas)              # only needed for --ble; copied if present
EXTRA_FILES=(README.md)                   # non-source files to copy too, if present

# ----- parse options -----
WITH_BLE=0
RUN_AFTER=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ble)    WITH_BLE=1 ;;
    --run)    RUN_AFTER=1 ;;
    --serial) shift; SERIAL="${1:?--serial needs a device path}" ;;
    --host)   shift; PI_HOST="${1:?--host needs a value}" ;;
    --user)   shift; PI_USER="${1:?--user needs a value}" ;;
    -h|--help)
      sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

TARGET="${PI_USER}@${PI_HOST}"

echo ">> target: ${TARGET}:${PI_DIR}"

# ----- sanity: are we in the source directory? -----
missing=0
for f in "$MAIN" "${REQUIRED_UNITS[@]}"; do
  if [[ ! -f "$f" ]]; then echo "!! missing source file: $f" >&2; missing=1; fi
done
[[ $missing -eq 0 ]] || { echo "Run this from the directory that holds the .pas files." >&2; exit 1; }

# gather the files to copy (required + any optional/extra ones that exist)
FILES=("$MAIN" "${REQUIRED_UNITS[@]}")
for f in "${OPTIONAL_UNITS[@]}" "${EXTRA_FILES[@]}"; do
  [[ -f "$f" ]] && FILES+=("$f")
done

if [[ $WITH_BLE -eq 1 && ! -f "meshble.pas" ]]; then
  echo "!! --ble requested but meshble.pas is not here." >&2; exit 1
fi

# ----- make sure fpc exists on the Pi -----
echo ">> checking Free Pascal on the Pi..."
if ! ssh "$TARGET" 'command -v fpc >/dev/null 2>&1'; then
  echo "!! fpc is not installed on the Pi." >&2
  echo "   Install it with:  ssh $TARGET 'sudo apt install fpc'" >&2
  exit 1
fi

# ----- copy sources -----
echo ">> creating ${PI_DIR} and copying $(echo "${FILES[@]}" | wc -w) file(s)..."
ssh "$TARGET" "mkdir -p $PI_DIR"
scp "${FILES[@]}" "$TARGET:$PI_DIR/"

# ----- build -----
DEFS=""
[[ $WITH_BLE -eq 1 ]] && DEFS="-dMESH_BLE"
echo ">> building on the Pi (fpc $DEFS $MAIN)..."
ssh "$TARGET" "cd $PI_DIR && fpc $DEFS $MAIN"

echo ">> done. Binary is at ${PI_DIR}/tiemesh on ${PI_HOST}."

# ----- optionally run (interactive, needs a TTY) -----
if [[ $RUN_AFTER -eq 1 ]]; then
  echo ">> launching on the Pi (Ctrl-C or /quit to exit)..."
  ssh -t "$TARGET" "cd $PI_DIR && ./tiemesh --serial $SERIAL"
else
  echo "   Run it with:  ssh -t $TARGET 'cd $PI_DIR && ./tiemesh --serial $SERIAL'"
fi
