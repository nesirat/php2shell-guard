#!/usr/bin/env bash
# shellcheck shell=bash
# php2shell-guard — Inventarisierung (Detection)

# Gibt PHP-Binaries aus: pfad|version
detect_php_binaries() {
	local b v seen=""
	for b in \
		"$(command -v php 2>/dev/null)" \
		/usr/bin/php /usr/local/bin/php \
		/usr/bin/php[0-9]* /usr/local/bin/php[0-9]* \
		/usr/bin/php[0-9]*.[0-9]* /usr/local/bin/php[0-9]*.[0-9]* \
		/opt/php*/bin/php /usr/local/php*/bin/php; do
		[ -x "$b" ] || continue
		case " $seen " in
		*" $b "*) continue ;;
		esac
		seen="$seen $b"
		v=$(normalize_version "$("$b" -v 2>/dev/null | head -1)")
		[ -z "$v" ] && continue
		printf '%s|%s\n' "$b" "$v"
	done
}

detect_fpm_binaries() {
	local b v seen=""
	for b in \
		"$(command -v php-fpm 2>/dev/null)" \
		/usr/sbin/php-fpm* /usr/local/sbin/php-fpm* \
		/usr/sbin/php-fpm[0-9]* /usr/sbin/php-fpm[0-9]*.[0-9]* \
		/usr/local/sbin/php-fpm[0-9]*.[0-9]*; do
		[ -x "$b" ] || continue
		case " $seen " in
		*" $b "*) continue ;;
		esac
		seen="$seen $b"
		v=$(normalize_version "$("$b" -v 2>/dev/null | head -1)")
		[ -z "$v" ] && continue
		printf '%s|%s\n' "$b" "$v"
	done
}

apache_ctl() {
	if command -v apache2ctl >/dev/null 2>&1; then printf 'apache2ctl'
	elif command -v apachectl >/dev/null 2>&1; then printf 'apachectl'
	elif command -v httpd >/dev/null 2>&1; then printf 'httpd'
	else printf ''
	fi
}

detect_mod_php() {
	local ctl out
	ctl=$(apache_ctl)
	if [ -n "$ctl" ]; then
		out=$("$ctl" -M 2>/dev/null || true)
		if printf '%s' "$out" | grep -qi 'php_module'; then
			printf 'yes'
			return 0
		fi
	fi
	if ls "${P2S_CONF_ROOT}"/etc/apache2/mods-enabled/*php*.load >/dev/null 2>&1; then printf 'yes'; return 0; fi
	if ls "${P2S_CONF_ROOT}"/etc/httpd/conf.d/*php*.conf >/dev/null 2>&1; then printf 'yes'; return 0; fi
	if ls "${P2S_CONF_ROOT}"/etc/httpd/conf.modules.d/*php*.conf >/dev/null 2>&1; then printf 'yes'; return 0; fi
	printf 'no'
}

detect_nginx() {
	command -v nginx >/dev/null 2>&1 && printf 'yes' || printf 'no'
}

detect_cgi() {
	local b
	for b in php-cgi /usr/bin/php-cgi /usr/local/bin/php-cgi; do
		if [ -x "$b" ] || command -v "$b" >/dev/null 2>&1; then printf 'yes'; return 0; fi
	done
	if ls -d "${P2S_CONF_ROOT}"/etc/php/*/cgi >/dev/null 2>&1; then printf 'yes'; return 0; fi
	printf 'no'
}

# Verzeichnisse der Apache-Konfiguration
apache_conf_dirs() {
	local d
	for d in /etc/apache2/conf-available /etc/apache2/conf-enabled /etc/apache2/mods-enabled \
		/etc/apache2/sites-enabled /etc/httpd/conf.d /etc/httpd/conf.modules.d /etc/httpd/conf; do
		[ -d "$d" ] && printf '%s\n' "$d"
	done
	return 0
}

apache_conf_files() {
	local d
	for d in $(apache_conf_dirs); do
		find "$d" -maxdepth 1 -type f \( -name '*.conf' -o -name '*.load' \) 2>/dev/null
	done
	return 0
}

fpm_pool_dirs() {
	local d
	for d in "${P2S_CONF_ROOT}"/etc/php/*/fpm "${P2S_CONF_ROOT}"/etc/php/*/fpm/pool.d \
		"${P2S_CONF_ROOT}"/etc/php-fpm.d "${P2S_CONF_ROOT}"/usr/local/etc/php-fpm.d \
		"${P2S_CONF_ROOT}"/opt/php*/etc/php-fpm.d; do
		[ -d "$d" ] && printf '%s\n' "$d"
	done
	return 0
}

fpm_pool_files() {
	local d
	for d in $(fpm_pool_dirs); do
		case "$d" in
		*/pool.d) find "$d" -maxdepth 1 -type f -name '*.conf' 2>/dev/null ;;
		*) find "$d" -maxdepth 1 -type f -name '*.conf' 2>/dev/null ;;
		esac
	done
	return 0
}

fpm_services() {
	local s
	for s in $(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -iE '^php.*fpm' | sort -u); do
		printf '%s\n' "$s"
	done
	for s in php-fpm php-fpm.service; do
		systemctl list-unit-files "$s" >/dev/null 2>&1 && printf '%s\n' "$s"
	done | sort -u
	return 0
}

# Web-Roots aus Apache/nginx-Konfiguration
detect_web_roots() {
	local r
	for r in $(grep -rhoiE '^[[:space:]]*DocumentRoot[[:space:]]+"[^"]+"' /etc/apache2/sites-enabled /etc/apache2/conf-enabled /etc/httpd/conf 2>/dev/null |
		sed -E 's/.*"([^"]+)"/\1/'); do
		[ -d "$r" ] && printf '%s\n' "$r"
	done
	for r in $(grep -rhoiE '^[[:space:]]*(root|alias)[[:space:]]+[^;[:space:]]+' /etc/nginx 2>/dev/null |
		awk '{print $2}' | tr -d '"'); do
		[ -d "$r" ] && printf '%s\n' "$r"
	done
	for r in /var/www/html /var/www /usr/share/nginx/html /srv/www; do
		[ -d "$r" ] && printf '%s\n' "$r"
	done
	return 0
}

detect_vhosts() {
	grep -rhoiE '^[[:space:]]*ServerName[[:space:]]+[^[:space:]]+' /etc/apache2/sites-enabled /etc/httpd/conf.d /etc/httpd/conf 2>/dev/null |
		awk '{print $2}' | sort -u
	return 0
}

# Alle Konfigurationsdateien, die fuer die Mitigation relevant sind
relevant_config_files() {
	local f
	for f in $(apache_conf_files); do printf '%s\n' "$f"; done
	for f in $(fpm_pool_files); do printf '%s\n' "$f"; done
	for f in $(find "${P2S_CONF_ROOT}"/etc/php "${P2S_CONF_ROOT}"/etc/php.d \
		"${P2S_CONF_ROOT}"/usr/local/etc/php "${P2S_CONF_ROOT}"/usr/local/etc/php/conf.d -maxdepth 4 -type f \( -name 'php.ini' -o -name '*.ini' \) 2>/dev/null); do
		printf '%s\n' "$f"
	done
	return 0
}

# SAPI-spezifische Konfigurationsdateien (nur was die WEB-SAPI wirklich benutzt)
config_files_for_sapi() {
	local sapi="${1:-}"
	local f
	case "$sapi" in
	apache2handler)
		for f in $(apache_conf_files); do printf '%s\n' "$f"; done
		for f in "${P2S_CONF_ROOT}"/etc/php/*/apache*/php.ini "${P2S_CONF_ROOT}"/etc/php/*/apache*/conf.d/*.ini \
			"${P2S_CONF_ROOT}"/usr/local/etc/php/*/apache*/php.ini \
			"${P2S_CONF_ROOT}"/usr/local/etc/php/*/apache*/conf.d/*.ini; do
			[ -f "$f" ] && printf '%s\n' "$f"
		done
		;;
	fpm)
		for f in $(fpm_pool_files); do printf '%s\n' "$f"; done
		for f in "${P2S_CONF_ROOT}"/etc/php/*/fpm/php.ini "${P2S_CONF_ROOT}"/etc/php/*/fpm/conf.d/*.ini \
			"${P2S_CONF_ROOT}"/etc/php/*/fpm/pool.d/*.conf \
			"${P2S_CONF_ROOT}"/usr/local/etc/php/*/fpm/php.ini \
			"${P2S_CONF_ROOT}"/usr/local/etc/php/*/fpm/conf.d/*.ini; do
			[ -f "$f" ] && printf '%s\n' "$f"
		done
		;;
	cgi-fcgi)
		for f in "${P2S_CONF_ROOT}"/etc/php/*/cgi/php.ini "${P2S_CONF_ROOT}"/etc/php/*/cgi/conf.d/*.ini \
			"${P2S_CONF_ROOT}"/etc/php.d/*.ini \
			"${P2S_CONF_ROOT}"/usr/local/etc/php/*/cgi/php.ini; do
			[ -f "$f" ] && printf '%s\n' "$f"
		done
		;;
	cli)
		for f in "${P2S_CONF_ROOT}"/etc/php/*/cli/php.ini "${P2S_CONF_ROOT}"/etc/php/*/cli/conf.d/*.ini; do
			[ -f "$f" ] && printf '%s\n' "$f"
		done
		;;
	*)
		return 0
		;;
	esac
	return 0
}

# Prueft, ob ein Directive admin-gesichert gesetzt ist (php_admin_value).
# Ausgabe: admin | ini | none
config_admin_value() {
	local key="$1"
	shift
	local f
	for f in "$@"; do
		[ -f "$f" ] || continue
		if grep -qiE "php_admin_value\[${key}\][[:space:]]*=" "$f" 2>/dev/null; then
			printf 'admin'
			return 0
		fi
		if grep -qiE "php_admin_value[[:space:]]+${key}[[:space:]]*=" "$f" 2>/dev/null; then
			printf 'admin'
			return 0
		fi
	done
	for f in "$@"; do
		[ -f "$f" ] || continue
		if grep -qiE "^[[:space:]]*${key}[[:space:]]*=" "$f" 2>/dev/null; then
			printf 'ini'
			return 0
		fi
	done
	printf 'none'
}

# Wert eines Directives aus php_admin_value/php_value/ini-Zeilen (letzter Treffer gewinnt)
config_directive_value() {
	local key="$1"
	shift
	local f v="" found=""
	for f in "$@"; do
		[ -f "$f" ] || continue
		found=""
		found=$(grep -ihE "php_admin_value\[${key}\][[:space:]]*=" "$f" 2>/dev/null | tail -1 |
			sed -E "s/.*=[[:space:]]*//; s/[[:space:]]+$//; s/;.*$//")
		if [ -z "$found" ]; then
			found=$(grep -ihE "php_admin_value[[:space:]]+${key}[[:space:]]*=" "$f" 2>/dev/null | tail -1 |
				sed -E "s/.*=[[:space:]]*//; s/[[:space:]]+$//; s/;.*$//")
		fi
		if [ -z "$found" ]; then
			found=$(grep -ihE "^[[:space:]]*${key}[[:space:]]*=" "$f" 2>/dev/null | tail -1 |
				sed -E "s/.*=[[:space:]]*//; s/[[:space:]]+$//; s/;.*$//")
		fi
		if [ -n "$found" ]; then
			v="$found"
		fi
	done
	printf '%s' "$v"
}

# app-level Overrides (php_value / ini_set) die eine admin-level Mitigation aushebeln
detect_overrides() {
	local key="$1"
	shift
	local f out=""
	for f in "$@"; do
		[ -f "$f" ] || continue
		out=$(grep -ihE "^[[:space:]]*php_value[[:space:]]+${key}[[:space:]]*=" "$f" 2>/dev/null)
		[ -n "$out" ] && printf '%s\n' "$out"
	done
	printf '%s' ""
}

# Vollstaendiges Inventar als JSON-Fragment-Array (ohne Klammern)
detect_install_json() {
	local sapi="$1" version="$2" binary="$3"
	shift 3
	local cfgs="$*"
	local branch fixed patched mit_status risk missing=""

	branch=$(ver_branch "$version")
	fixed=$(php_fixed_min_version "$branch")
	if [ -n "$fixed" ] && php_version_patched "$version" "$branch"; then
		patched="true"
	else
		patched="false"
	fi

	# Mitigation-Status aus den Konfigurationsdateien
	local ml sup feb ml_enf sup_enf
	ml=$(config_directive_value memory_limit $cfgs)
	sup=$(config_directive_value session.upload_progress.enabled $cfgs)
	feb=$(config_directive_value fatal_error_backtraces $cfgs)
	ml_enf=$(config_admin_value memory_limit $cfgs)
	sup_enf=$(config_admin_value session.upload_progress.enabled $cfgs)

	# Wirksam nur, wenn admin-gesichert gesetzt (nicht durch die App ueberschreibbar)
	local ml_ok=0 sup_ok=0
	[ "$ml" = "-1" ] && [ "$ml_enf" = "admin" ] && ml_ok=1
	[ "$sup" = "0" ] && [ "$sup_enf" = "admin" ] && sup_ok=1

	if [ "$ml_ok" = "1" ] && [ "$sup_ok" = "1" ]; then
		mit_status="applied"
	elif [ "$ml" = "-1" ] || [ "$sup" = "0" ]; then
		mit_status="partial"
	else
		mit_status="missing"
	fi

	if [ "$ml_ok" = "0" ]; then
		if [ "$ml" = "-1" ]; then
			missing="$missing memory_limit(nicht-admin-gesichert)"
		else
			missing="$missing memory_limit"
		fi
	fi
	if [ "$sup_ok" = "0" ]; then
		if [ "$sup" = "0" ]; then
			missing="$missing session.upload_progress.enabled(nicht-admin-gesichert)"
		else
			missing="$missing session.upload_progress.enabled"
		fi
	fi
	if php_has_fatal_backtraces "$version" && [ "$feb" != "0" ]; then
		missing="$missing fatal_error_backtraces"
	fi

	if [ "$patched" = "true" ]; then
		risk="low"
	elif [ "$mit_status" = "applied" ]; then
		risk="medium"
	else
		risk="critical"
	fi

	local cj="{\"sapi\":$(json_str "$sapi")"
	cj="$cj,\"php_version\":$(json_str "$version")"
	cj="$cj,\"branch\":$(json_str "$branch")"
	cj="$cj,\"fixed_min\":$(json_str "$fixed")"
	cj="$cj,\"patched\":$patched"
	cj="$cj,\"mitigation\":$(json_str "$mit_status")"
	cj="$cj,\"risk\":$(json_str "$risk")"
	cj="$cj,\"memory_limit\":$(json_str "$ml")"
	cj="$cj,\"memory_limit_enforcement\":$(json_str "$ml_enf")"
	cj="$cj,\"session_upload_progress\":$(json_str "$sup")"
	cj="$cj,\"session_upload_progress_enforcement\":$(json_str "$sup_enf")"
	cj="$cj,\"fatal_error_backtraces\":$(json_str "$feb")"
	cj="$cj,\"missing\":$(json_str "$missing")"
	cj="$cj,\"binary\":$(json_str "$binary")}"
	printf '%s' "$cj"
}

cmd_scan() {
	local webroot_override=""
	while [ $# -gt 0 ]; do
		case "$1" in
		--json) P2S_JSON=1 ;;
		--webroot)
			webroot_override="$2"
			shift
			;;
		*) die "Unbekannte Option fuer scan: $1" ;;
		esac
		shift
	done

	local mod_php nginx cgi
	mod_php=$(detect_mod_php)
	nginx=$(detect_nginx)
	cgi=$(detect_cgi)

	local cfg_files
	cfg_files=$(relevant_config_files | sort -u)

	local entries="" count=0
	local rows=""
	local seen=""
	local critical_count=0
	local b v sapi bin

	add_row() {
		local key="$1"
		if printf '%s\n' "$seen" | grep -qxF "$key"; then
			return 0
		fi
		seen="$seen$key"$'\n'
		local sapi_cfgs js risk
		sapi_cfgs=$(config_files_for_sapi "$sapi" | sort -u)
		if ! js=$(detect_install_json "$sapi" "$v" "$bin" $sapi_cfgs); then
			log_err "Inventarisierung fehlgeschlagen für $sapi $v"
			return 1
		fi
		risk=$(printf '%s' "$js" | sed -n 's/.*"risk":"\([^"]*\)".*/\1/p')
		if [ "$risk" = "critical" ]; then
			critical_count=$((critical_count + 1))
		fi
		entries="$entries$js,"
		rows="$rows$sapi|$v|$bin"$'\n'
		count=$((count + 1))
	}

	# mod_php
	if [ "$mod_php" = "yes" ]; then
		for b in $(detect_php_binaries); do
			IFS='|' read -r bin v <<<"$b"
			sapi="apache2handler"
			add_row "apache2handler|$v"
		done
	fi

	# PHP-FPM
	local fpm_found=0
	for b in $(detect_fpm_binaries); do
		fpm_found=1
		IFS='|' read -r bin v <<<"$b"
		sapi="fpm"
		add_row "fpm|$v"
	done
	if [ "$fpm_found" = "0" ]; then
		for d in "${P2S_CONF_ROOT}"/etc/php/*/fpm; do
			[ -d "$d" ] || continue
			v=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$d/php-fpm.conf" 2>/dev/null | head -1)
			[ -z "$v" ] && continue
			bin="$d/php-fpm"
			sapi="fpm"
			add_row "fpm|$v"
		done
	fi

	# CGI
	if [ "$cgi" = "yes" ]; then
		for b in $(detect_php_binaries); do
			IFS='|' read -r bin v <<<"$b"
			sapi="cgi-fcgi"
			add_row "cgi-fcgi|$v"
		done
	fi

	# Nur CLI, kein Web-Serving
	if [ "$count" = "0" ]; then
		for b in $(detect_php_binaries); do
			IFS='|' read -r bin v <<<"$b"
			sapi="cli"
			add_row "cli|$v"
		done
	fi

	# Trailing comma entfernen
	entries="${entries%,}"

	if is_true "$P2S_JSON"; then
		printf '{"tool":"php2shell-guard","tool_version":"%s","host":%s,"timestamp":"%s","cves":["CVE-2026-109618","CVE-2026-109619"],"web_serving":{"mod_php":%s,"fpm":%s,"nginx":%s,"cgi":%s},"installs":[%s]}\n' \
			"$P2S_VERSION" "$(json_str "$(host_label)")" "$(ts_utc)" \
			"$(json_bool "$([ "$mod_php" = yes ] && echo 1 || echo 0)")" \
			"$(json_bool "$([ "$fpm_found" = 1 ] && echo 1 || echo 0)")" \
			"$(json_bool "$([ "$nginx" = yes ] && echo 1 || echo 0)")" \
			"$(json_bool "$([ "$cgi" = yes ] && echo 1 || echo 0)")" \
			"$entries"
		if [ "$critical_count" -gt 0 ]; then
			return 2
		fi
		return 0
	fi

	log_step "PHP2Shell-Scan auf $(host_label)"
	log_info "OS: $(os_id) $(os_version) | Paketmanager: $(pkg_manager)"
	log_info "SAPI: mod_php=$mod_php fpm=$([ "$fpm_found" = 1 ] && echo yes || echo no) nginx=$nginx cgi=$cgi"
	log ""

	if [ "$count" = "0" ]; then
		log_ok "Keine PHP-Installation auf diesem Host gefunden."
		return 0
	fi

	local found_critical=0
	printf '  %-14s %-12s %-10s %-10s %-9s %s\n' "SAPI" "PHP" "Fix ab" "gepatcht" "Risiko" "fehlende Mitigation"
	while IFS='|' read -r sapi v bin; do
		[ -n "$sapi" ] || continue
		local branch fixed patched risk missing mit
		branch=$(ver_branch "$v")
		fixed=$(php_fixed_min_version "$branch")
		if [ -n "$fixed" ] && php_version_patched "$v" "$branch"; then
			patched="ja"
			risk="low"
		else
			patched="nein"
			risk="critical"
			found_critical=1
		fi
		mit=$(detect_install_json "$sapi" "$v" "$bin" $(config_files_for_sapi "$sapi" | sort -u))
		missing=$(printf '%s' "$mit" | sed -n 's/.*"missing":"\([^"]*\)".*/\1/p')
		printf '  %-14s %-12s %-10s %-10s %-9s %s\n' \
			"$sapi" "$v" "${fixed:-kein-Fix(EOL)}" "$patched" "$risk" "${missing:-keine}"
	done <<EOF
$rows
EOF

	if [ "$found_critical" = "1" ]; then
		log ""
		log_err "Kritisch: mindestens eine ungepatchte PHP-Version gefunden."
		log_err "Nächste Schritte: 'php2shell-guard mitigate' (sofort) und 'php2shell-guard patch' (Update)."
		return 2
	fi
	log ""
	log_ok "Alle gefundenen PHP-Versionen sind gepatcht."
	return 0
}
