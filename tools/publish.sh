#!/usr/bin/env bash
# publish.sh — veröffentlicht das Projekt auf GitHub.
#
# Benötigt einen GitHub-Token mit `repo`-Recht (klassischer PAT oder Fine-Grained PAT
# mit "Administration: Read and write" für den Ziel-Repo):
#
#   GITHUB_TOKEN=ghp_xxx ./tools/publish.sh
#
# Ohne Token kann das Repository nicht per API angelegt werden. In dem Fall:
#   1. Repository https://github.com/new anlegen (leer, ohne README)
#   2. git remote add origin git@github.com:nesirat/php2shell-guard.git
#   3. git push -u origin main
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd "$SELF_DIR/.." && pwd)

REPO_SLUG="${P2S_REPO:-nesirat/php2shell-guard}"
REPO_NAME="${REPO_SLUG##*/}"
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
DESCRIPTION="Detection, mitigation, patching and fleet automation for the PHP2Shell RCE pair (CVE-2026-109618 / CVE-2026-109619)"

api() {
	local method="$1" path="$2"
	shift 2
	curl -fsS -X "$method" \
		-H "Authorization: Bearer $TOKEN" \
		-H "Accept: application/vnd.github+json" \
		-H "X-GitHub-Api-Version: 2022-11-28" \
		"$@" "https://api.github.com$path"
}

if [ -z "$TOKEN" ]; then
	printf 'FEHLER: GITHUB_TOKEN nicht gesetzt.\n' >&2
	printf '      Ohne Token kann das Repository nicht per API angelegt werden.\n' >&2
	printf '      Alternative: Repository manuell anlegen, dann:\n' >&2
	printf '        git -C %q remote add origin git@github.com:%s.git\n' "$ROOT_DIR" "$REPO_SLUG" >&2
	printf '        git -C %q push -u origin main\n' "$ROOT_DIR" >&2
	exit 1
fi

printf '==> Token prüfen\n'
api GET /user | grep -q '"login"' || {
	printf 'FEHLER: Token ungültig.\n' >&2
	exit 1
}

printf '==> Repository %s anlegen\n' "$REPO_SLUG"
if api GET "/repos/$REPO_SLUG" >/dev/null 2>&1; then
	printf '    existiert bereits — überspringe Anlage\n'
else
	api POST /user/repos \
		-d "name=$REPO_NAME" \
		-d "description=$DESCRIPTION" \
		-d "private=false" \
		-d "has_issues=true" \
		-d "has_wiki=false" \
		-d "has_discussions=true" >/dev/null
	printf '    angelegt (public)\n'
fi

printf '==> Topics setzen\n'
api PUT "/repos/$REPO_SLUG/topics" \
	-d '{"names":["php","security","cve-2026-109618","cve-2026-109619","php2shell","hardening","fleet","devops","incident-response"]}' >/dev/null || true

printf '==> Remote setzen\n'
if git -C "$ROOT_DIR" remote get-url origin >/dev/null 2>&1; then
	git -C "$ROOT_DIR" remote set-url origin "git@github.com:${REPO_SLUG}.git"
else
	git -C "$ROOT_DIR" remote add origin "git@github.com:${REPO_SLUG}.git"
fi

printf '==> Push\n'
git -C "$ROOT_DIR" push -u origin HEAD

VERSION=$(grep -E '^P2S_VERSION=' "$ROOT_DIR/bin/php2shell-guard" | head -1 | cut -d'"' -f2)
TAG="v$VERSION"

printf '==> Release %s\n' "$TAG"
if api GET "/repos/$REPO_SLUG/releases/tags/$TAG" >/dev/null 2>&1; then
	printf '    Release existiert bereits — überspringe\n'
else
	NOTES=$(sed -n '/^## \[/,$p' "$ROOT_DIR/CHANGELOG.md" | head -40)
	api POST "/repos/$REPO_SLUG/releases" \
		-d "tag_name=$TAG" \
		-d "name=$TAG" \
		--data-urlencode "body=$NOTES" >/dev/null
	printf '    Release angelegt\n'
fi

printf '\n==> Fertig: https://github.com/%s\n' "$REPO_SLUG"
