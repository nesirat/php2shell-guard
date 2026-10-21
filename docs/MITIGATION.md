# Mitigation — was warum, und was nicht

Stand: 2026-10-21 · Quellen: [PHP Security Advisory](https://www.php.net/archive/2026.php#2026-10-21-5),
[GHSA-w8hw-w9fx-j79w](https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w),
[GHSA-6wmf-4rv5-p3rp](https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp)

---

## 1. Die Reihenfolge zählt

| Priorität | Maßnahme | Warum |
|---|---|---|
| P0 | **Update auf gepatchte Version** | einzige vollständige Behebung |
| P0 | Falls Update nicht sofort möglich: **admin-gesicherte INI-Werte + Worker-Neustart** | entschärft die bekannten Pfade |
| P1 | **Request-Limits auf Webserver-/Proxy-Ebene** | greift vor dem PHP-Parser, deckt Chunked-Requests ohne Content-Length |
| P1 | **cgroup-Grenze (`MemoryMax`)** | verhindert, dass `memory_limit=-1` zu DoS wird |
| P2 | **IOC-Prüfung** | klärt, ob vor der Veröffentlichung ausgenutzt wurde |
| P2 | **Dauer-Gate in CI** | verhindert Rückkehr ungepatchter Versionen |

> Ein Update ist der einzige Weg, der die Lücke **behebt**. Alles andere ist
> Notfallschutz und muss als solcher dokumentiert werden.

---

## 2. CVE-2026-109618 — Speicher-Korruption (CVSS 9.2)

### Mechanismus

PHP nutzt bei Speichererschöpfung `longjmp()`. In Kontexten, in denen der
Request-Speicher nur teilweise initialisiert ist (Startup/Parse), hinterlässt
ein Allokationsfehler einen ungültigen Zustand. Der Request-Shutdown liest und
verzweigt danach — daraus entsteht RCE.

### Maßnahmen

| Maßnahme | Wert | Wo | Anmerkung |
|---|---|---|---|
| `memory_limit` | `-1` | `php_admin_value` (Apache/Pool) oder `php.ini` | **primäre** Konfigurations-Mitigation. Entfernt das kontrollierbare OOM. |
| `post_max_size` | klein (8M ohne Upload-Bedarf, max. 32M) | admin-Konfiguration | Angriffe nutzen chunked Requests ohne brauchbares `Content-Length`. |
| `upload_max_filesize` | `< post_max_size` | admin-Konfiguration | |
| `max_input_nesting_level` | 16 | admin-Konfiguration | reduziert Eingabekomplexität |
| `max_input_vars` | 1000 | admin-Konfiguration | |
| `max_file_uploads` | 10 | admin-Konfiguration | |
| Body-Limit Webserver | `LimitRequestBody` / `client_max_body_size` | Apache/nginx | greift vor PHP |
| Feld-/Header-Limits | `LimitRequestFields`, `LimitRequestFieldSize` | Apache | Multipart-Part-/Header-Flut |
| Verfügbarkeitsgrenze | `MemoryMax` (cgroup) | systemd / Container | **kein** `RLIMIT_AS`/`RLIMIT_DATA` |

### Warum `memory_limit = -1` und nicht `memory_limit = 64M`?

Der Angriff braucht einen *kontrollierbaren* Speichererschöpfungs-Zustand.
Ein endliches Limit liefert genau diesen Zustand. `-1` nimmt ihn weg — der
Worker läuft dann in ein cgroup-Limit statt in einen OOM-Pfad.

### Warum kein `RLIMIT_AS` / `RLIMIT_DATA`?

Diese Limits erzeugen *gerade* Allocation-Fehler und könnten den betroffenen
Pfad erneut auslösen. Das Advisory nennt das explizit. Korrekt ist eine
cgroup-Grenze (`memory.max` / `MemoryMax`), die den Worker beendet statt
Speicherfehler zu produzieren.

---

## 3. CVE-2026-109619 — stale State (CVSS 9.8)

### Mechanismus

Request-eigener Zustand (Error-/Session-/Objekt-/Extension-State) kann das
Ende der Request-Verarbeitung überleben. Fatale Errors, Warnungen während der
frühen Initialisierung oder unvollständige Resets hinterlassen Globals, die auf
freigegebenen Speicher zeigen. Der **nächste** Request auf demselben Worker
konsumiert diesen Zustand, bevor die normale Initialisierung ihn zurücksetzt.

### Maßnahmen

| Maßnahme | Wert | Wo | Anmerkung |
|---|---|---|---|
| `session.upload_progress.enabled` | `0` | **php.ini / FPM-Pool / Server-Config** | blockiert den bestätigten Producer/Consumer-Pfad |
| `fatal_error_backtraces` | `0` | dito | nur PHP 8.5; entfernt den bestätigten Producer |
| Ungültige/deprecated INI-Werte | entfernen | dito | Diagnose-Meldungen vor Initialisierung sind selbst ein Producer |
| Erreichbare fatale Errors / Timeouts | beheben | Applikation | `max_execution_time` gilt als fatal |
| `pm.max_requests=1` | optional | FPM-Pool | bricht Same-Worker-Exploitation |
| **Worker-Neustart** | Pflicht | FPM/Apache | nur ein Neustart ersetzt den korrupten Prozess |

### Warum nicht `ini_set()` oder `.user.ini`?

Beide greifen **nach** bzw. zu spät: `ini_set()` läuft innerhalb des Requests,
`.user.ini` wird im FPM-Kontext nach der normalen Initialisierung angewendet.
Die Lücke nutzt Operationen, die **vor** der regulären Request-Initialisierung
laufen — die Einstellung muss also beim Worker-Start vorhanden sein.

### Warum der Neustart zwingend ist

Der stale state lebt im langlebigen Worker-Prozess. Eine geänderte Konfiguration
räumt ihn nicht ab; nur ein Neustart ersetzt den Prozess durch einen sauberen.

---

## 4. SAPI-Risikomatrix

| SAPI | Risiko | Anwendungsunabhängig ausnutzbar? | Mitigation greift über |
|---|---|---|---|
| Apache `mod_php` | **höchstes** | ja — Shutdown läuft auch bei fehlgeschlagenem Startup | `php_admin_value` im Apache-Config |
| PHP-FPM | hoch | nein — State wird nachgelagert publiziert | `php_admin_value[]` je Pool |
| FrankenPHP | hoch (mod_php-Modell) | vermutlich ja | php.ini |
| LSAPI | hoch (FPM-Modell) | bedingt | php.ini |
| php-cgi | mittel | begrenzt | php.ini (schwächer, `PHP_INI_ALL`) |
| CLI | gering | kein HTTP-Vektor | — |

> Empfehlung: **mod_php migrieren.** Für die Akutphase genügt die Mitigation;
> mittelfristig ist FPM (oder ein Container pro App) die robustere Architektur.

---

## 5. Was die Mitigation ausdrücklich NICHT ist

* **Kein Fix.** Ein Allokationsfehler unterhalb `memory_limit=-1` kann den
  betroffenen Pfad weiterhin erreichen.
* **Kein Ersatz für das Update.** Beide CVEs sind nur durch die gepatchte
  Version vollständig behoben.
* **Kein vollständiger WAF-Ersatz.** Multipart-Teilanzahl und Headeranzahl pro
  Teil sind in nginx nicht nativ begrenzbar; Apache braucht `LimitRequest*`
  plus ggf. ModSecurity.
* **Keine Kompromittierungs-Garantie.** `ioc` findet Hinweise, keine
  Abwesenheit von Kompromittierung.

---

## 6. Betriebliche Umsetzung

### Reihenfolge auf einem Host

```bash
# 1. Bestand
php2shell-guard scan

# 2. Notfallschutz (mit Backups der Originaldateien)
sudo php2shell-guard mitigate --dry-run
sudo php2shell-guard mitigate

# 3. Update
sudo php2shell-guard patch --apply

# 4. Nachweis
php2shell-guard verify --url https://example.org/
php2shell-guard ioc --since-days 30
```

### Rollback

Alle geänderten Dateien werden vor dem Überschreiben als
`<datei>.p2s-backup.<timestamp>` gesichert. Zusätzlich existiert eine
markierte Block-Struktur (`>>> php2shell-guard >>>` / `<<< php2shell-guard <<<`),
sodass ein erneuter Lauf idempotent arbeitet.

### Rollout in einer Flotte

Siehe [`FLEET.md`](FLEET.md).

### Container / Docker

```yaml
services:
  php-fpm:
    image: php:8.3-fpm
    mem_limit: 1g          # Verfügbarkeitsgrenze
    restart: unless-stopped
```

`mem_limit` wirkt als cgroup-Grenze (`memory.max`) und ist damit die im
Advisory empfohlene Form der Begrenzung.

---

## 7. Referenzen

* <https://www.php.net/archive/2026.php#2026-10-21-5>
* <https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w>
* <https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp>
* <https://www.ncsc.gov.uk/news/critical-security-issue-affecting-php>
* EOL-Backports: `php/php-src` Branches `PHP-7.4-`, `PHP-8.0-`, `PHP-8.1-CVE-2026-109618-109619`
