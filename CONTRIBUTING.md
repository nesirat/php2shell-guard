# Contributing

Danke, dass du beiträgst. Das Werkzeug soll **offen nutzbar** bleiben —
Beiträge, die es einfacher machen, eine ganze Flotte in Minuten zu härten,
sind besonders willkommen.

## Entwicklung

```bash
git clone <repo>
cd php2shell-guard
make test          # Testsuite
make lint          # shellcheck (falls installiert)
make fmt           # shfmt -w -i 0 -ci
make bundle        # Single-File-Bundle bauen
```

## Konventionen

* **Shell:** Bash ≥ 3.2, POSIX-Werkzeuge (`grep`, `sed`, `awk`, `find`).
  Keine Bash-4-Features (`mapfile`, `declare -A`), damit das Werkzeug auch auf
  macOS (Bash 3.2) und alten Systemen läuft.
* **Keine Abhängigkeiten:** Weder Python noch `jq` dürfen vorausgesetzt werden.
  `python3` wird nur in der Testsuite zur JSON-Validierung genutzt (optional).
* **BSD-Kompatibilität:** `sed -E` mit BERE-Alternation (`\|`) funktioniert auf
  macOS nicht — bitte zwei `sed`-Aufrufe statt Alternation verwenden
  (durch die Testsuite abgesichert).
* **`set -euo pipefail` beachten:** Jede Funktion, die in einer Pipeline
  benutzt wird, muss mit `return 0` enden — sonst bricht der Lauf bei
  `pipefail` ab.
* **Formatierung:** `shfmt -i 0 -ci`, Tabs zur Einrückung.
* **Sprache:** Code-Kommentare und Variablennamen auf Englisch, Dokumentation
  auf Deutsch **und** Englisch (`README.md` / `README.en.md`).

## Neue Beiträge, die gebraucht werden

* weitere Betriebssysteme (SuSE, FreeBSD, Gentoo)
* weitere SAPIs (FrankenPHP, LSAPI, CGI)
* weitere IOC-Muster
* Ansible-/Salt-Rollen
* Eine „Kompromittierungs-Bewertung" mit Rückstufung nach Branche-Kontext

## Tests

Jeder Bugfix braucht einen Regressionstest in `tests/run-tests.sh`.

```bash
./tests/run-tests.sh
```

## Pull Requests

1. Fork + Branch (`feature/…` oder `fix/…`)
2. `make test && make lint` muss grün sein
3. PR-Beschreibung: Was wurde geändert, warum, wie verifiziert
4. Verweise auf das betroffene Advisory, falls es sicherheitsrelevant ist
