# Changelog

Alle nennenswerten Änderungen an diesem Projekt werden hier dokumentiert.

Format basierend auf [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
Projektversion nach [SemVer](https://semver.org/lang/de/).

## [0.1.0] — 2026-10-21

### Added

- `scan` — Inventarisierung von PHP-Versionen, SAPIs und Mitigation-Status
  (JSON-Ausgabe, Exit-Code 2 bei kritischem Befund → CI-Gate).
- `mitigate` — temporäre Mitigation für CVE-2026-109618/109619:
  admin-gesicherte `php_admin_value`-/`php_admin_value[]`-Konfiguration für
  Apache `mod_php`, PHP-FPM (je Pool), php-cgi und nginx; Request-Limits auf
  Webserver-Ebene; Worker-Neustart; optionale cgroup-Grenze (`MemoryMax`).
- `patch` — Paketmanager-gestütztes PHP-Update (Debian/Ubuntu, RHEL/Rocky/Alma,
  Alpine, SUSE) inkl. EOL-Branch-Hinweisen mit Migrationsempfehlung.
- `verify` — Prüfung der **effektiven** Konfiguration über HTTP (Probe-Datei im
  Web-Root, danach entfernt).
- `ioc` — Suche nach Kompromittierungs-Indikatoren (Webshell-Muster, PHP-Code in
  Nicht-PHP-Dateien, Konfiguration im Web-Root, Schreibrechte, kürzlich geänderte
  Dateien, Log-Indikatoren).
- `report` — Konsolidierung beliebiger Scan-JSONs zu Markdown/CSV.
- `templates` — Anzeige der anzuwendenden Konfiguration.
- `php2shell-fleet` — parallele Ausführung über SSH auf ganze Host-Flotten.
- `dist/php2shell-guard.sh` — Single-File-Bundle (alle Bibliotheken und
  Templates eingebettet, keine Abhängigkeiten).
- `docs/MANUAL.md` / `docs/MANUAL.en.md` — vollständiges Bedienhandbuch:
  Installation, Kommando-Referenz, CI-Integration, Betrieb, Rollback,
  Troubleshooting, FAQ, Glossar.
- `tools/publish.sh` — Veröffentlichung auf GitHub (Repo anlegen, Topics, Push, Release).
- Testsuite (`tests/run-tests.sh`, 74 Tests) inkl. Regressionstests für
  Konfigurationsauswertung, JSON-Erzeugung, Report-Parsing und
  BSD-/GNU-sed-Kompatibilität.

[0.1.0]: https://github.com/nesirat/php2shell-guard/releases/tag/v0.1.0
