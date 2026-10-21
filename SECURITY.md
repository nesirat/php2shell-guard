# Security Policy

## Melden von Schwachstellen

Wenn du eine Schwachstelle in **php2shell-guard** findest, melde sie bitte
privat (nicht als öffentliches Issue) an die Maintainer. Bitte gib mit:

* Beschreibung des Problems und betroffener Version/Kommandos
* reproduzierbare Schritte
* mögliche Auswirkung (insbesondere: erlaubt das Werkzeug unprivilegierte
  Rechteerhöhung oder das Umgehen von `sudo`-Grenzen?)
* Vorschlag für eine Behebung

Wir bestätigen den Eingang innerhalb von 72 Stunden und halten dich über den
Fix informiert.

## Sicherheitsmodell des Werkzeugs

Das Werkzeug arbeitet in einer Umgebung, in der es **Root-Rechte** auf
Zielhosts haben kann. Beachte deshalb:

| Aspekt | Verhalten |
|---|---|
| `scan`, `report`, `templates` | read-only, keine Rechte nötig |
| `verify` | schreibt eine temporäre Datei in den Web-Root (Zufallsname, enthält keine Geheimnisse, wird gelöscht) |
| `ioc` | Lesezugriff auf Web-Roots und Logs |
| `mitigate`, `patch --apply` | benötigen root; legen **Backups** der geänderten Konfigurationsdateien an (`*.p2s-backup.<timestamp>`) |

### Wichtige Einschränkungen

* `mitigate` setzt `memory_limit = -1` **admin-gesichert**. Das ist
  beabsichtigt (der Angriff braucht ein kontrollierbares OOM), erhöht aber die
  DoS-Gefahr. Nutze `--cgroup-limit`, um eine Verfügbarkeitsgrenze zu setzen.
* `verify` legt die Probe-Datei im Web-Root ab. In Umgebungen mit strengem
  Change-Management sollte stattdessen ein dedizierter, kurzlebiger
  Probe-Pfad verwendet werden.
* Das Werkzeug setzt **kein** `RLIMIT_AS`/`RLIMIT_DATA` — das wäre
  kontraproduktiv (siehe `docs/MITIGATION.md`).

## Vertrauensgrenzen

* Das Werkzeug führt **keinen** Code aus, der aus dem Internet geladen wurde.
* Das Single-File-Bundle wird lokal gebaut (`make bundle`) — wer es über das
  Netz verteilt, sollte es selbst bauen oder die Prüfsumme prüfen.
* Der Fleet-Runner nutzt SSH-Standardmechanismen (Host-Key-Prüfung, Agent).
  `--ssh-opts` kann die Host-Key-Prüfung abschalten — nur in kontrollierten
  Testumgebungen verwenden.

## Beteiligung an der Sicherheitsforschung

Die Nutzung dieses Werkzeugs gegen Systeme, für die keine ausdrückliche
Autorisierung vorliegt, ist nicht gestattet. Es dient ausschließlich der
Härtung und Prüfung eigener oder ausdrücklich freigegebener Systeme.
