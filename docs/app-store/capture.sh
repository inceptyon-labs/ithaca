#!/bin/zsh
# Captures one screen of the Debug app in a booted simulator, signed in to the App Review demo account, for
# compose.py. Build the Debug app for the simulator and install it first, then for example:
#   capture.sh <sim udid> raw/phone-home.png 12 -IthacaScreenshotScreen home
# Env: ITHACA_DEMO_TOKEN, the demo account's Plex token (required). ITHACA_DEMO_SEERR and
# ITHACA_DEMO_SEERR_SESSION, the Seerr address and the demo account's connect.sid, for screens that show Seerr.
# Screen arguments are listed in docs/screenshots.md.
SIM=$1; OUT=$2; WAIT=$3; shift 3
APP=com.inceptyon.ithaca
: ${ITHACA_DEMO_TOKEN:?set ITHACA_DEMO_TOKEN to the demo account token}
xcrun simctl status_bar $SIM override --time 9:41 --batteryState discharging --batteryLevel 100 --cellularBars 4 --wifiBars 3 \
  --operatorName "" >/dev/null 2>&1 # tvOS has no status bar
xcrun simctl terminate $SIM $APP >/dev/null 2>&1
args=(-IthacaScreenshotMode YES -IthacaScreenshotToken $ITHACA_DEMO_TOKEN)
[[ -n $ITHACA_DEMO_SEERR ]] && args+=(-IthacaScreenshotSeerr $ITHACA_DEMO_SEERR -IthacaScreenshotSeerrSession $ITHACA_DEMO_SEERR_SESSION)
xcrun simctl launch $SIM $APP $args "$@" >/dev/null
sleep $WAIT
xcrun simctl io $SIM screenshot $OUT >/dev/null 2>&1
echo $OUT
