#!/usr/bin/env bash
# shellcheck shell=bash
# php2shell-guard — Auswertung/Reporting über mehrere Hosts

json_field() {
	local obj="$1" key="$2"
	printf '%s' "$obj" | sed -n "s/.*\"${key}\":\([^,}]*\).*/\1/p" | head -1 | sed -e 's/^"//' -e 's/"$//'
}

json_top_field() {
	local f="$1" key="$2"
	local v
	v=$(tr -d '\n' <"$f" | sed -n "s/.*\"${key}\":\"\([^\"]*\)\".*/\1/p" | head -1)
	if [ -z "$v" ]; then
		v=$(tr -d '\n' <"$f" | sed -n "s/.*\"${key}\":\([^,}]*\).*/\1/p" | head -1)
	fi
	printf '%s' "$v"
}

json_install_rows() {
	local f="$1"
	tr -d '\n' <"$f" |
		sed 's/.*"installs":\[//' | sed 's/\].*//' |
		tr '{' '\n' |
		while IFS= read -r obj || [ -n "$obj" ]; do
			[ -n "$obj" ] || continue
			printf '%s|%s|%s|%s|%s\n' \
				"$(json_field "$obj" sapi)" \
				"$(json_field "$obj" php_version)" \
				"$(json_field "$obj" patched)" \
				"$(json_field "$obj" mitigation)" \
				"$(json_field "$obj" risk)"
		done
}

cmd_report() {
	local out_md=""
	local out_csv=""
	local files=()
	while [ $# -gt 0 ]; do
		case "$1" in
		--out)
			out_md="$2"
			shift
			;;
		--csv)
			out_csv="$2"
			shift
			;;
		*) files+=("$1") ;;
		esac
		shift
	done

	if [ "${#files[@]}" -eq 0 ]; then
		files=(*.json)
	fi

	local f
	local total=0 crit=0 patched=0 mitigated=0
	local md=""

	md_add() { md="$md$1"$'\n'; }

	md_add "# PHP2Shell-Fleet-Report"
	md_add ""
	md_add "Zeitpunkt: $(ts_utc)"
	md_add ""

	for f in "${files[@]}"; do
		[ -f "$f" ] || continue
		[ -s "$f" ] || continue
		grep -q '"tool":"php2shell-guard"' "$f" 2>/dev/null || continue
		local host
		host=$(json_top_field "$f" host)
		[ -z "$host" ] && host=$(basename "$f" .json)
		md_add "| Host | SAPI | PHP-Version | Gepatcht | Mitigation | Risiko |"
		md_add "|---|---|---|---|---|---|"
		local rows
		rows=$(json_install_rows "$f")
		if [ -z "$rows" ]; then
			md_add "| $host | - | - | - | - | keine PHP-Installation |"
		fi
		while IFS='|' read -r sapi ver pat mit risk; do
			[ -n "$sapi" ] || continue
			total=$((total + 1))
			case "$risk" in
			critical) crit=$((crit + 1)) ;;
			medium) mitigated=$((mitigated + 1)) ;;
			low) patched=$((patched + 1)) ;;
			esac
			md_add "| $host | $sapi | $ver | $pat | $mit | $risk |"
		done <<EOF
$rows
EOF
		md_add ""
	done

	md_add "## Zusammenfassung"
	md_add ""
	md_add "- PHP-Installationen gesamt: $total"
	md_add "- Gepatcht (Risiko low): $patched"
	md_add "- Nur gemitigiert (Risiko medium, Update Pflicht): $mitigated"
	md_add "- Ungepatcht ohne wirksame Mitigation (Risiko critical): $crit"
	md_add ""
	if [ "$crit" -gt 0 ]; then
		md_add "> **Handlungsbedarf:** $crit Installation(en) sind ungepatcht und nicht wirksam gemitigert."
		md_add "> Zuerst \`php2shell-guard mitigate\`, danach \`php2shell-guard patch --apply\`."
	fi

	if [ -n "$out_md" ]; then
		printf '%s' "$md" >"$out_md"
		log_ok "Report geschrieben: $out_md"
	else
		printf '%s' "$md"
	fi

	if [ -n "$out_csv" ]; then
		printf 'host,sapi,php_version,patched,mitigation,risk\n' >"$out_csv"
		for f in "${files[@]}"; do
			[ -f "$f" ] || continue
			[ -s "$f" ] || continue
			grep -q '"tool":"php2shell-guard"' "$f" 2>/dev/null || continue
			local host
			host=$(json_top_field "$f" host)
			[ -z "$host" ] && host=$(basename "$f" .json)
			local rows
			rows=$(json_install_rows "$f")
			while IFS='|' read -r sapi ver pat mit risk; do
				[ -n "$sapi" ] || continue
				printf '%s,%s,%s,%s,%s,%s\n' "$host" "$sapi" "$ver" "$pat" "$mit" "$risk" >>"$out_csv"
			done <<EOF
$rows
EOF
		done
		log_ok "CSV geschrieben: $out_csv"
	fi

	[ "$crit" -gt 0 ] && return 2
	return 0
}
