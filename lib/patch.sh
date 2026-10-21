#!/usr/bin/env bash
# shellcheck shell=bash
# php2shell-guard — Paket-Updates (der eigentliche Fix)

installed_php_packages() {
	case "$(pkg_manager)" in
	apt)
		dpkg-query -W -f='${Package} ${Version}\n' 'php*' 2>/dev/null | grep -i php || true
		;;
	dnf | yum)
		rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' 2>/dev/null | grep -i php || true
		;;
	apk)
		apk info -v 2>/dev/null | grep -i php || true
		;;
	zypper)
		rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\n' 2>/dev/null | grep -i php || true
		;;
	*)
		printf ''
		;;
	esac
}

upgradable_php_packages() {
	case "$(pkg_manager)" in
	apt)
		apt-get -s -q upgrade 2>/dev/null | awk '/^Inst php/ {print $2}' | sort -u || true
		;;
	dnf)
		dnf -q list --upgrades 2>/dev/null | awk 'NR>2 && tolower($1) ~ /^php/ {print $1}' | sort -u || true
		;;
	yum)
		yum -q list updates 2>/dev/null | awk 'NR>2 && tolower($1) ~ /^php/ {print $1}' | sort -u || true
		;;
	apk)
		apk upgrade --simulate 2>/dev/null | awk 'tolower($0) ~ /^php/ {print $1}' | sort -u || true
		;;
	zypper)
		zypper --non-interactive list-updates 2>/dev/null | awk 'tolower($2) ~ /^php/ {print $2}' | sort -u || true
		;;
	*)
		printf ''
		;;
	esac
}

has_sury_repo() {
	if [ -d /etc/apt/sources.list.d ] && ls /etc/apt/sources.list.d/*sury* >/dev/null 2>&1; then
		printf 'yes'
		return 0
	fi
	if grep -qs 'packages.sury.org' /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null; then
		printf 'yes'
		return 0
	fi
	printf 'no'
}

apply_upgrade() {
	local pkgs="$*"
	if [ -z "$pkgs" ]; then
		log_info "Keine aktualisierbaren PHP-Pakete gefunden."
		return 0
	fi
	log_step "Update ausführen: $pkgs"
	if is_true "$P2S_DRY_RUN"; then
		log_dry "would upgrade $pkgs"
		return 0
	fi
	local pm
	pm=$(pkg_manager)
	case "$pm" in
	apt)
		DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade $pkgs || return 1
		;;
	dnf | yum)
		"$pm" -y upgrade $pkgs || return 1
		;;
	apk)
		apk upgrade $pkgs || return 1
		;;
	zypper)
		zypper --non-interactive update $pkgs || return 1
		;;
	*)
		log_err "Paketmanager nicht unterstützt: $pm"
		return 1
		;;
	esac
	return 0
}

cmd_patch() {
	local apply=0
	while [ $# -gt 0 ]; do
		case "$1" in
		--apply) apply=1 ;;
		--dry-run) P2S_DRY_RUN=1 ;;
		--yes) P2S_ASSUME_YES=1 ;;
		--json) P2S_JSON=1 ;;
		*) die "Unbekannte Option für patch: $1" ;;
		esac
		shift
	done

	log_step "PHP-Update-Prüfung auf $(host_label)"

	local pm
	pm=$(pkg_manager)
	log_info "Paketmanager: $pm | OS: $(os_id) $(os_version)"
	if [ "$pm" = "apt" ]; then
		log_info "Sury-Repo: $(has_sury_repo) (falls nein: https://packages.sury.org/php für aktuelle Versionen)"
	fi

	local installed upgradable
	installed=$(installed_php_packages)
	upgradable=$(upgradable_php_packages)

	if [ -z "$installed" ]; then
		log_warn "Keine PHP-Pakete gefunden — nichts zu tun."
		return 0
	fi

	log ""
	log_info "Installierte PHP-Pakete:"
	printf '%s\n' "$installed" | sed 's/^/      /'

	log ""
	if [ -n "$upgradable" ]; then
		log_warn "Verfügbare Updates:"
		printf '%s\n' "$upgradable" | sed 's/^/      /'
	else
		log_ok "Keine ausstehenden PHP-Pakete-Updates im Paketmanager."
	fi

	# EOL-Branche mit Warnung versehen
	local b v
	for b in $(detect_php_binaries) $(detect_fpm_binaries); do
		IFS='|' read -r _ v <<<"$b"
		local branch fixed
		branch=$(ver_branch "$v")
		fixed=$(php_fixed_min_version "$branch")
		if [ -z "$fixed" ]; then
			log_warn "PHP-Branch $branch ist EOL — kein Upstream-Fix verfügbar."
			log_warn "  Optionen: Migration auf 8.2+ (8.2.35) oder Source-Backport php-src/PHP-${branch}-CVE-2026-109618-109619."
		fi
	done

	if [ "$apply" != "1" ]; then
		log ""
		log_info "Nur Prüfung. Mit '--apply' werden die Updates installiert."
		return 0
	fi

	require_root
	if ! confirm "Updates jetzt installieren?"; then
		log_info "Abgebrochen."
		return 0
	fi

	if ! apply_upgrade $upgradable; then
		log_err "Update fehlgeschlagen."
		return 1
	fi

	log_step "Dienste neu starten"
	restart_workers

	log ""
	log_ok "Update abgeschlossen. Gegenprobe mit 'php2shell-guard scan' und 'php2shell-guard verify'."
	return 0
}
