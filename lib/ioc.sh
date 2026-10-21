#!/usr/bin/env bash
# shellcheck shell=bash
# php2shell-guard — Kompromittierungs-Indikatoren (IOC-Scan)

P2S_EXCLUDE_RE="/(vendor|node_modules|\.git|storage/framework|storage/logs|var/cache|backup|\.idea)/"

ioc_find_recent_php() {
	local root="$1" days="$2"
	find "$root" -type f -name '*.php' -mtime -"$days" 2>/dev/null |
		grep -vE "$P2S_EXCLUDE_RE" |
		head -500
	return 0
}

ioc_find_patterns() {
	local root="$1"
	local f
	for f in $(grep -rlE --include='*.php' \
		-e 'eval[[:space:]]*\([[:space:]]*(base64_decode|gzinflate|gzuncompress|str_rot13|hex2bin|assert)[[:space:]]*\(' \
		-e '(assert|system|exec|shell_exec|passthru|popen|proc_open)[[:space:]]*\([[:space:]]*\$_(POST|GET|REQUEST|COOKIE|SERVER)' \
		-e 'preg_replace[[:space:]]*\(.*/[a-zA-Z]*e[a-zA-Z]*["'"'"']' \
		-e 'create_function[[:space:]]*\([[:space:]]*(base64_decode|eval)' \
		-e '(system|shell_exec|passthru|popen|proc_open)[[:space:]]*\([[:space:]]*(base64_decode|gzinflate)' \
		-e '(move_uploaded_file|file_put_contents|fwrite)[[:space:]]*\([^)]*\.p?hp[0-9]*' \
		-e '\$\{?_[A-Za-z]+\}?[[:space:]]*=[[:space:]]*(base64_decode|hex2bin)[[:space:]]*\([[:space:]]*["'"'"']?[A-Za-z0-9+/=]{40,}' \
		-e '(chr[[:space:]]*\([[:space:]]*[0-9]+[[:space:]]*\)[[:space:]]*\.){4,}' \
		"$root" 2>/dev/null | grep -vE "$P2S_EXCLUDE_RE" | head -200); do
		printf '%s\n' "$f"
	done
	return 0
}

ioc_find_embedded_php() {
	local root="$1"
	find "$root" -type f \( -name '*.jpg' -o -name '*.jpeg' -o -name '*.png' -o -name '*.gif' -o -name '*.txt' -o -name '*.zip' \) \
		-exec grep -lE '<\?php|<\?=eval' {} + 2>/dev/null | grep -vE "$P2S_EXCLUDE_RE" | head -50
	return 0
}

ioc_find_web_ini() {
	local root="$1"
	find "$root" -maxdepth 3 -type f \( -name 'php.ini' -o -name '.user.ini' -o -name '.htaccess' \) 2>/dev/null |
		grep -vE "$P2S_EXCLUDE_RE" | head -50
	return 0
}

ioc_find_world_writable() {
	local root="$1"
	find "$root" -type f -name '*.php' -perm -0002 2>/dev/null | grep -vE "$P2S_EXCLUDE_RE" | head -50
	return 0
}

ioc_check_logs() {
	local logdir
	for logdir in /var/log/apache2 /var/log/httpd /var/log/nginx; do
		[ -d "$logdir" ] || continue
		local f
		for f in "$logdir"/*access*.log "$logdir"/access.log; do
			[ -f "$f" ] || continue
			local n
			n=$(grep -c 'PHP_SESSION_UPLOAD_PROGRESS' "$f" 2>/dev/null || true)
			if [ "${n:-0}" -gt 0 ]; then
				printf 'HOCH\tlog-session-upload-progress\t%s\t%s Treffer PHP_SESSION_UPLOAD_PROGRESS\n' "$f" "$n"
			fi
			local m
			m=$(grep -cE 'Allowed memory size|Maximum execution time|Segmentation fault' "$f" 2>/dev/null || true)
			if [ "${m:-0}" -gt 0 ]; then
				printf 'MITTEL\tlog-oom-timeout\t%s\t%s Treffer OOM/Timeout/Fatal\n' "$f" "$m"
			fi
		done
	done
}

cmd_ioc() {
	local since_days=14
	local max_files=500
	while [ $# -gt 0 ]; do
		case "$1" in
		--since-days)
			since_days="$2"
			shift
			;;
		--max-files)
			max_files="$2"
			shift
			;;
		--json) P2S_JSON=1 ;;
		*) die "Unbekannte Option für ioc: $1" ;;
		esac
		shift
	done

	log_step "IOC-Scan (Kompromittierungs-Indikatoren) auf $(host_label)"
	log_info "Zeitfenster für 'kürzlich geändert': ${since_days} Tage"

	local roots
	roots=$(detect_web_roots | sort -u)
	if [ -z "$roots" ]; then
		log_warn "Keine Web-Roots gefunden — IOC-Scan wird übersprungen."
		return 0
	fi
	log_info "Geprüfte Roots: $(printf '%s' "$roots" | tr '\n' ' ')"

	local findings=""
	local root f
	local scanned=0

	for root in $roots; do
		[ -d "$root" ] || continue
		for f in $(ioc_find_patterns "$root"); do
			findings="$findings KRITISCH\twebshell-muster\t$f\tverdächtiger PHP-Code (eval/exec mit Request-Daten oder base64)\n"
			scanned=$((scanned + 1))
		done
		for f in $(ioc_find_embedded_php "$root"); do
			findings="$findings KRITISCH\tphp-in-binary\t$f\tPHP-Code in Nicht-PHP-Datei\n"
			scanned=$((scanned + 1))
		done
		for f in $(ioc_find_web_ini "$root"); do
			findings="$findings HOCH\tweb-konfiguration\t$f\tphp.ini/.user.ini/.htaccess im Web-Root (Konfigurations-Hijacking möglich)\n"
			scanned=$((scanned + 1))
		done
		for f in $(ioc_find_world_writable "$root"); do
			findings="$findings HOCH\tworld-writable\t$f\tPHP-Datei für alle Benutzer schreibbar\n"
			scanned=$((scanned + 1))
		done
		for f in $(ioc_find_recent_php "$root" "$since_days" | head -"$max_files"); do
			findings="$findings MITTEL\tzuletzt-geaendert\t$f\tPHP-Datei innerhalb von ${since_days} Tagen geändert\n"
			scanned=$((scanned + 1))
		done
	done

	local log_findings
	log_findings=$(ioc_check_logs)
	if [ -n "$log_findings" ]; then
		findings="$findings$log_findings\n"
	fi

	if is_true "$P2S_JSON"; then
		printf '{"tool":"php2shell-guard","host":"%s","timestamp":"%s","findings":[' "$(json_str "$(host_label)")" "$(ts_utc)"
		local first=1 line sev typ path detail
		while IFS=$'\t' read -r sev typ path detail; do
			[ -n "$sev" ] || continue
			if [ "$first" = "0" ]; then printf ','; fi
			first=0
			printf '{"severity":"%s","type":"%s","path":"%s","detail":"%s"}' \
				"$(json_str "$sev")" "$(json_str "$typ")" "$(json_str "$path")" "$(json_str "$detail")"
		done <<EOF
$(printf '%b' "$findings")
EOF
		printf ']}\n'
		return 0
	fi

	if [ -z "$findings" ]; then
		log ""
		log_ok "Keine bekannten Indikatoren gefunden — das ist kein Beweis für Sicherheit."
		return 0
	fi

	log ""
	log_warn "$scanned Indikator(en) gefunden:"
	printf '%b' "$findings" | sort -u | while IFS=$'\t' read -r sev typ path detail; do
		[ -n "$sev" ] || continue
		printf '  [%-8s] %-24s %s\n' "$sev" "$typ" "$path"
		if [ -n "$detail" ]; then
			printf '             %s\n' "$detail"
		fi
	done
	log ""
	log_err "Bei KRITISCH-Treffern: Host isolieren, Logs forensisch sichern und System neu aufsetzen."
	return 1
}
