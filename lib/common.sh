#!/usr/bin/env bash
# shellcheck shell=bash
# php2shell-guard — shared helpers
# CVE-2026-109618 / CVE-2026-109619 ("PHP2Shell")

P2S_VERSION="${P2S_VERSION:-0.1.0}"
# shellcheck disable=SC2034 # von anderen Dateien gelesen; shellcheck prueft jede Datei einzeln
P2S_CVES="CVE-2026-109618 CVE-2026-109619"
# shellcheck disable=SC2034
P2S_START_MARK=">>> php2shell-guard >>>"
# shellcheck disable=SC2034
P2S_END_MARK="<<< php2shell-guard <<<"

P2S_CONF_ROOT="${P2S_CONF_ROOT:-}"
P2S_DRY_RUN="${P2S_DRY_RUN:-0}"
P2S_ASSUME_YES="${P2S_ASSUME_YES:-0}"
P2S_JSON="${P2S_JSON:-0}"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RESET=$'\033[0m'
	C_RED=$'\033[31m'
	C_GREEN=$'\033[32m'
	C_YELLOW=$'\033[33m'
	C_BLUE=$'\033[34m'
	C_BOLD=$'\033[1m'
else
	C_RESET=""
	C_RED=""
	C_GREEN=""
	C_YELLOW=""
	C_BLUE=""
	C_BOLD=""
fi

log() { printf '%s\n' "$*"; }

log_info() { printf '%s[*]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_ok() { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_err() { printf '%s[-]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
log_step() { printf '%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
log_dry() { printf '%s[dry-run]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }

die() {
	log_err "$*"
	exit 1
}

is_true() {
	case "${1:-}" in
		1 | true | TRUE | yes | YES | y | Y) return 0 ;;
		*) return 1 ;;
	esac
}

ts_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

ts_compact() { date -u +%Y%m%dT%H%M%SZ; }

host_label() {
	hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'unknown'
}

require_root() {
	if [ "$(id -u)" != "0" ]; then
		die "Root-Rechte erforderlich (oder mit --sudo auf einem Host mit sudo -n ausfuehren)."
	fi
}

confirm() {
	local prompt="$1"
	local answer=""
	if is_true "$P2S_ASSUME_YES"; then
		return 0
	fi
	if [ ! -t 0 ]; then
		log_warn "Kein TTY und --yes nicht gesetzt: automatisch bestaetigt ($prompt)"
		return 0
	fi
	printf '%s%s%s [y/N] ' "$C_BOLD" "$prompt" "$C_RESET"
	read -r answer || answer=""
	case "$answer" in
		y | Y | yes | YES) return 0 ;;
		*) return 1 ;;
	esac
}

json_escape() {
	local s="$1"
	s=${s//\\/\\\\}
	s=${s//\"/\\\"}
	s=${s//$'\n'/ }
	s=${s//$'\r'/ }
	s=${s//$'\t'/\\t}
	printf '%s' "$s"
}

json_str() { printf '"%s"' "$(json_escape "$1")"; }

json_bool() {
	if is_true "${1:-0}"; then printf 'true'; else printf 'false'; fi
}

# ver_ge A B -> true, wenn Version A >= B (numerisch, tolerant gegen Suffixe)
ver_ge() {
	local i x y
	local -a va vb
	IFS=. read -r -a va <<<"${1%%-*}"
	IFS=. read -r -a vb <<<"${2%%-*}"
	for i in 0 1 2; do
		x="${va[$i]:-0}"
		y="${vb[$i]:-0}"
		x="${x//[^0-9]/}"
		y="${y//[^0-9]/}"
		[ -z "$x" ] && x=0
		[ -z "$y" ] && y=0
		if [ "$x" -gt "$y" ]; then return 0; fi
		if [ "$x" -lt "$y" ]; then return 1; fi
	done
	return 0
}

ver_major_minor() {
	local v="$1"
	v="${v#PHP }"
	printf '%s' "${v%%.*}" | tr -cd '0-9'
}

ver_branch() {
	local v="${1#PHP }"
	v="${v%%-*}"
	printf '%s.%s' "$(printf '%s' "$v" | cut -d. -f1)" "$(printf '%s' "$v" | cut -d. -f2)"
}

# Mindestversion mit offiziellem Fix je Branch; leer = kein Upstream-Fix (EOL)
php_fixed_min_version() {
	case "$1" in
		8.5) printf '8.5.12' ;;
		8.4) printf '8.4.27' ;;
		8.3) printf '8.3.36' ;;
		8.2) printf '8.2.35' ;;
		*) printf '' ;;
	esac
}

# true, wenn die PHP-Version den offiziellen Fix enthaelt
php_version_patched() {
	local ver="$1" branch="$2" fixed
	fixed=$(php_fixed_min_version "$branch")
	if [ -z "$fixed" ]; then
		return 1
	fi
	ver_ge "$ver" "$fixed"
}

# true, wenn Branch >= 8.5 (fatal_error_backtraces existiert)
php_has_fatal_backtraces() {
	ver_ge "$1" "8.5.0"
}

normalize_version() {
	local v="$1"
	v="${v#PHP }"
	v="${v%% (*}"
	v="${v%% *}"
	printf '%s' "$v"
}

os_id() {
	if [ -r /etc/os-release ]; then
		# shellcheck disable=SC1091
		. /etc/os-release
		printf '%s' "${ID:-unknown}"
		return 0
	fi
	printf 'unknown'
}

os_version() {
	if [ -r /etc/os-release ]; then
		# shellcheck disable=SC1091
		. /etc/os-release
		printf '%s' "${VERSION_ID:-unknown}"
		return 0
	fi
	printf 'unknown'
}

pkg_manager() {
	if command -v apt-get >/dev/null 2>&1; then
		printf 'apt'
	elif command -v dnf >/dev/null 2>&1; then
		printf 'dnf'
	elif command -v yum >/dev/null 2>&1; then
		printf 'yum'
	elif command -v apk >/dev/null 2>&1; then
		printf 'apk'
	elif command -v zypper >/dev/null 2>&1; then
		printf 'zypper'
	else
		printf 'none'
	fi
}

file_backup() {
	local f="$1"
	[ -e "$f" ] || return 0
	local bak
	bak="${f}.p2s-backup.$(ts_compact)"
	cp -a "$f" "$bak" 2>/dev/null && log_ok "Backup: $bak"
}

# Block-Ersetzung: entfernt einen verwalteten Block und haengt den neuen an (EOF)
upsert_block() {
	local target="$1" marker_start="$2" marker_end="$3" content_file="$4"
	local tmp
	tmp=$(mktemp) || return 1
	awk -v start="$marker_start" -v end="$marker_end" -v cfile="$content_file" '
		BEGIN { skip = 0 }
		$0 == start { skip = 1; next }
		$0 == end   { skip = 0; next }
		skip != 1   { print }
		END {
			print ""
			while ((getline line < cfile) > 0) print line
			close(cfile)
		}
	' "$target" >"$tmp" || {
		rm -f "$tmp"
		return 1
	}
	cat "$tmp" >"$target"
	rm -f "$tmp"
	return 0
}

has_block() {
	local target="$1" marker="$2"
	[ -f "$target" ] && grep -qxF "$marker" "$target"
}

in_dir() {
	local needle="$1"
	shift
	local d
	for d in "$@"; do
		[ -d "$d" ] || continue
		if printf '%s' "$d" | grep -qF "$needle"; then
			return 0
		fi
	done
	return 1
}

run_cmd() {
	if is_true "$P2S_DRY_RUN"; then
		log_dry "$*"
		return 0
	fi
	"$@"
}

# Liest einen ini-Wert aus einer Liste von Konfigurationsdateien.
# Gibt den letzten gefundenen Wert zurueck (leer = nicht gesetzt).
ini_value_from_files() {
	local key="$1"
	shift
	local f v=""
	for f in "$@"; do
		[ -f "$f" ] || continue
		v=$(grep -ihE "^[[:space:]]*${key}[[:space:]]*=" "$f" 2>/dev/null | tail -1 | sed -E "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//; s/;.*$//; s/[[:space:]]+$//")
		[ -n "$v" ] && printf '%s' "$v"
	done
	printf '%s' ""
}

php_ini_paths() {
	local b="$1" loaded scan
	loaded=$("$b" --ini 2>/dev/null | awk -F': ' '/Loaded Configuration File/ {print $2}')
	if [ -n "$loaded" ] && [ -f "$loaded" ]; then
		printf '%s\n' "$loaded"
	fi
	scan=$("$b" --ini 2>/dev/null | awk -F': ' '/Scan for additional .ini files in/ {print $2}')
	if [ -n "$scan" ] && [ -d "$scan" ]; then
		printf '%s\n' "$scan"
	fi
	return 0
}
