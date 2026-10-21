#!/usr/bin/env bash
# shellcheck shell=bash
# php2shell-guard — Mitigation (Härtung) für laufende Systeme

P2S_TEMPLATE_DIR="${P2S_TEMPLATE_DIR:-${SELF_DIR:-.}/../templates}"

P2S_POST_MAX="${P2S_POST_MAX:-8M}"
P2S_UPLOAD_MAX="${P2S_UPLOAD_MAX:-8M}"
P2S_MAX_NESTING="${P2S_MAX_NESTING:-16}"
P2S_MAX_INPUT_VARS="${P2S_MAX_INPUT_VARS:-1000}"
P2S_MAX_FILE_UPLOADS="${P2S_MAX_FILE_UPLOADS:-10}"
P2S_LIMIT_REQUEST_BODY="${P2S_LIMIT_REQUEST_BODY:-8388608}"
P2S_LIMIT_REQUEST_FIELDS="${P2S_LIMIT_REQUEST_FIELDS:-100}"
P2S_LIMIT_REQUEST_FIELD_SIZE="${P2S_LIMIT_REQUEST_FIELD_SIZE:-8192}"
P2S_CGROUP_LIMIT_MB="${P2S_CGROUP_LIMIT_MB:-}"

# Template-Inhalt ausgeben (Datei oder eingebettet im Bundle)
tpl_content() {
	local name="$1"
	if [ -n "${P2S_EMBEDDED_TEMPLATES:-}" ] && declare -F p2s_embedded_templates >/dev/null 2>&1; then
		p2s_embedded_templates "$name"
		return 0
	fi
	local f
	case "$name" in
		apache) f="$P2S_TEMPLATE_DIR/apache-php2shell-guard.conf" ;;
		fpm) f="$P2S_TEMPLATE_DIR/php-fpm-pool-guard.conf" ;;
		ini) f="$P2S_TEMPLATE_DIR/php-ini-guard.ini" ;;
		nginx) f="$P2S_TEMPLATE_DIR/nginx-php2shell-guard.conf" ;;
		*) die "Unbekanntes Template: $name" ;;
	esac
	[ -f "$f" ] || die "Template fehlt: $f"
	cat "$f"
}

# fatal_error_backtraces existiert erst ab PHP 8.5
php_fatal_bt_value() {
	local b v
	for b in $(detect_php_binaries) $(detect_fpm_binaries); do
		IFS='|' read -r _ v <<<"$b"
		if php_has_fatal_backtraces "$v"; then
			printf '0'
			return 0
		fi
	done
	printf 'none'
}

render_template() {
	local name="$1" dest="$2" fatal_bt="$3"
	local tmp
	tmp=$(mktemp) || return 1
	tpl_content "$name" |
		sed -e "s|@POST_MAX@|$P2S_POST_MAX|g" \
			-e "s|@UPLOAD_MAX@|$P2S_UPLOAD_MAX|g" \
			-e "s|@MAX_NESTING@|$P2S_MAX_NESTING|g" \
			-e "s|@MAX_INPUT_VARS@|$P2S_MAX_INPUT_VARS|g" \
			-e "s|@MAX_FILE_UPLOADS@|$P2S_MAX_FILE_UPLOADS|g" \
			-e "s|@LIMIT_REQUEST_BODY@|$P2S_LIMIT_REQUEST_BODY|g" \
			-e "s|@LIMIT_REQUEST_FIELDS@|$P2S_LIMIT_REQUEST_FIELDS|g" \
			-e "s|@LIMIT_REQUEST_FIELD_SIZE@|$P2S_LIMIT_REQUEST_FIELD_SIZE|g" \
			-e "s|@FATAL_BACKTRACES@|$fatal_bt|g" >"$tmp"
	if [ "$fatal_bt" != "0" ]; then
		grep -v 'fatal_error_backtraces' "$tmp" >"$tmp.2" && mv "$tmp.2" "$tmp"
	fi
	cat "$tmp" >"$dest"
	rm -f "$tmp"
	return 0
}

apache_dropin_path() {
	if [ -d "${P2S_CONF_ROOT}"/etc/apache2/conf-available ]; then
		printf '%s/etc/apache2/conf-available/php2shell-guard.conf' "$P2S_CONF_ROOT"
	elif [ -d "${P2S_CONF_ROOT}"/etc/httpd/conf.d ]; then
		printf '%s/etc/httpd/conf.d/php2shell-guard.conf' "$P2S_CONF_ROOT"
	else
		printf ''
	fi
}

apache_restart_cmd() {
	local ctl
	ctl=$(apache_ctl)
	if [ -n "$ctl" ] && command -v systemctl >/dev/null 2>&1; then
		if systemctl list-unit-files apache2.service >/dev/null 2>&1; then
			printf 'systemctl reload apache2.service'
		elif systemctl list-unit-files httpd.service >/dev/null 2>&1; then
			printf 'systemctl reload httpd.service'
		else
			printf '%s graceful' "$ctl"
		fi
	elif [ -n "$ctl" ]; then
		printf '%s graceful' "$ctl"
	else
		printf ''
	fi
}

fpm_services() {
	local s
	for s in $(systemctl list-units --type=service --all --no-legend 2>/dev/null | awk '{print $1}' | grep -iE '^php.*fpm' | sort -u); do
		printf '%s\n' "$s"
	done
	for s in php-fpm.service php8.3-fpm.service php8.2-fpm.service; do
		if systemctl list-unit-files "$s" >/dev/null 2>&1; then
			printf '%s\n' "$s"
		fi
	done
	return 0
}

fpm_reload_services() {
	local s
	for s in $(fpm_services); do
		if systemctl cat "$s" >/dev/null 2>&1; then
			printf '%s\n' "$s"
		fi
	done
	return 0
}

# Verwalteten Block in eine FPM-Pool-Datei einfügen (pro Pool-Sektion, Reihenfolge bleibt erhalten)
fpm_upsert_pool() {
	local pool="$1" block="$2"
	local tmp
	tmp=$(mktemp) || return 1
	awk -v cfile="$block" '
		function flush(   i, out, skip) {
			if (!in_section) return
			out = ""
			skip = 0
			for (i = 1; i <= n; i++) {
				if (content[i] == "; >>> php2shell-guard >>>") { skip = 1; continue }
				if (content[i] == "; <<< php2shell-guard <<<") { skip = 0; continue }
				if (!skip) out = out content[i] "\n"
			}
			printf "%s", out
			while ((getline bl < cfile) > 0) print bl
			close(cfile)
			for (i = 1; i <= n; i++) delete content[i]
			n = 0
		}
		/^[[:space:]]*\[[^]]*\]/ {
			flush()
			in_section = 1
			print
			next
		}
		{
			if (in_section) content[++n] = $0
			else print
		}
		END { flush() }
	' "$pool" >"$tmp" || {
		rm -f "$tmp"
		return 1
	}
	cat "$tmp" >"$pool"
	rm -f "$tmp"
	return 0
}

mitigate_mod_php() {
	local fatal_bt="$1"
	local dest
	dest=$(apache_dropin_path)
	if [ -z "$dest" ]; then
		log_warn "Kein Apache-Konfigurationsverzeichnis gefunden — mod_php Mitigation übersprungen."
		return 1
	fi
	log_step "mod_php: Apache-Drop-in schreiben ($dest)"
	if is_true "$P2S_DRY_RUN"; then
		log_dry "would write $dest"
		return 0
	fi
	file_backup "$dest"
	render_template apache "$dest" "$fatal_bt"
	if [ -d "${P2S_CONF_ROOT}"/etc/apache2/conf-available ] && command -v a2enconf >/dev/null 2>&1; then
		if a2enconf php2shell-guard >/dev/null 2>&1; then
			log_ok "a2enconf php2shell-guard aktiviert"
		fi
	fi
	local ctl
	ctl=$(apache_ctl)
	if [ -n "$ctl" ]; then
		if "$ctl" -t >/dev/null 2>&1; then
			log_ok "Apache-Konfiguration gültig"
		else
			log_err "Apache-Konfiguration ungültig — $dest zurückrollen!"
			return 1
		fi
	fi
	return 0
}

mitigate_fpm() {
	local fatal_bt="$1"
	local pools
	pools=$(fpm_pool_files | sort -u)
	if [ -z "$pools" ]; then
		log_warn "Keine PHP-FPM-Pool-Dateien gefunden — FPM Mitigation übersprungen."
		return 1
	fi
	local block body
	block=$(mktemp) || return 1
	body=$(mktemp) || {
		rm -f "$block"
		return 1
	}
	# Nicht nach /dev/stdout schreiben: unter Linux ist das /proc/self/fd/1.
	# Liegt stdout schon auf einer Datei, oeffnet ">" diese Datei mit O_TRUNC
	# und loescht den Start-Marker, bevor der Block in den Pool wandert.
	if ! render_template fpm "$body" "$fatal_bt"; then
		rm -f "$block" "$body"
		return 1
	fi
	{
		printf '; >>> php2shell-guard >>>\n'
		cat "$body"
		printf '; <<< php2shell-guard <<<\n'
	} >"$block"
	rm -f "$body"
	local p
	for p in $pools; do
		log_step "FPM: Pool aktualisieren ($p)"
		if is_true "$P2S_DRY_RUN"; then
			log_dry "would patch $p"
			continue
		fi
		file_backup "$p"
		if fpm_upsert_pool "$p" "$block"; then
			log_ok "Pool aktualisiert: $p"
		else
			log_err "Pool konnte nicht aktualisiert werden: $p"
		fi
	done
	rm -f "$block"
	return 0
}

mitigate_cgi() {
	local fatal_bt="$1"
	local d dest
	for d in "${P2S_CONF_ROOT}"/etc/php/*/cgi/conf.d; do
		[ -d "$d" ] || continue
		dest="$d/99-php2shell-guard.ini"
		log_step "CGI: php.ini-Drop-in schreiben ($dest)"
		if is_true "$P2S_DRY_RUN"; then
			log_dry "would write $dest"
			continue
		fi
		file_backup "$dest"
		render_template ini "$dest" "$fatal_bt"
		log_ok "CGI-Konfiguration aktualisiert: $dest"
	done
	if [ -d "${P2S_CONF_ROOT}"/etc/php.d ]; then
		dest="${P2S_CONF_ROOT}/etc/php.d/99-php2shell-guard.ini"
		log_step "CGI: php.ini-Drop-in schreiben ($dest)"
		if is_true "$P2S_DRY_RUN"; then
			log_dry "would write $dest"
		else
			file_backup "$dest"
			render_template ini "$dest" "$fatal_bt"
			log_ok "CGI-Konfiguration aktualisiert: $dest"
		fi
	fi
	return 0
}

mitigate_nginx() {
	local fatal_bt="$1"
	if [ ! -d "${P2S_CONF_ROOT}"/etc/nginx/conf.d ]; then
		return 1
	fi
	local dest="${P2S_CONF_ROOT}/etc/nginx/conf.d/php2shell-guard.conf"
	log_step "nginx: Drop-in schreiben ($dest)"
	if is_true "$P2S_DRY_RUN"; then
		log_dry "would write $dest"
		return 0
	fi
	file_backup "$dest"
	render_template nginx "$dest" "$fatal_bt"
	if command -v nginx >/dev/null 2>&1; then
		if nginx -t >/dev/null 2>&1; then
			log_ok "nginx-Konfiguration gültig"
		else
			log_err "nginx-Konfiguration ungültig — $dest zurückrollen!"
			return 1
		fi
	fi
	return 0
}

# systemd cgroup-Grenze als Verfügbarkeitsgrenze (NICHT RLIMIT_AS/RLIMIT_DATA)
apply_cgroup_limit() {
	local svc="$1" mb="$2"
	if [ -z "$mb" ]; then
		return 0
	fi
	local dir="/etc/systemd/system/${svc}.d"
	local dest="$dir/php2shell-guard.conf"
	log_step "cgroup: MemoryMax=${mb}M für $svc"
	if is_true "$P2S_DRY_RUN"; then
		log_dry "would write $dest"
		return 0
	fi
	mkdir -p "$dir"
	cat >"$dest" <<EOF
# php2shell-guard: Verfügbarkeitsgrenze gegen unbegrenzte Allokation (memory_limit=-1).
# WICHTIG: Kein LimitAddressSpace/LimitData setzen — das erzeugt Allocation-Fehler
# und könnte den betroffenen Pfad erneut auslösen.
[Service]
MemoryMax=${mb}M
EOF
	systemctl daemon-reload >/dev/null 2>&1
	log_ok "cgroup-Limit gesetzt: $dest"
	return 0
}

restart_workers() {
	local svc cmd
	for svc in $(fpm_reload_services); do
		log_step "FPM neu starten: $svc"
		if is_true "$P2S_DRY_RUN"; then
			log_dry "would reload $svc"
			continue
		fi
		if systemctl reload "$svc" >/dev/null 2>&1; then
			log_ok "$svc neu geladen (Worker ersetzt)"
		elif systemctl restart "$svc" >/dev/null 2>&1; then
			log_ok "$svc neu gestartet (Worker ersetzt)"
		else
			log_warn "$svc konnte nicht neu geladen werden — manueller Restart nötig!"
		fi
	done
	cmd=$(apache_restart_cmd)
	if [ -n "$cmd" ]; then
		log_step "Apache neu laden: $cmd"
		if is_true "$P2S_DRY_RUN"; then
			log_dry "would run $cmd"
		else
			if $cmd >/dev/null 2>&1; then
				log_ok "Apache neu geladen (mod_php Worker ersetzt)"
			else
				log_err "Apache-Reload fehlgeschlagen — bitte prüfen!"
			fi
		fi
	fi
	if [ "$(detect_nginx)" = "yes" ] && command -v systemctl >/dev/null 2>&1; then
		if systemctl list-unit-files nginx.service >/dev/null 2>&1; then
			log_step "nginx neu laden"
			if is_true "$P2S_DRY_RUN"; then
				log_dry "would reload nginx"
			elif systemctl reload nginx >/dev/null 2>&1; then
				log_ok "nginx neu geladen"
			else
				log_warn "nginx-Reload fehlgeschlagen"
			fi
		fi
	fi
	return 0
}

# App-Level-Overrides (php_value) neutralisieren
fix_overrides() {
	local changed=0
	local f
	for f in $(apache_conf_files); do
		if ! grep -qiE '^[[:space:]]*php_value[[:space:]]+(memory_limit|session\.upload_progress\.enabled)' "$f" 2>/dev/null; then
			continue
		fi
		log_warn "App-Level-Override gefunden in $f:"
		grep -inE '^[[:space:]]*php_value[[:space:]]+(memory_limit|session\.upload_progress\.enabled)' "$f" 2>/dev/null | sed 's/^/      /'
		if is_true "$P2S_DRY_RUN"; then
			continue
		fi
		file_backup "$f"
		sed -i.tmp \
			-e 's/^\([[:space:]]*\)php_value[[:space:]]\+memory_limit\(.*\)$/\1php_admin_value memory_limit -1\2/' \
			-e 's/^\([[:space:]]*\)php_value[[:space:]]\+session\.upload_progress\.enabled\(.*\)$/\1php_admin_value session.upload_progress.enabled 0\2/' \
			"$f"
		mv -f "$f.tmp" "$f"
		changed=1
		log_ok "Overrides in $f auf php_admin_value umgestellt"
	done
	return $changed
}

cmd_mitigate() {
	local fix_overrides_flag=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--fix-overrides) fix_overrides_flag=1 ;;
			--dry-run) P2S_DRY_RUN=1 ;;
			--yes) P2S_ASSUME_YES=1 ;;
			--post-max)
				P2S_POST_MAX="$2"
				shift
				;;
			--upload-max)
				P2S_UPLOAD_MAX="$2"
				shift
				;;
			--cgroup-limit)
				P2S_CGROUP_LIMIT_MB="$2"
				shift
				;;
			--json) P2S_JSON=1 ;;
			*) die "Unbekannte Option für mitigate: $1" ;;
		esac
		shift
	done
	# confirm() und andere Befehle lesen die Flags; in dieser Datei gibt es keinen weiteren Leser.
	: "$P2S_ASSUME_YES" "$P2S_JSON"

	log_step "PHP2Shell-Mitigation auf $(host_label)"
	log_warn "Diese Maßnahmen sind temporär. Das Update auf eine gepatchte PHP-Version bleibt Pflicht."
	log ""

	local fatal_bt
	fatal_bt=$(php_fatal_bt_value)
	log_info "post_max_size=$P2S_POST_MAX upload_max_filesize=$P2S_UPLOAD_MAX fatal_error_backtraces=$fatal_bt"

	require_root

	local mod_php cgi nginx fpm_found applied=""
	mod_php=$(detect_mod_php)
	cgi=$(detect_cgi)
	nginx=$(detect_nginx)
	fpm_found=0
	if [ -n "$(detect_fpm_binaries)" ]; then
		fpm_found=1
	fi
	if [ "$fpm_found" = "0" ] && ls -d /etc/php/*/fpm >/dev/null 2>&1; then
		fpm_found=1
	fi

	if [ "$mod_php" = "yes" ]; then
		if mitigate_mod_php "$fatal_bt"; then applied="$applied mod_php"; fi
	fi
	if [ "$fpm_found" = "1" ]; then
		if mitigate_fpm "$fatal_bt"; then applied="$applied fpm"; fi
	fi
	if [ "$cgi" = "yes" ] && [ "$mod_php" = "no" ] && [ "$fpm_found" = "0" ]; then
		if mitigate_cgi "$fatal_bt"; then applied="$applied cgi"; fi
	fi
	if [ "$nginx" = "yes" ]; then
		if mitigate_nginx "$fatal_bt"; then applied="$applied nginx"; fi
	fi

	if [ "$fix_overrides_flag" = "1" ]; then
		log_step "App-Level-Overrides prüfen/neutralisieren"
		fix_overrides || true
	fi

	log_step "Worker neu starten (Pflicht: stale state lebt im Worker-Prozess)"
	restart_workers

	if [ -n "$P2S_CGROUP_LIMIT_MB" ]; then
		local svc
		for svc in $(fpm_reload_services); do
			apply_cgroup_limit "$svc" "$P2S_CGROUP_LIMIT_MB"
		done
	fi

	log ""
	log_ok "Mitigation angewendet: ${applied:-keine SAPI erkannt}"
	log_warn "Verbleibend: PHP-Update durchführen (php2shell-guard patch) und Kompromittierung prüfen (php2shell-guard ioc)."
	return 0
}

cmd_templates() {
	local which="${1:-all}"
	case "$which" in
		apache | fpm | ini | nginx)
			tpl_content "$which"
			;;
		all)
			local t
			for t in apache fpm ini nginx; do
				printf '\n===== %s =====\n' "$t"
				tpl_content "$t"
			done
			;;
		*) die "Unbekanntes Template: $which" ;;
	esac
}
