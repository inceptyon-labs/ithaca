#!/bin/bash
set -e

# Ithaca deployment: bump the version, write the notes, archive and upload the iOS and tvOS apps (one App Store record,
# bundle ID com.inceptyon.ithaca) with the same build number, then TestFlight or App Store review.
# Usage: ./scripts/deploy.sh [prod|beta] [-y]
#   prod  App Store (default): TestFlight as below, then both platforms submitted for review, released automatically on
#         approval, and the release tagged v<version>. Asks before it starts unless -y. Also: production, release.
#         The first version (1.0) only gets its build attached; submit it from the version page with the in-app
#         purchases.
#   beta  TestFlight only: upload, set "What to Test", the internal group gets it. Also: testflight.
#   --preflight  run the release checks below and exit; archives and uploads nothing.
#
# Preflight (refuses to continue): a clean git tree; the App Store Connect key; the App Store Connect app record;
# and VLCKit in Frameworks/ being Ithaca's own TrueHD build, not VideoLAN's stock one (see docs/development-workflow.md).
# A menu bumps the build number (always) and MARKETING_VERSION (patch, minor or major) in project.yml; both apps share them.
# Signing is automatic (-allowProvisioningUpdates) with the API key flags in .asc.local; scripts/ExportOptions.plist
# uploads straight to App Store Connect. Every upload is tagged build/<n>, which starts the next build's "What to Test";
# scripts/whats_new.sh (git-cliff, then claude) also writes the App Store's What's New and this version's CHANGELOG.md
# section, from the last v<version> tag. scripts/asc.mjs does the App Store Connect steps.
# Env: ITHACA_SKIP_WHATS_NEW=1 keeps the existing notes; WHATS_NEW_MODEL picks claude's model (default sonnet).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

PROJECT_YML="project.yml"
NOTES="docs/app-store/what-to-test.txt"
WHATS_NEW="docs/app-store/whats-new.txt"
STOCK_CACHE="$ROOT/.build/release/vlckit-stock"

# ─── VLCKit: the TrueHD build ────────────────────────────────────────
# Releases ship Ithaca's own VLCKit (build_vlckit.sh: ffmpeg's TrueHD/MLP decoders on; docs/playback.md → "Dolby
# TrueHD decoding"). Each framework's install marker must name the version install_vlckit.sh pins (VLCKIT_VERSION),
# and each device binary's Mach-O UUID must differ from the one in VideoLAN's pinned stock archive, so a stale marker
# can't pass for it. The stock UUIDs are cached in .build/release after one verified download; later runs are offline.
install_pin() { sed -n "s/^$1=\"\(.*\)\"/\1/p" ci_scripts/install_vlckit.sh | head -1; }
binary_uuid() { xcrun dwarfdump --uuid "$1" 2>/dev/null | awk '/\(arm64\)/ {print $2}' | head -1; }

# stock_uuid <ios|tvos>: prints the arm64 UUID of the stock archive's binary, downloading and verifying it if not cached.
stock_uuid() {
    local plat="$1" name archive sha base cache dir slice
    if [ "$plat" = ios ]; then
        name=MobileVLCKit; archive=$(install_pin STOCK_IOS_ARCHIVE); sha=$(install_pin STOCK_IOS_ARCHIVE_SHA256); slice=ios-arm64_armv7_armv7s
    else
        name=TVVLCKit; archive=$(install_pin STOCK_TVOS_ARCHIVE); sha=$(install_pin STOCK_TVOS_ARCHIVE_SHA256); slice=tvos-arm64
    fi
    base=$(install_pin STOCK_DOWNLOAD_BASE_URL)
    [ -n "$archive" ] && [ -n "$sha" ] && [ -n "$base" ] || { echo "cannot read the stock VLCKit pins from ci_scripts/install_vlckit.sh" >&2; return 1; }
    cache="$STOCK_CACHE/$name-$sha.uuid"
    if [ ! -s "$cache" ]; then
        dir=$(mktemp -d)
        mkdir -p "$STOCK_CACHE"
        echo "    downloading VideoLAN's stock $name to read its UUID (once)..." >&2
        curl --fail --silent --show-error --location --retry 8 --retry-all-errors --retry-delay 3 -o "$dir/$archive" "$base/$archive" \
            || { rm -rf "$dir"; echo "download of $archive failed" >&2; return 1; }
        if [ "$(shasum -a 256 "$dir/$archive" | awk '{print $1}')" != "$sha" ]; then
            rm -rf "$dir"; echo "checksum mismatch for $archive" >&2; return 1
        fi
        tar -xf "$dir/$archive" -C "$dir" "$name-binary/$name.xcframework/$slice/$name.framework/$name" \
            || { rm -rf "$dir"; echo "cannot extract $name from $archive" >&2; return 1; }
        binary_uuid "$dir/$name-binary/$name.xcframework/$slice/$name.framework/$name" >"$cache"
        rm -rf "$dir"
    fi
    cat "$cache"
}

# check_truehd_vlckit: 0 when both installed frameworks are Ithaca's TrueHD build, 1 with the reason printed.
check_truehd_vlckit() {
    local ok=0 plat name slice stock installed marker wanted
    wanted=$(install_pin VLCKIT_VERSION)
    for plat in ios tvos; do
        if [ "$plat" = ios ]; then name=MobileVLCKit; slice=ios-arm64; else name=TVVLCKit; slice=tvos-arm64; fi
        installed=$(binary_uuid "Frameworks/$name.xcframework/$slice/$name.framework/$name")
        if [ -z "$installed" ]; then
            echo "    $name: no binary at Frameworks/$name.xcframework/$slice"; ok=1; continue
        fi
        marker=$(cat "Frameworks/$name.xcframework/vlckit-installed.txt" 2>/dev/null)
        stock=$(stock_uuid "$plat") || { echo "    $name: could not read the stock UUID"; ok=1; continue; }
        if [ "$installed" = "$stock" ]; then
            echo "    $name: VideoLAN's stock build (UUID $installed), which has no TrueHD decoder"; ok=1
        elif [ "$marker" != "$wanted" ]; then
            echo "    $name: installed as '${marker:-unknown}', not $wanted"; ok=1
        else
            echo "    $name: $wanted with TrueHD (UUID $installed)"
        fi
    done
    if [ $ok -ne 0 ]; then
        echo "    Install the TrueHD build: rm -rf Frameworks/MobileVLCKit.xcframework Frameworks/TVVLCKit.xcframework && ITHACA_VLCKIT_CACHE_DIR=.build/vlckit/out ci_scripts/install_vlckit.sh && git checkout Frameworks/VLCKit-VERSION.txt"
    fi
    return $ok
}

# release_preflight: runs every check, prints each failure, returns non-zero if any failed.
release_preflight() {
    local fail=0 tool KEY_PATH
    for tool in xcodegen xcodebuild node git; do
        command -v $tool >/dev/null 2>&1 || { echo -e "${RED}✗ $tool not found${NC}"; fail=1; }
    done
    if [ ! -f .asc.local ]; then
        echo -e "${RED}✗ .asc.local not found (the App Store Connect key flags)${NC}"; fail=1
    else
        KEY_PATH=$(sed -n 's/.*-authenticationKeyPath \([^ ]*\).*/\1/p' .asc.local); KEY_PATH="${KEY_PATH/#\~/$HOME}"
        [ -f "$KEY_PATH" ] || { echo -e "${RED}✗ API key not found at $KEY_PATH${NC}"; fail=1; }
    fi
    if [ -n "$(git status --porcelain)" ]; then
        echo -e "${RED}✗ The git tree is dirty; commit or stash first:${NC}"; git status --short | sed 's/^/    /'; fail=1
    else
        echo -e "${GREEN}✓ git tree clean${NC}"
    fi
    echo -e "${BLUE}VLCKit in Frameworks/ must be Ithaca's TrueHD build...${NC}"
    if check_truehd_vlckit; then echo -e "${GREEN}✓ VLCKit has TrueHD${NC}"; else echo -e "${RED}✗ VLCKit is not Ithaca's TrueHD build${NC}"; fail=1; fi
    command -v node >/dev/null 2>&1 && { node scripts/asc.mjs check || fail=1; }
    return $fail
}

# Sourced for the functions only (e.g. to run check_truehd_vlckit on its own).
[ "${ITHACA_DEPLOY_SOURCE_ONLY:-0}" = "1" ] && return 0 2>/dev/null

LANE="release"; ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --preflight) release_preflight && echo -e "${GREEN}✓ Preflight passed${NC}"; exit $? ;;
        beta|testflight) LANE="beta" ;;
        prod|production|release) LANE="release" ;;
        -y|--yes) ASSUME_YES=1 ;;
        *) echo -e "${RED}Usage: $0 [prod|beta] [-y] | --preflight${NC}"; exit 1 ;;
    esac
done
LANE_LABEL="TestFlight"
[ "$LANE" = "release" ] && LANE_LABEL="App Store (production)"

echo ""
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}      ITHACA DEPLOYMENT → ${LANE_LABEL} (iOS + tvOS)${NC}"
echo -e "${CYAN}════════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BLUE}Pre-flight checks...${NC}"
release_preflight || { echo -e "${RED}Preflight failed; nothing was archived${NC}"; exit 1; }
echo -e "${GREEN}✓ Pre-flight checks passed${NC}"
echo ""

# ─── Version ─────────────────────────────────────────────────────────
CURRENT_VERSION=$(grep -m1 'MARKETING_VERSION:' "$PROJECT_YML" | sed 's/.*: *"//;s/".*//')
CURRENT_BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION:' "$PROJECT_YML" | sed 's/.*: *"//;s/".*//')
MAJOR=$(echo "$CURRENT_VERSION" | cut -d. -f1); MINOR=$(echo "$CURRENT_VERSION" | cut -d. -f2); PATCH=$(echo "$CURRENT_VERSION" | cut -d. -f3)
[ -z "$MINOR" ] && MINOR=0
[ -z "$PATCH" ] && PATCH=0
echo -e "Current version: ${YELLOW}${CURRENT_VERSION} (build ${CURRENT_BUILD})${NC}"
echo ""
echo -e "${BLUE}Bump version?${NC}"
echo "  1) Build number only   -> ${CURRENT_VERSION} (build $(( CURRENT_BUILD + 1 )))"
echo "  2) Patch (bug fix)     -> ${MAJOR}.${MINOR}.$(( PATCH + 1 )) (build $(( CURRENT_BUILD + 1 )))"
echo "  3) Minor (new feature) -> ${MAJOR}.$(( MINOR + 1 )).0 (build $(( CURRENT_BUILD + 1 )))"
echo "  4) Major               -> $(( MAJOR + 1 )).0.0 (build $(( CURRENT_BUILD + 1 )))"
echo ""
# From /dev/tty: without a terminal (or with -y) it's option 1.
bump_choice=""
[ "$ASSUME_YES" = "0" ] && { read -r -p "Enter choice [1-4] (default: 1): " bump_choice </dev/tty || bump_choice=""; }
VERSION="$CURRENT_VERSION"; NEW_BUILD=$(( CURRENT_BUILD + 1 ))
case "$bump_choice" in
    2) VERSION="${MAJOR}.${MINOR}.$(( PATCH + 1 ))" ;;
    3) VERSION="${MAJOR}.$(( MINOR + 1 )).0" ;;
    4) VERSION="$(( MAJOR + 1 )).0.0" ;;
esac
echo -e "Updating to: ${GREEN}${VERSION} (build ${NEW_BUILD})${NC} (iOS and tvOS)"

# The tree was clean, so a failure before the first upload puts the bump and notes back; after an upload the build
# number is spent and stays.
SPENT=0
revert_on_failure() {
    local status=$?
    if [ $status -ne 0 ] && [ $SPENT -eq 0 ]; then
        git checkout -- "$PROJECT_YML" Ithaca.xcodeproj CHANGELOG.md 2>/dev/null || true
        for f in "$NOTES" "$WHATS_NEW"; do
            if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then git checkout -- "$f" 2>/dev/null || true; else rm -f "$f"; fi
        done
        echo -e "${YELLOW}Reverted the build number bump${NC}"
    fi
}
trap revert_on_failure EXIT
sed -i '' "s/MARKETING_VERSION: .*/MARKETING_VERSION: \"${VERSION}\"/" "$PROJECT_YML"
sed -i '' "s/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: \"${NEW_BUILD}\"/" "$PROJECT_YML"
echo ""

# ─── Notes ───────────────────────────────────────────────────────────
echo -e "${BLUE}[1/5] Writing What to Test, What's New and the changelog...${NC}"
if [ "${ITHACA_SKIP_WHATS_NEW:-0}" = "1" ]; then
    echo -e "${YELLOW}Keeping the existing notes (ITHACA_SKIP_WHATS_NEW=1)${NC}"
else
    scripts/whats_new.sh "$VERSION" "$NEW_BUILD" || echo -e "${YELLOW}⚠ Notes failed; continuing with the existing ones${NC}"
fi
[ -f "$NOTES" ] || echo "- Fixes behind the scenes; nothing new to try." >"$NOTES"
[ -f "$WHATS_NEW" ] || echo "- Fixes and improvements." >"$WHATS_NEW"
echo -e "${GREEN}What to Test:${NC}"; sed 's/^/    /' "$NOTES"
if [ "$LANE" = "release" ]; then echo -e "${GREEN}What's New:${NC}"; sed 's/^/    /' "$WHATS_NEW"; fi
echo ""

# ─── Project ─────────────────────────────────────────────────────────
echo -e "${BLUE}[2/5] Regenerating the Xcode project...${NC}"
xcodegen generate --quiet
# xcodegen rewrites the shared schemes differently from the checked-in ones; keep the checked-in ones.
git checkout Ithaca.xcodeproj/xcshareddata
echo -e "${GREEN}✓ Project regenerated${NC}"
echo ""

# Production submits for review and releases on approval, so confirm first. Read from /dev/tty: claude can drain the
# inherited stdin, and a read that hits EOF would end the script under set -e before the check.
if [ "$LANE" = "release" ] && [ "$ASSUME_YES" = "0" ]; then
    echo -e "${YELLOW}This uploads ${VERSION} (build ${NEW_BUILD}) for iOS and tvOS and submits both to App Review, released on approval.${NC}"
    confirm=""
    read -r -p "Continue? (y/N): " confirm </dev/tty || confirm=""
    [[ "$confirm" =~ ^[Yy]$ ]] || { echo -e "${RED}Aborted${NC}"; exit 1; }
    echo ""
fi

# ─── Archive ─────────────────────────────────────────────────────────
LOG="build/deploy.log"; mkdir -p build; : >"$LOG"
FLAGS=$(grep -v '^#' .asc.local | sed "s#~#$HOME#g")
rm -rf build/Ithaca-iOS.xcarchive build/Ithaca-tvOS.xcarchive build/export-ios build/export-tvos
echo -e "${BLUE}[3/5] Archiving iOS and tvOS (log: ${LOG})...${NC}"
for pair in "Ithaca:iOS:ios" "Ithaca-tvOS:tvOS:tvos"; do
    IFS=: read -r scheme platform tag <<<"$pair"
    echo "    $scheme"
    # shellcheck disable=SC2086 # .asc.local is a line of flags
    xcodebuild -project Ithaca.xcodeproj -scheme "$scheme" -configuration Release -destination "generic/platform=$platform" \
        -archivePath "build/Ithaca-$platform.xcarchive" -allowProvisioningUpdates $FLAGS archive >>"$LOG" 2>&1 \
        || { grep -E "error:" "$LOG" | head -20; echo -e "${RED}$scheme archive failed; see $LOG${NC}"; exit 1; }
done
echo -e "${GREEN}✓ Archived both${NC}"
echo ""

# ─── Upload ──────────────────────────────────────────────────────────
echo -e "${BLUE}[4/5] Uploading to App Store Connect...${NC}"
SPENT=1
for platform in iOS tvOS; do
    # shellcheck disable=SC2086
    xcodebuild -exportArchive -archivePath "build/Ithaca-$platform.xcarchive" -exportOptionsPlist scripts/ExportOptions.plist \
        -exportPath "build/export-$platform" -allowProvisioningUpdates $FLAGS >>"$LOG" 2>&1 \
        || { grep -E "error" "$LOG" | tail -20; echo -e "${RED}$platform upload failed; see $LOG. Build ${NEW_BUILD} may have uploaded for the other platform, so the build number stays bumped.${NC}"; exit 1; }
    echo -e "${GREEN}✓ Uploaded $platform build ${NEW_BUILD}${NC}"
done
echo ""

# ─── Commit and tag ──────────────────────────────────────────────────
# What shipped: the build number and the notes. Only these paths, so other work stays unstaged.
echo -e "${BLUE}Committing the release files...${NC}"
git add "$PROJECT_YML" Ithaca.xcodeproj/project.pbxproj "$NOTES" "$WHATS_NEW" CHANGELOG.md
if git diff --cached --quiet; then
    echo -e "${YELLOW}Nothing new to commit${NC}"
elif [ "$LANE" = "release" ]; then
    git commit -q -m "chore: release v${VERSION} (build ${NEW_BUILD})"
else
    git commit -q -m "chore: TestFlight ${VERSION} (build ${NEW_BUILD})"
fi
git tag -f "build/${NEW_BUILD}" >/dev/null
[ "$LANE" = "release" ] && ! git rev-parse -q --verify "refs/tags/v${VERSION}" >/dev/null \
    && git tag -a "v${VERSION}" -m "Release ${VERSION} (build ${NEW_BUILD})"
git push -q && git push -q --tags 2>/dev/null && echo -e "${GREEN}✓ Committed, tagged build/${NEW_BUILD} and pushed${NC}" \
    || echo -e "${YELLOW}⚠ Push failed; run git push && git push --tags${NC}"
echo ""

# ─── App Store Connect ───────────────────────────────────────────────
echo -e "${BLUE}[5/5] TestFlight${NC}"
node scripts/asc.mjs testflight "$NEW_BUILD" "$NOTES"
if [ "$LANE" = "release" ]; then
    echo -e "${BLUE}App Store review${NC}"
    # 3: the first version, left for the version page.
    set +e; node scripts/asc.mjs release "$VERSION" "$NEW_BUILD" "$WHATS_NEW"; status=$?; set -e
    [ $status -eq 0 ] || [ $status -eq 3 ] || exit $status
fi

echo ""
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}            ITHACA DEPLOYMENT COMPLETE${NC}"
echo -e "${GREEN}════════════════════════════════════════════════════════════${NC}"
echo -e "Version: ${CYAN}${VERSION} (build ${NEW_BUILD})${NC} → ${CYAN}${LANE_LABEL}${NC}"
echo ""
