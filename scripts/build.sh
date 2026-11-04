#!/bin/sh
# Builds the plugin into an installable zip in dist/, which git ignores.
# Usage: scripts/build.sh          from committed main, level with GitLab: dist/<name>-<version>.zip
#        scripts/build.sh --dev    from the current branch, named <name>-dev: dist/<name>-dev-<version>.zip
set -eu
fail() { printf 'REFUSED  %s\n' "$1" >&2; exit 1; }

case "$*" in
  "") DEV=0; REF=main ;;
  --dev) DEV=1; REF=HEAD ;;
  *) fail "usage: scripts/build.sh [--dev]" ;;
esac
cd "$(dirname "$0")/.."
command -v claude >/dev/null 2>&1 || fail "claude not found; the zip cannot be validated"

if [ "$DEV" = 1 ]; then
  [ -z "$(git status --porcelain)" ] || fail "uncommitted changes; commit or discard them first"
else
  # Checked over the push URL (SSH): the fetch URL may have no login in Terminal.
  LS=$(git ls-remote "$(git remote get-url --push origin)" refs/heads/main) || fail "cannot reach GitLab over SSH to check main is level"
  REMOTE=$(printf '%s' "$LS" | cut -f1)
  [ -n "$REMOTE" ] || fail "cannot read main from GitLab"
  [ "$(git rev-parse main)" = "$REMOTE" ] || fail "main is not level with GitLab; pull or push first"
fi

MANIFEST=$(git show "$REF:.claude-plugin/plugin.json" 2>/dev/null) || fail "no .claude-plugin/plugin.json on $REF"
NAME=$(printf '%s' "$MANIFEST" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])') || fail "cannot read the name from plugin.json"
V=$(printf '%s' "$MANIFEST" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])') || fail "cannot read the version from plugin.json"
[ "$DEV" = 0 ] || NAME="$NAME-dev"
OUT="dist/$NAME-$V.zip"
[ ! -e "$OUT" ] || fail "$OUT already exists; bump the version in plugin.json for a new build"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ethics-gate-lite-build.XXXXXX") || fail "cannot make a temporary folder"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/plugin"
git archive --format=tar -o "$TMP/plugin.tar" "$REF" .claude-plugin skills README.md || fail "cannot archive the plugin files from $REF"
tar -x -C "$TMP/plugin" -f "$TMP/plugin.tar"
if [ "$DEV" = 1 ]; then
  python3 - "$TMP/plugin/.claude-plugin/plugin.json" "$NAME" <<'EOF'
import json, sys
path, name = sys.argv[1], sys.argv[2]
with open(path) as f:
    manifest = json.load(f)
manifest["name"] = name
with open(path, "w") as f:
    json.dump(manifest, f, indent=2, ensure_ascii=False)
    f.write("\n")
EOF
fi

claude plugin validate --strict "$TMP/plugin" || fail "validation failed; nothing was written to dist/"
(cd "$TMP/plugin" && zip -qrX "$TMP/plugin.zip" .)
mkdir -p dist
mv "$TMP/plugin.zip" "$OUT"
printf 'BUILT    %s  (%s %s, from %s)\n' "$OUT" "$NAME" "$V" "$(git rev-parse --short "$REF")"
