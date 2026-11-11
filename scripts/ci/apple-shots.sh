#!/bin/bash
# Throwaway (artifacts branches only, never in a PR): screenshots of the Agents list on the mock hub's Paseo computer
# (MOCK_PASEO=1), light and dark, through PersonaUITests/PaseoShotsUITests. The PNGs land in
# $RUNNER_TEMP/persona-shots/shots, which the workflow uploads. Ends with a one-line verdict.
set -euo pipefail
source "$(dirname "$0")/common.sh"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode_26.0.1.app/Contents/Developer}"
xcodebuild -version
OUT="${RUNNER_TEMP:-/tmp}/persona-shots"
SHOTS="$OUT/shots"
mkdir -p "$SHOTS"
SPM="${CI_SPM_CACHE:-$HOME/Library/Caches/persona-ci/spm}"
mkdir -p "$SPM"
SPM=$(cd "$SPM" && pwd)
MOCK=""
SIM=""
finish() {
  local code=$?
  trap - EXIT
  [ -z "$MOCK" ] || kill "$MOCK" 2>/dev/null || true
  [ -z "$SIM" ] || { xcrun simctl shutdown "$SIM" >/dev/null 2>&1 || true; xcrun simctl delete "$SIM" >/dev/null 2>&1 || true; }
  local n
  n=$(find "$SHOTS" -name '*.png' | wc -l | tr -d ' ')
  printf 'apple-shots: %s, %s screenshots in %s\n' "$([ "$code" = 0 ] && printf PASS || printf FAIL)" "$n" "$SHOTS"
  exit "$code"
}
trap finish EXIT

export PERSONA_CONFIG="$OUT/config.json"
python3 -I - "$PERSONA_CONFIG" <<'PY'
import json, sys
with open(sys.argv[1], "w") as output:
    json.dump({"app": {"bundle_id": "org.example.persona.ci", "team_id": ""}}, output)
PY
export PERSONA_META_WEARABLES=NO
ci_run 'Generate public unsigned Apple config' 60 python3 scripts/persona_config.py xcconfig
ci_run 'Generate Apple project' 120 xcodegen generate --spec apple/project.yml --project apple

IOS_RUNTIME=""
for platform in iOS watchOS; do
  runtimes="$OUT/runtimes-$platform.json"
  xcrun simctl list runtimes -j > "$runtimes"
  if ! runtime=$(python3 scripts/ci/apple_runtime.py "$runtimes" --platform "$platform"); then
    ci_run "Download matching $platform 26.0 simulator runtime" 1200 xcodebuild -downloadPlatform "$platform" -architectureVariant universal
    xcrun simctl list runtimes -j > "$runtimes"
    runtime=$(python3 scripts/ci/apple_runtime.py "$runtimes" --platform "$platform")
  fi
  printf 'apple-shots: %s runtime %s\n' "$platform" "$runtime"
  if [ "$platform" = iOS ]; then IOS_RUNTIME="$runtime"; fi
done

XCODE=(xcodebuild -project apple/Persona.xcodeproj -configuration Debug -clonedSourcePackagesDirPath "$SPM/SourcePackages")
ci_run 'Resolve Swift packages (Persona)' 900 "${XCODE[@]}" -scheme Persona -resolvePackageDependencies
TEST_SIGNING=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER=)
COMMON=("${XCODE[@]}" -scheme Persona -derivedDataPath "$OUT/dd" -parallel-testing-enabled NO -disableAutomaticPackageResolution
        "${TEST_SIGNING[@]}")
ci_run 'Build the UI tests' 2700 "${COMMON[@]}" -destination 'generic/platform=iOS Simulator' ARCHS="$(uname -m)" ONLY_ACTIVE_ARCH=YES \
  -only-testing:PersonaUITests/PaseoShotsUITests build-for-testing

SIM=$(scripts/app/sim-boot.sh --profile stock --runtime "$IOS_RUNTIME" --device-type "iPhone 17 Pro" "Persona Shots CI" | tail -1)
printf 'apple-shots: simulator %s\n' "$SIM"

PORT=18791
MOCK_PASEO=1 PORT=$PORT python3 scripts/mock/mock_hub.py > "$OUT/mock.log" 2>&1 &
MOCK=$!
python3 - "$PORT" <<'PY'
import socket, sys, time
deadline = time.time() + 60
while time.time() < deadline:
    try:
        socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1).close()
        print("apple-shots: mock hub up")
        sys.exit(0)
    except OSError:
        time.sleep(1)
sys.exit("apple-shots: mock hub did not come up in 60 s")
PY

failed=0
for mode in light dark; do
  # A finished test run can leave its destination shut down: boot it again (waiting for it) before switching.
  ci_run "Boot the simulator ($mode)" 600 xcrun simctl bootstatus "$SIM" -b
  ci_run "Appearance $mode" 60 xcrun simctl ui "$SIM" appearance "$mode"
  export TEST_RUNNER_PERSONA_SHOTS_HUB="http://127.0.0.1:$PORT" TEST_RUNNER_PERSONA_SHOTS="$SHOTS" TEST_RUNNER_PERSONA_SHOTS_SUFFIX="$mode"
  ci_run "UI screenshots ($mode)" 1200 "${COMMON[@]}" -destination "platform=iOS Simulator,id=$SIM" -destination-timeout 120 \
    -only-testing:PersonaUITests/PaseoShotsUITests -resultBundlePath "$OUT/shots-$mode.xcresult" test-without-building || failed=1
  # The attachments too, should the test runner not have been able to write the files.
  xcrun xcresulttool export attachments --path "$OUT/shots-$mode.xcresult" --output-path "$SHOTS/attachments-$mode" >/dev/null 2>&1 || true
done
ls -la "$SHOTS" "$SHOTS"/attachments-* 2>/dev/null || true
cp "$OUT/mock.log" "$SHOTS/mock.log" 2>/dev/null || true
exit "$failed"
