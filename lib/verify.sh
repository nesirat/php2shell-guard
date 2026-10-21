#!/usr/bin/env bash
# shellcheck shell=bash
# php2shell-guard — Verifikation der effektiven PHP-Konfiguration

# Bytes aus "8M", "32M", "8388608", "1G"
size_to_bytes() {
	local v="$1" num unit
	num="${v%%[!0-9]*}"
	unit="${v#$num}"
	case "$unit" in
	K | k) printf '%s' $((num * 1024)) ;;
	M | m) printf '%s' $((num * 1024 * 1024)) ;;
	G | g) printf '%s' $((num * 1024 * 1024 * 1024)) ;;
	*) printf '%s' "$num" ;;
	esac
}

# Verzeichnis der Web-Roots bestimmen
detect_probe_roots() {
	local r
	for r in $(detect_web_roots); do
		printf '%s\n' "$r"
	done
}

probe_file_content() {
	cat <<'EOF'
<?php
header('Content-Type: text/plain; charset=utf-8');
$keys = array(
    'memory_limit',
    'post_max_size',
    'upload_max_filesize',
    'session.upload_progress.enabled',
    'fatal_error_backtraces',
    'max_input_nesting_level',
    'max_input_vars',
    'max_file_uploads',
);
echo "p2s_probe=1\n";
echo "sapi=" . php_sapi_name() . "\n";
echo "version=" . PHP_VERSION . "\n";
foreach ($keys as $k) {
    echo $k . "=" . ini_get($k) . "\n";
}
EOF
}

# Prüft eine Ist/Soll-Kombination
verify_directive() {
	local key="$1" actual="$2" expected="$3" mode="${4:-eq}"
	local ok=1
	case "$mode" in
	eq)
		[ "$actual" = "$expected" ] || ok=0
		;;
	max)
		if [ -z "$actual" ]; then
			ok=0
		else
			[ "$(size_to_bytes "$actual")" -le "$(size_to_bytes "$expected")" ] || ok=0
		fi
		;;
	esac
	if [ "$ok" = "1" ]; then
		printf 'OK'
	else
		printf 'FEHLER'
	fi
}

cmd_verify() {
	local url=""
	local vhost=""
	local docroot=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--url)
			url="$2"
			shift
			;;
		--vhost)
			vhost="$2"
			shift
			;;
		--docroot)
			docroot="$2"
			shift
			;;
		--json) P2S_JSON=1 ;;
		*) die "Unbekannte Option für verify: $1" ;;
		esac
		shift
	done

	log_step "Verifikation der effektiven PHP-Konfiguration auf $(host_label)"

	local roots
	if [ -n "$docroot" ]; then
		roots="$docroot"
	else
		roots=$(detect_probe_roots | head -1)
	fi

	if [ -z "$url" ]; then
		if [ -z "$roots" ]; then
			log_err "Kein Web-Root gefunden. Bitte --docroot oder --url angeben."
			return 1
		fi
		url="http://127.0.0.1/"
	fi

	if [ ! -d "$roots" ]; then
		log_err "Web-Root nicht erreichbar: $roots"
		return 1
	fi

	local probe="$roots/__p2s_probe_$$.php"
	log_info "Probe: $probe -> $url"

	if is_true "$P2S_DRY_RUN"; then
		log_dry "would probe $url"
		return 0
	fi

	probe_file_content >"$probe" || {
		log_err "Probe-Datei konnte nicht geschrieben werden: $probe"
		return 1
	}

	local out=""
	local curl_opts="-s --max-time 15"
	if [ -n "$vhost" ]; then
		curl_opts="$curl_opts -H Host:$vhost"
	fi
	out=$(curl $curl_opts "$url" 2>/dev/null || true)
	rm -f "$probe"

	if [ -z "$out" ] || ! printf '%s' "$out" | grep -q 'p2s_probe=1'; then
		log_err "Probe nicht abrufbar (URL=$url). Ist PHP unter dieser URL erreichbar?"
		return 1
	fi

	local sapi version
	sapi=$(printf '%s' "$out" | awk -F= '/^sapi=/{print $2}')
	version=$(printf '%s' "$out" | awk -F= '/^version=/{print $2}')

	local val
	val() { printf '%s' "$out" | awk -F= -v k="$1" '$1==k {print substr($0, index($0,"=")+1)}' | tail -1; }

	log ""
	log_info "SAPI: $sapi | Version: $version"
	log ""

	local ml sup pms umf min miv mfu feb
	ml=$(val memory_limit)
	sup=$(val session.upload_progress.enabled)
	pms=$(val post_max_size)
	umf=$(val upload_max_filesize)
	min=$(val max_input_nesting_level)
	miv=$(val max_input_vars)
	mfu=$(val max_file_uploads)
	feb=$(val fatal_error_backtraces)

	local failed=0
	row() {
		local key="$1" val="$2" expected="$3" mode="$4"
		local res
		res=$(verify_directive "$key" "$val" "$expected" "$mode")
		if [ "$res" = "FEHLER" ]; then
			failed=$((failed + 1))
		fi
		printf '  %-32s Ist=%-10s Soll=%-10s %s\n' "$key" "${val:-<leer>}" "$expected" "$res"
	}

	row memory_limit "$ml" "-1" eq
	row session.upload_progress.enabled "$sup" "0" eq
	row post_max_size "$pms" "32M" max
	row upload_max_filesize "$umf" "32M" max
	row max_input_nesting_level "$min" "64" max
	row max_input_vars "$miv" "2000" max
	row max_file_uploads "$mfu" "20" max
	if php_has_fatal_backtraces "$version"; then
		row fatal_error_backtraces "$feb" "0" eq
	fi

	log ""
	if [ "$failed" = "0" ]; then
		log_ok "Alle geprüften Mitigationen sind aktiv."
	else
		log_err "$failed Prüfung(en) fehlgeschlagen."
	fi

	local branch fixed patched
	branch=$(ver_branch "$version")
	fixed=$(php_fixed_min_version "$branch")
	if [ -n "$fixed" ] && php_version_patched "$version" "$branch"; then
		log_ok "PHP $version enthält den offiziellen Fix (>= $fixed)."
	else
		log_err "PHP $version ist NICHT gepatcht (Fix ab ${fixed:-kein Upstream-Fix für EOL-Branch $branch})."
		log_err "Mitigation ist nur ein Notfallschutz — Update ist zwingend erforderlich."
	fi

	return $((failed > 0 ? 1 : 0))
}
