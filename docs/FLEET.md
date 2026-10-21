# Flottenbetrieb (Batch)

Stand: 2026-10-21

---

## 1. Grundidee

Ein Bundle, **eine** Datei, keine Abhängigkeiten auf dem Zielhost. Der Fleet-Runner
verteilt es per SSH über stdin und sammelt JSON-Ergebnisse ein.

```
                    ┌──────────────────────────┐
                    │ php2shell-fleet          │
                    │  - Parallelität          │
                    │  - SSH-Optionen          │
                    │  - Ergebnis-Sammlung     │
                    └───────────┬──────────────┘
              ┌─────────────────┼─────────────────┐
              ▼                 ▼                 ▼
        ssh host1         ssh host2         ssh host3
        bash -s < bundle  bash -s < bundle  bash -s < bundle
              │                 │                 │
              ▼                 ▼                 ▼
        result.json        result.json        result.json
                    └─────────────────┬─────────────────┘
                                      ▼
                            fleet-report.md / .csv
```

---

## 2. Vorbereitung

```bash
make bundle                 # dist/php2shell-guard.sh erzeugen
```

Das Bundle enthält alle Bibliotheken **und** die Konfigurations-Templates —
es ist auf dem Zielhost vollständig lauffähig.

---

## 3. Hostliste

`examples/hosts.txt`:

```
# Kommentare mit # und Leerzeilen sind erlaubt
root@10.0.0.11
deploy@10.0.0.12
web01.example.org
```

Der Name vor `@` wird als SSH-User verwendet. Werden keine Angaben gemacht,
greift der Default-User aus `~/.ssh/config`.

Bei mehreren known_hosts-Einträgen empfiehlt sich ein eigener Host-Alias je
Zielsystem, damit der Runner dieselbe Konfiguration wie im Alltag nutzt.

---

## 4. Kommandos

```bash
# Bestand (read-only)
./bin/php2shell-fleet --hosts examples/hosts.txt --cmd scan --parallel 10

# Mitigation (mit sudo auf dem Zielhost)
./bin/php2shell-fleet --hosts examples/hosts.txt --cmd mitigate --sudo --parallel 5 --extra "--dry-run"

# Update
./bin/php2shell-fleet --hosts examples/hosts.txt --cmd patch --sudo --extra "--apply"

# IOC-Prüfung
./bin/php2shell-fleet --hosts examples/hosts.txt --cmd ioc

# Gesamtreport
./bin/php2shell-fleet --hosts examples/hosts.txt --cmd scan --report fleet-report.md
```

### Optionen

| Option | Bedeutung |
|---|---|
| `--hosts <datei>` | Hostliste (Pflicht) |
| `--cmd <befehl>` | `scan` (Standard), `mitigate`, `patch`, `verify`, `ioc` |
| `--parallel <n>` | parallele Verbindungen (Standard 8) |
| `--sudo` | Remote-Befehl mit `sudo -n` (NOPASSWD erforderlich) |
| `--identity <key>` | SSH-Identity-Datei |
| `--ssh-opts "<opt>"` | zusätzliche SSH-Optionen |
| `--extra "<args>"` | Zusatzargumente für den Remote-Befehl |
| `--out <dir>` | Ergebnisverzeichnis (Standard `./fleet-results`) |
| `--local` | Hosts lokal ausführen (Tests) |
| `--report <datei>` | Markdown-Report schreiben |
| `--dry-run`, `--yes` | durchgereicht an den Remote-Befehl |

---

## 5. Exit-Codes

| Code | Bedeutung |
|---|---|
| `0` | kein kritischer Befund |
| `2` | mindestens eine ungepatchte PHP-Version ohne wirksame Mitigation |

Im Fleet-Lauf wird `2` als `KRITISCH` ausgewiesen (kein Fehler) — der
Gesamtreport listet die betroffenen Hosts.

---

## 6. Ergebnisstruktur

```
fleet-results/
├── web01/
│   ├── result.json     ← Scan-Ergebnis (JSON)
│   └── stderr.txt      ← stderr des Remote-Laufs
├── web02/
│   └── ...
```

`result.json` (gekürzt):

```json
{
  "tool": "php2shell-guard",
  "host": "rv1033",
  "timestamp": "2026-10-21T22:44:10Z",
  "cves": ["CVE-2026-109618", "CVE-2026-109619"],
  "web_serving": { "mod_php": true, "fpm": false, "nginx": false, "cgi": false },
  "installs": [
    {
      "sapi": "apache2handler",
      "php_version": "8.1.2-1ubuntu2.27",
      "branch": "8.1",
      "fixed_min": "",
      "patched": false,
      "mitigation": "missing",
      "risk": "critical",
      "memory_limit": "512M",
      "memory_limit_enforcement": "ini",
      "missing": " memory_limit session.upload_progress.enabled"
    }
  ]
}
```

`enforcement` ist das entscheidende Feld: `admin` = nicht durch die Anwendung
überschreibbar (wirksam), `ini` = über `ini_set()` aushebelbar (unvollständig).

---

## 7. Rollout-Empfehlung

| Schritt | Umfang | Risiko |
|---|---|---|
| 1. `scan` auf allen Hosts | read-only | keines |
| 2. `mitigate --dry-run` | read-only | keines |
| 3. `mitigate` auf **einem** Testhost | verändernd | gering — Backup der Config-Dateien |
| 4. `verify` auf dem Testhost | verändernd (kurze Probe-Datei) | gering |
| 5. `mitigate` auf die restliche Flotte | verändernd | gering — Apache-Reload, kein Neustart |
| 6. `patch --apply` in Wellen (z. B. 5 Hosts gleichzeitig) | verändernd | mittel — Paketupdate + Dienstneustart |
| 7. `scan` + `report` | read-only | keines |
| 8. `ioc` | Lesezugriff | keines |

### Warum Wellen?

`patch --apply` startet PHP-FPM und Apache neu. Ein Neustart ist ein
kurzer Ausfall. Mit Wellen und `--parallel` bleibt die Ausfallzeit je Host
minimal und die Last auf dem Paket-Mirror (apt/dnf) begrenzt.

### Nachtzfenster

`mitigate` ist auch nachts unkritisch (graceful Apache-Reload, FPM-Reload
ersetzt Worker). `patch --apply` gehört in ein Wartungsfenster, sofern die
Anwendung keine laufenden Requests verträgt.

---

## 8. Ansible-Ansatz

Für Umgebungen, in denen Ansible der Standard ist, siehe
[`../examples/ansible-playbook.yml`](../examples/ansible-playbook.yml).
Der Vorteil: Idempotenz, Check-Mode und Reporting sind eingebaut; der Nachteil:
etwas mehr Setup-Aufwand als der Shell-Runner.

---

## 9. Dauerbetrieb

```bash
# Täglich: Inventar-Delta
./bin/php2shell-fleet --hosts examples/hosts.txt --cmd scan \
  --out "inventory/$(date +%F)" --parallel 10

# Report über alle gespeicherten Läufe
./bin/php2shell-guard report inventory/*/*/result.json --out inventory.md
```

Der `report`-Befehl konsolidiert beliebige Scan-JSONs zu einer Markdown-Tabelle
inklusive Risiko-Zählung.
