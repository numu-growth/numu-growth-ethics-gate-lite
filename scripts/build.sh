#!/bin/sh
# Builds the plugin into an installable zip in dist/, which git ignores.
# The plugin is the numu-growth-ethics-gate-lite folder. The zip holds its .claude-plugin, skills, README.md and LICENSE.
# The repository root holds a copy of LICENSE and the build refuses unless the two copies are the same.
# A --version rebuild of a tag from before the plugin had its own folder builds from the repository root, with LICENSE when the tag has one. Release and --dev builds use the plugin folder only.
# Once every check has passed and the zip has validated, dist/ is emptied first, so it only ever holds the zip just built.
# A release or --dev build validates with --strict --profile directory, which adds those of the plugin directory's checks that the CLI runs. A --version rebuild validates with --strict alone, so every tagged version can be rebuilt.
# Usage: scripts/build.sh                      from committed main, level with GitLab: dist/<name>-<version>.zip; tags main v<version>
#        scripts/build.sh --dev                from the current branch, named <name>-dev: dist/<name>-dev-<version>.zip, never tagged
#        scripts/build.sh --version <version>  from tag v<version>: dist/<name>-<version>.zip, never tagged
set -eu
fail() { printf 'REFUSED  %s\n' "$1" >&2; exit 1; }
USAGE="usage: scripts/build.sh [--dev | --version <version>]"

case "${1-}" in
  "") [ $# -eq 0 ] || fail "$USAGE"; MODE=release; REF=main ;;
  --dev) [ $# -eq 1 ] || fail "$USAGE"; MODE=dev; REF=HEAD ;;
  --version) { [ $# -eq 2 ] && [ -n "$2" ]; } || fail "$USAGE"; MODE=rebuild; REF="refs/tags/v$2" ;;
  *) fail "$USAGE" ;;
esac
cd "$(dirname "$0")/.."
command -v claude >/dev/null 2>&1 || fail "claude not found; the zip cannot be validated"

case $MODE in
  dev) [ -z "$(git status --porcelain)" ] || fail "uncommitted changes; commit or discard them first" ;;
  rebuild) git rev-parse -q --verify "$REF^{commit}" >/dev/null || fail "no tag v$2; only a tagged version can be rebuilt" ;;
esac
COMMIT=$(git rev-parse -q --verify "$REF^{commit}") || fail "cannot find $REF"

PLUGIN_DIR=numu-growth-ethics-gate-lite
if git cat-file -e "$COMMIT:$PLUGIN_DIR/.claude-plugin/plugin.json" 2>/dev/null; then
  P="$PLUGIN_DIR/"
  ROOT_LICENSE=$(git rev-parse -q --verify "$COMMIT:LICENSE") || fail "no LICENSE at the repository root on $REF"
  PLUGIN_LICENSE=$(git rev-parse -q --verify "$COMMIT:${P}LICENSE") || fail "no $PLUGIN_DIR/LICENSE on $REF"
  [ "$ROOT_LICENSE" = "$PLUGIN_LICENSE" ] || fail "LICENSE and $PLUGIN_DIR/LICENSE differ; make them the same"
  LICENSE_FILE="${P}LICENSE"
elif [ "$MODE" = rebuild ] && git cat-file -e "$COMMIT:.claude-plugin/plugin.json" 2>/dev/null; then
  P=
  if git cat-file -e "$COMMIT:LICENSE" 2>/dev/null; then LICENSE_FILE=LICENSE; else LICENSE_FILE=; fi
else
  fail "no $PLUGIN_DIR/.claude-plugin/plugin.json on $REF"
fi

MANIFEST=$(git show "$COMMIT:${P}.claude-plugin/plugin.json" 2>/dev/null) || fail "no ${P}.claude-plugin/plugin.json on $REF"
NAME=$(printf '%s' "$MANIFEST" | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])') || fail "cannot read the name from plugin.json"
V=$(printf '%s' "$MANIFEST" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])') || fail "cannot read the version from plugin.json"
[ "$MODE" != rebuild ] || [ "$V" = "$2" ] || fail "plugin.json at tag v$2 gives version $V"
[ "$MODE" != dev ] || NAME="$NAME-dev"
OUT="dist/$NAME-$V.zip"

TAG="v$V"
NEWTAG=0
if [ "$MODE" = release ]; then
  # Checked over the push URL (SSH): the fetch URL may have no login in Terminal.
  LS=$(git ls-remote "$(git remote get-url --push origin)" refs/heads/main "refs/tags/$TAG" "refs/tags/$TAG^{}") || fail "cannot reach GitLab over SSH to check main is level"
  REMOTE=$(printf '%s\n' "$LS" | awk '$2 == "refs/heads/main" { print $1 }')
  [ -n "$REMOTE" ] || fail "cannot read main from GitLab"
  [ "$COMMIT" = "$REMOTE" ] || fail "main is not level with GitLab; pull or push first"
  REMOTE_TAG=$(printf '%s\n' "$LS" | awk -v t="refs/tags/$TAG" '$2 == t { l = $1 } $2 == t "^{}" { p = $1 } END { print (p != "" ? p : l) }')
  LOCAL_TAG=$(git rev-parse -q --verify "refs/tags/$TAG^{commit}" || true)
  for T in "$LOCAL_TAG" "$REMOTE_TAG"; do
    [ -z "$T" ] || [ "$T" = "$COMMIT" ] || fail "tag $TAG already points at $(printf '%s' "$T" | cut -c1-7), not main; raise the version in plugin.json"
  done
  [ -n "$LOCAL_TAG" ] || NEWTAG=1
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/numu-growth-ethics-gate-lite-build.XXXXXX") || fail "cannot make a temporary folder"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/tree"
git archive --format=tar -o "$TMP/plugin.tar" "$COMMIT" "${P}.claude-plugin" "${P}skills" "${P}README.md" $LICENSE_FILE || fail "cannot archive the plugin files from $REF"
tar -x -C "$TMP/tree" -f "$TMP/plugin.tar"
PLUGIN="$TMP/tree${P:+/$PLUGIN_DIR}"
if [ "$MODE" = dev ]; then
  python3 - "$PLUGIN/.claude-plugin/plugin.json" "$NAME" <<'EOF'
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

case $MODE in
  rebuild) claude plugin validate --strict "$PLUGIN" ;;
  *) claude plugin validate --strict --profile directory "$PLUGIN" ;;
esac || fail "validation failed; nothing was written to dist/"
(cd "$PLUGIN" && zip -qrX "$TMP/plugin.zip" .)
rm -rf dist
mkdir dist
mv "$TMP/plugin.zip" "$OUT"
printf 'BUILT    %s  (%s %s, from %s)\n' "$OUT" "$NAME" "$V" "$(git rev-parse --short "$COMMIT")"
if [ "$NEWTAG" = 1 ]; then
  git tag "$TAG" "$COMMIT" || fail "$OUT was built but tag $TAG could not be created"
  printf 'TAGGED   %s at %s\n' "$TAG" "$(git rev-parse --short "$COMMIT")"
fi
if [ "$MODE" = release ] && [ -z "$REMOTE_TAG" ]; then
  if git remote get-url github >/dev/null 2>&1; then
    printf 'PUSH     git push origin %s && git push github %s   (to GitLab and GitHub)\n' "$TAG" "$TAG"
  else
    printf 'PUSH     git push origin %s   (to GitLab only)\n' "$TAG"
  fi
fi
