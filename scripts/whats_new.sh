#!/usr/bin/env bash
# whats_new.sh: release notes for an Ithaca build (iOS and tvOS share them).
#
# git-cliff drafts from the Conventional Commits; `claude -p` rewrites the draft into short bullets. Writes:
#   docs/app-store/what-to-test.txt  TestFlight's "What to Test": commits since the previous build's tag (build/<n>)
#   docs/app-store/whats-new.txt     the App Store's "What's New": commits since the last release tag (v<version>)
#   CHANGELOG.md                     this version's section, from git-cliff as is, replacing an older one for it
# Without claude, or when its answer doesn't parse, the git-cliff draft is used, so a deploy never waits on the AI.
#
# Usage: whats_new.sh <version> <build> [iso-date]
# Env:   WHATS_NEW_MODEL   claude model (default: sonnet)
#        WHATS_NEW_AI=0    use the git-cliff draft as is
#        WHATS_NEW_SINCE   git ref to start the release range from, instead of the last release tag

set -euo pipefail

VERSION="${1:?usage: whats_new.sh <version> <build> [iso-date]}"
BUILD="${2:?usage: whats_new.sh <version> <build> [iso-date]}"
DATE="${3:-$(date +%Y-%m-%d)}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
MODEL="${WHATS_NEW_MODEL:-sonnet}"
TEST_PATH="docs/app-store/what-to-test.txt"
NEW_PATH="docs/app-store/whats-new.txt"

command -v git-cliff >/dev/null 2>&1 || { echo "whats_new: git-cliff not installed (brew install git-cliff); skipping." >&2; exit 0; }

# The release range starts at the last shipped version's tag (not this version's, so a second pass still sees its
# commits); the build range at the previous build's tag, else at the last build tag, else where the release range does.
# Before the first release there is no v tag: the release range is then the last 40 commits (Ithaca's history goes back
# through Dusk), and 1.0's notes say it's the first release.
RELEASE_SINCE="${WHATS_NEW_SINCE:-$(git describe --tags --abbrev=0 --match 'v[0-9]*' --exclude "v$VERSION" 2>/dev/null || true)}"
FIRST_RELEASE=0
if [ -z "$RELEASE_SINCE" ]; then FIRST_RELEASE=1; RELEASE_SINCE="$(git rev-list --max-count=40 HEAD | tail -1)"; fi
BUILD_SINCE="$(git rev-parse -q --verify "refs/tags/build/$((BUILD - 1))" >/dev/null && echo "build/$((BUILD - 1))" \
  || git describe --tags --abbrev=0 --match 'build/*' 2>/dev/null || echo "$RELEASE_SINCE")"

range() { [ -n "$1" ] && echo "$1..HEAD" || echo "HEAD"; }
draft() { git cliff "$(range "$1")" --tag "v$VERSION" 2>/dev/null || true; }
commits() { git log --pretty='- %s%n%b' "$(range "$1")" 2>/dev/null || true; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# polish <out.json> <draft> <commits> <instructions>: a JSON array of bullets, or [] to fall back to the draft.
polish() {
  printf '[]' >"$1"
  if [ "${WHATS_NEW_AI:-1}" = "0" ]; then echo "whats_new: AI off (WHATS_NEW_AI=0); using the git-cliff draft."; return; fi
  if ! command -v claude >/dev/null 2>&1; then echo "whats_new: claude not on PATH; using the git-cliff draft."; return; fi
  if [ -z "${2//[[:space:]]/}" ]; then echo "whats_new: no commits in range; using the fallback line."; return; fi
  printf '%s\n\n=== git-cliff draft ===\n%s\n\n=== raw commits ===\n%s' "$4" "$2" "$3" \
    | claude -p --model "$MODEL" 2>/dev/null | sed '/^```/d' >"$1.raw" || true
  if python3 -c "import json,sys; assert isinstance(json.load(open(sys.argv[1])), list)" "$1.raw" 2>/dev/null; then
    mv "$1.raw" "$1"
  else
    echo "whats_new: claude's answer didn't parse; using the git-cliff draft."
  fi
}

ABOUT="Ithaca is a native Apple TV, iPhone and iPad client for Plex: it plays the original file (Dolby Vision, Atmos,
every subtitle), requests titles through Seerr, and picks something to watch from a description (Ithaca Pro). Below are a
git-cliff draft and the raw commit log."
RULES="Rules:
- Each bullet is one plain sentence in the present tense. No version or build numbers, no jargon, no metaphors.
- Merge related commits into one bullet. Drop internal work (refactors, tooling, docs, screenshots, tests).
- Never invent anything that isn't in the commits.
- Output ONLY a JSON array of strings. No preamble, no code fences."

echo "whats_new: What to Test since ${BUILD_SINCE:-the first commit}, What's New since ${RELEASE_SINCE:-the first commit} ($MODEL)"
TEST_DRAFT="$(draft "$BUILD_SINCE")"
polish "$TMP/test.json" "$TEST_DRAFT" "$(commits "$BUILD_SINCE")" "You are writing TestFlight's 'What to Test' note for a
new beta build of Ithaca. $ABOUT

Write 1-5 short bullets: what changed in this build and what a tester should try. If nothing changed that a tester can
see, return [\"Fixes behind the scenes; nothing new to try.\"].
$RULES"

NEW_DRAFT="$(draft "$RELEASE_SINCE")"
if [ "$FIRST_RELEASE" = "1" ]; then printf '["The first release of Ithaca on the App Store."]' >"$TMP/new.json"; else
polish "$TMP/new.json" "$NEW_DRAFT" "$(commits "$RELEASE_SINCE")" "You are writing the App Store 'What's New' notes for a
release of Ithaca. $ABOUT

Write 2-6 short bullets about what someone with a Plex server gets from this release, most important first.
If nothing is user-facing, return [\"Fixes and improvements.\"].
$RULES"
fi

TEST_DRAFT="$TEST_DRAFT" NEW_DRAFT="$NEW_DRAFT" TMP="$TMP" TEST_PATH="$TEST_PATH" NEW_PATH="$NEW_PATH" python3 - <<'PY'
import json, os, re
from pathlib import Path

def bullets(name, draft, fallback):
    items = json.loads(Path(os.environ["TMP"], name).read_text() or "[]")
    if not items:
        items = [re.sub(r"^[-*]\s*", "", l).strip() for l in draft.splitlines() if l.strip().startswith(("-", "*"))]
    return items or [fallback]

# TestFlight's What to Test and the App Store's What's New both stop at 4000 characters.
for name, draft, path, fallback in [("test.json", os.environ["TEST_DRAFT"], os.environ["TEST_PATH"], "Fixes behind the scenes; nothing new to try."),
                                     ("new.json", os.environ["NEW_DRAFT"], os.environ["NEW_PATH"], "Fixes and improvements.")]:
    body = "\n".join(f"- {b}" for b in bullets(name, draft, fallback))[:3999]
    Path(path).write_text(body + "\n")
    print(f"whats_new: wrote {path}")
PY

# This version's changelog section, in place of an older one for the same version, under [Unreleased].
SECTION="$(draft "$RELEASE_SINCE" | sed "s/^## \[$VERSION\] - .*/## [$VERSION] - $DATE/")"
[ "$FIRST_RELEASE" = "1" ] && SECTION="$(printf '## [%s] - %s\n\nThe first App Store release.' "$VERSION" "$DATE")"
VERSION="$VERSION" SECTION="$SECTION" python3 - <<'PY'
import os, re
from pathlib import Path

path, version, section = Path("CHANGELOG.md"), os.environ["VERSION"], os.environ["SECTION"].strip()
text = path.read_text()
text = re.sub(rf"^## \[{re.escape(version)}\].*?(?=^## \[|\Z)", "", text, flags=re.S | re.M)
if section:
    head, sep, rest = text.partition("## [Unreleased]\n")
    if sep:
        text = head + sep + "\n" + section + "\n\n" + rest.lstrip("\n")
    else:
        text = text.rstrip("\n") + "\n\n" + section + "\n"
path.write_text(text)
print(f"whats_new: CHANGELOG.md has {version}")
PY
