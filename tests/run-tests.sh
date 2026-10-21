#!/usr/bin/env bash
# php2shell-guard — Testsuite (reines Bash, keine externen Abhängigkeiten)
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FIX="$ROOT/tests/fixtures"
PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/detect.sh
. "$ROOT/lib/detect.sh"
# shellcheck source=lib/mitigate.sh
. "$ROOT/lib/mitigate.sh"
# shellcheck source=lib/report.sh
. "$ROOT/lib/report.sh"
# shellcheck source=lib/verify.sh
. "$ROOT/lib/verify.sh"
# shellcheck source=lib/ioc.sh
. "$ROOT/lib/ioc.sh"

ok() {
	PASS=$((PASS + 1))
	printf '  [PASS] %s\n' "$1"
}

ko() {
	FAIL=$((FAIL + 1))
	printf '  [FAIL] %s — %s\n' "$1" "${2:-}"
}

assert_eq() {
	local name="$1" expected="$2" actual="$3"
	if [ "$expected" = "$actual" ]; then
		ok "$name"
	else
		ko "$name" "erwartet='$expected' war='$actual'"
	fi
}

assert_true() {
	local name="$1"
	shift
	if "$@"; then ok "$name"; else ko "$name" "Befehl fehlgeschlagen: $*"; fi
}

assert_false() {
	local name="$1"
	shift
	if "$@"; then ko "$name" "Befehl sollte fehlschlagen: $*"; else ok "$name"; fi
}

assert_contains() {
	local name="$1" haystack="$2" needle="$3"
	case "$haystack" in
	*"$needle"*) ok "$name" ;;
	*) ko "$name" "'$needle' nicht gefunden" ;;
	esac
}

json_valid() {
	if command -v python3 >/dev/null 2>&1; then
		python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$1" 2>/dev/null
	else
		return 0
	fi
}

section() {
	printf '\n== %s ==\n' "$1"
}

section "Versionslogik"
assert_true "ver_ge 8.5.12 >= 8.5.12" ver_ge 8.5.12 8.5.12
assert_false "ver_ge 8.5.11 >= 8.5.12" ver_ge 8.5.11 8.5.12
assert_true "ver_ge 8.4.27 >= 8.4.27" ver_ge 8.4.27 8.4.27
assert_true "ver_ge 8.3.36 >= 8.3.36" ver_ge 8.3.36 8.3.36
assert_true "ver_ge 8.2.35 >= 8.2.35" ver_ge 8.2.35 8.2.35
assert_true "ver_ge mit Distro-Suffix" ver_ge 8.5.12-1+deb12u1 8.5.12
assert_true "ver_ge 8.10.0 >= 8.9.0" ver_ge 8.10.0 8.9.0
assert_eq "ver_branch 8.1.2-1ubuntu2.27" "8.1" "$(ver_branch 8.1.2-1ubuntu2.27)"
assert_eq "ver_branch 8.5.12" "8.5" "$(ver_branch 8.5.12)"

section "Patch-Status je Branch"
assert_true "8.5.12 gepatcht" php_version_patched 8.5.12 8.5
assert_false "8.5.11 ungepatcht" php_version_patched 8.5.11 8.5
assert_true "8.4.27 gepatcht" php_version_patched 8.4.27 8.4
assert_true "8.3.36 gepatcht" php_version_patched 8.3.36 8.3
assert_true "8.2.35 gepatcht" php_version_patched 8.2.35 8.2
assert_false "8.1.2 EOL ohne Upstream-Fix" php_version_patched 8.1.2 8.1
assert_false "7.4.33 EOL ohne Upstream-Fix" php_version_patched 7.4.33 7.4
assert_true "fatal_error_backtraces nur ab 8.5" php_has_fatal_backtraces 8.5.12
assert_false "fatal_error_backtraces nicht bei 8.3" php_has_fatal_backtraces 8.3.36

section "Konfigurationsauswertung"
mkdir -p "$TMP/cfg"
cat >"$TMP/cfg/a.ini" <<'EOF'
memory_limit = 512M
session.upload_progress.enabled = 1
EOF
cat >"$TMP/cfg/b.ini" <<'EOF'
memory_limit = -1
EOF
cat >"$TMP/cfg/pool.conf" <<'EOF'
[www]
listen = 127.0.0.1:9000
php_admin_value[memory_limit] = -1
php_admin_value[session.upload_progress.enabled] = 0
EOF

assert_eq "config_directive_value nimmt letzten Wert (kein Verketten)" "-1" \
	"$(config_directive_value memory_limit "$TMP/cfg/a.ini" "$TMP/cfg/b.ini")"
assert_eq "config_directive_value ini-Wert" "512M" \
	"$(config_directive_value memory_limit "$TMP/cfg/a.ini")"
assert_eq "config_admin_value erkennt php_admin_value" "admin" \
	"$(config_admin_value memory_limit "$TMP/cfg/pool.conf")"
assert_eq "config_admin_value erkennt ini" "ini" \
	"$(config_admin_value memory_limit "$TMP/cfg/a.ini")"
assert_eq "config_admin_value ohne Treffer" "none" \
	"$(config_admin_value memory_limit "$TMP/cfg/fehlt.ini")"

section "Inventar-JSON"
json=$(detect_install_json apache2handler 8.1.2-1ubuntu2.27 /usr/bin/php "$TMP/cfg/a.ini")
printf '%s' "$json" >"$TMP/inv.json"
assert_true "detect_install_json erzeugt valides JSON" json_valid "$TMP/inv.json"
assert_contains "EOL-Branch ohne Fix" "$json" '"fixed_min":""'
assert_contains "Risiko critical bei EOL" "$json" '"risk":"critical"'
assert_contains "Mitigation als missing markiert" "$json" '"mitigation":"missing"'

json=$(detect_install_json fpm 8.3.36 /usr/bin/php8.3 "$TMP/cfg/pool.conf")
printf '%s' "$json" >"$TMP/inv2.json"
assert_true "detect_install_json (fpm) valides JSON" json_valid "$TMP/inv2.json"
assert_contains "gepatchte Version -> risk low" "$json" '"risk":"low"'

json=$(detect_install_json fpm 8.3.36 /usr/bin/php8.3 "$TMP/cfg/pool.conf")
assert_contains "admin-gesicherte Mitigation erkannt" "$json" '"mitigation":"applied"'
assert_contains "Enforcement admin" "$json" '"memory_limit_enforcement":"admin"'

section "Pool-Upsert (Idempotenz und Reihenfolge)"
cp "$TMP/cfg/pool.conf" "$TMP/pool2.conf"
block="$TMP/block.conf"
printf '; >>> php2shell-guard >>>\nphp_admin_value[memory_limit] = -1\n; <<< php2shell-guard <<<\n' >"$block"
fpm_upsert_pool "$TMP/pool2.conf" "$block" >/dev/null 2>&1
fpm_upsert_pool "$TMP/pool2.conf" "$block" >/dev/null 2>&1
cnt=$(grep -c 'php2shell-guard' "$TMP/pool2.conf")
assert_eq "Pool-Block genau einmal vorhanden" "2" "$cnt"
assert_contains "Pool-Sektion erhalten" "$(cat "$TMP/pool2.conf")" "[www]"
assert_contains "原有 Zeile erhalten" "$(cat "$TMP/pool2.conf")" "listen = 127.0.0.1:9000"

section "Report-Parsing"
cat >"$TMP/report.json" <<'EOF'
{"tool":"php2shell-guard","host":"web01","installs":[{"sapi":"fpm","php_version":"8.3.36","patched":true,"mitigation":"applied","risk":"low"}]}
EOF
assert_eq "json_top_field liest host" "web01" "$(json_top_field "$TMP/report.json" host)"
assert_eq "json_install_rows liest letzte Zeile ohne Newline" \
	"fpm|8.3.36|true|applied|low" "$(json_install_rows "$TMP/report.json")"

section "IOC-Erkennung"
mkdir -p "$TMP/web"
cp "$FIX/webshell.php" "$TMP/web/webshell.php"
cp "$FIX/clean.php" "$TMP/web/clean.php"
found=$(ioc_find_patterns "$TMP/web")
assert_contains "Webshell-Muster erkannt" "$found" "webshell.php"
clean_only=$(ioc_find_patterns "$TMP/web" | grep -c 'clean.php' || true)
assert_eq "saubere Datei nicht gemeldet" "0" "$clean_only"

section "Mitigation (simulierte Umgebung)"
SIM="$TMP/sim"
mkdir -p "$SIM/etc/apache2/conf-available" "$SIM/etc/apache2/mods-enabled" \
	"$SIM/etc/php/8.3/fpm/pool.d" "$SIM/etc/php/8.3/apache2/conf.d"
cat >"$SIM/etc/php/8.3/fpm/pool.d/www.conf" <<'EOF'
[www]
user = www-data
listen = 127.0.0.1:9000
php_admin_value[memory_limit] = 128M
EOF
touch "$SIM/etc/apache2/mods-enabled/php8.3.load"
mkdir -p "$TMP/stub"
for c in systemctl apache2ctl a2enconf nginx; do
	printf '#!/bin/sh\nexit 0\n' >"$TMP/stub/$c"
	chmod +x "$TMP/stub/$c"
done
export PATH="$TMP/stub:$PATH"
export P2S_CONF_ROOT="$SIM"
export P2S_TEMPLATE_DIR="$ROOT/templates"

mitigate_mod_php 0 >/dev/null 2>&1
dropin="$SIM/etc/apache2/conf-available/php2shell-guard.conf"
if [ -f "$dropin" ]; then ok "Apache-Drop-in wird geschrieben"; else ko "Apache-Drop-in wird geschrieben" "$dropin fehlt"; fi
assert_contains "Drop-in setzt memory_limit admin-gesichert" "$(cat "$dropin" 2>/dev/null)" "php_admin_value memory_limit -1"
assert_contains "Drop-in deaktiviert session.upload_progress" "$(cat "$dropin" 2>/dev/null)" "php_admin_value session.upload_progress.enabled 0"
assert_contains "Drop-in begrenzt Request-Body" "$(cat "$dropin" 2>/dev/null)" "LimitRequestBody"
assert_contains "Drop-in enthält Request-Feld-Limit" "$(cat "$dropin" 2>/dev/null)" "LimitRequestFields"

mitigate_fpm 0 >/dev/null 2>&1
pool="$SIM/etc/php/8.3/fpm/pool.d/www.conf"
assert_contains "Pool erhält admin-gesichertes memory_limit" "$(cat "$pool" 2>/dev/null)" "php_admin_value[memory_limit] = -1"
assert_contains "Pool erhält session.upload_progress" "$(cat "$pool" 2>/dev/null)" "php_admin_value[session.upload_progress.enabled] = 0"
assert_contains "Pool-Einstellungen bleiben erhalten" "$(cat "$pool" 2>/dev/null)" "user = www-data"
poolblocks=$(grep -c '^; >>> php2shell-guard >>>' "$pool")
assert_eq "Pool-Block genau einmal" "1" "$poolblocks"
mitigate_fpm 0 >/dev/null 2>&1
poolblocks=$(grep -c '^; >>> php2shell-guard >>>' "$pool")
assert_eq "Pool-Update ist idempotent" "1" "$poolblocks"

# fatal_error_backtraces nur fuer PHP >= 8.5
mitigate_fpm none >/dev/null 2>&1
assert_eq "fatal_error_backtraces ohne 8.5 entfernt" "0" "$(grep -c 'fatal_error_backtraces' "$pool")"

export P2S_CONF_ROOT=""
export PATH="${PATH#"$TMP/stub:"}"

section "Verify (Probe-Antwort)"
probe_out='p2s_probe=1
sapi=fpm
version=8.3.36
memory_limit=-1
session.upload_progress.enabled=0
post_max_size=8M
upload_max_filesize=8M
max_input_nesting_level=16
max_input_vars=1000
max_file_uploads=10
fatal_error_backtraces=0'
assert_true "gültige Probe-Antwort wird akzeptiert" probe_response_ok "$probe_out"
assert_eq "Wert wird korrekt gelesen" "8M" "$(probe_value "$probe_out" post_max_size)"
assert_eq "Wert mit Punkt im Namen" "0" "$(probe_value "$probe_out" session.upload_progress.enabled)"
assert_false "roher PHP-Quelltext wird abgelehnt" probe_response_ok '<?php echo "p2s_probe=1"; ?>'
assert_false "leere Antwort wird abgelehnt" probe_response_ok ""

if command -v python3 >/dev/null 2>&1; then
	mkdir -p "$TMP/webserv"
	cat >"$TMP/mock_php.py" <<'PYEOF'
import http.server, socketserver, sys

BODY = b"p2s_probe=1\nsapi=apache2handler\nversion=8.1.2\nmemory_limit=512M\nsession.upload_progress.enabled=1\npost_max_size=8M\nupload_max_filesize=2M\nmax_input_nesting_level=64\nmax_input_vars=1000\nmax_file_uploads=20\n"


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)

    def log_message(self, *args):
        pass


socketserver.TCPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PYEOF
	port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
	python3 "$TMP/mock_php.py" "$port" >/dev/null 2>&1 &
	srvpid=$!
	ready=0
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		sleep 0.3
		if curl -s --max-time 2 "http://127.0.0.1:${port}/" | grep -q 'p2s_probe=1'; then
			ready=1
			break
		fi
	done
	if [ "$ready" = "1" ]; then
		out=$("$ROOT/bin/php2shell-guard" verify --docroot "$TMP/webserv" --url "http://127.0.0.1:${port}/" 2>&1)
		rc=$?
		assert_contains "verify meldet nicht wirksames memory_limit" "$out" "memory_limit"
		assert_contains "verify erkennt PHP-Version" "$out" "8.1.2"
		assert_contains "verify meldet Fehlgeschlagene Prüfungen" "$out" "Prüfung"
		assert_true "verify meldet Fehler bei fehlender Mitigation (rc != 0)" test "$rc" -ne 0
		if ls "$TMP/webserv"/__p2s_probe_*.php >/dev/null 2>&1; then
			ko "Probe-Datei wird wieder entfernt" "Datei liegt noch im Web-Root"
		else
			ok "Probe-Datei wird wieder entfernt"
		fi
	else
		printf '  [SKIP] verify-HTTP-Test (Mock-Server nicht startbar)\n'
	fi
	kill "$srvpid" >/dev/null 2>&1
else
	printf '  [SKIP] verify-HTTP-Test (python3 nicht verfügbar)\n'
fi

section "sed-Portabilität (BSD/GNU)"
if grep -rnE "sed [^|]*\\\\\|" "$ROOT/lib" "$ROOT/bin" >/dev/null 2>&1; then
	ko "keine BRE-Alternation (\\|) in sed-Ausdrücken" "gefunden"
else
	ok "keine BRE-Alternation (\\|) in sed-Ausdrücken"
fi

section "Pipeline-Rückgabewerte (set -e / pipefail)"
for fn in config_files_for_sapi detect_web_roots apache_conf_files fpm_pool_files relevant_config_files; do
	if ( "$fn" cli | sort -u >/dev/null ); then
		ok "$fn liefert Status 0 in Pipelines"
	else
		ko "$fn liefert Status 0 in Pipelines" "Status != 0"
	fi
done

section "CLI"
out=$("$ROOT/bin/php2shell-guard" --version 2>&1)
assert_contains "version wird ausgegeben" "$out" "php2shell-guard"
out=$("$ROOT/bin/php2shell-guard" scan --json 2>/dev/null)
printf '%s' "$out" >"$TMP/scan.json"
assert_true "scan --json liefert valides JSON" json_valid "$TMP/scan.json"
assert_contains "scan --json enthält tool-Marker" "$out" '"tool":"php2shell-guard"'
out=$("$ROOT/bin/php2shell-guard" templates apache 2>&1)
assert_contains "templates apache liefert Drop-in" "$out" "php_admin_value memory_limit -1"
assert_contains "templates apache enthält Request-Limits" "$out" "LimitRequestBody"

section "Bundle"
if (cd "$ROOT" && ./tools/build-bundle.sh >/dev/null 2>&1); then
	ok "Bundle wird gebaut"
else
	ko "Bundle wird gebaut" "build-bundle.sh fehlgeschlagen"
fi
if [ -x "$ROOT/dist/php2shell-guard.sh" ]; then
	ok "Bundle ist ausführbar"
else
	ko "Bundle ist ausführbar" "dist/php2shell-guard.sh fehlt"
fi
out=$(bash "$ROOT/dist/php2shell-guard.sh" scan --json 2>/dev/null)
printf '%s' "$out" >"$TMP/bundle.json"
assert_true "Bundle liefert valides JSON" json_valid "$TMP/bundle.json"
out=$(bash "$ROOT/dist/php2shell-guard.sh" templates fpm 2>&1)
assert_contains "Bundle enthält eingebettete Templates" "$out" "php_admin_value[memory_limit] = -1"

printf '\n===============================\n'
printf 'Erfolgreich: %d | Fehlgeschlagen: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
