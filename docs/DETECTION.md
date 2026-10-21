# Detection — Kompromittierung prüfen

Stand: 2026-10-21

> **Wichtig:** Eine Prüfung ohne Treffer ist **kein Beweis** für Sicherheit.
> Sie zeigt nur, dass die bekannten Muster nicht gefunden wurden.

---

## 1. Wann prüfen?

| Zeitpunkt | Priorität |
|---|---|
| Vor der Veröffentlichung (vor 21.10.2026) | hoch — Public PoCs existieren seit Veröffentlichung |
| Direkt nach dem Patch | hoch — Nachweis für den Change-Ticket |
| Routine (wöchentlich) | mittel |

---

## 2. Was `php2shell-guard ioc` prüft

### 2.1 Webshell-Muster im Web-Root

| Muster | Bedeutung |
|---|---|
| `eval(base64_decode(...))`, `eval(gzinflate(...))`, `eval(str_rot13(...))` | klassische obfuskierte Webshell |
| `system($_GET[...])`, `shell_exec($_REQUEST[...])`, `assert($_POST[...])` | direkte Command-Ausführung aus Request-Daten |
| `preg_replace(..., '/e')` | Code-Ausführung via Regex-Callback |
| `create_function(base64_decode(...))` | dynamische Funktionserzeugung |
| `move_uploaded_file(...php)`, `file_put_contents(...php)` | Dropper-Verhalten |
| `$x = base64_decode("…40+ Zeichen…")` | Obfuskierung von Nutzlasten |
| `chr(…).(chr(…)).{4,}` | Shellcode-Konstruktion |

### 2.2 PHP-Code in Nicht-PHP-Dateien

`.jpg`, `.png`, `.gif`, `.txt`, `.zip` mit `<?php` — klassische Bild-Shell.
Der Angreifer tarnt die Nutzlast als Bild.

### 2.3 Konfigurations-Hijacking im Web-Root

`php.ini`, `.user.ini` oder `.htaccess` **innerhalb** des Web-Roots erlauben
Attacker-kontrollierte Konfiguration (z. B. `auto_prepend_file`,
`disable_functions`). Legitime Deployments haben dort keine `php.ini`.

### 2.4 Schreibrechte

PHP-Dateien, die für alle Benutzer schreibbar sind (`-perm -0002`), sind ein
direkter Weg für Persistenz.

### 2.5 Kürzlich geänderte PHP-Dateien

Alle `.php`-Dateien, die in den letzten `--since-days` Tagen geändert wurden
(Standard 14), ohne `vendor/`, `node_modules/`, `storage/`, `cache/`.

### 2.6 Log-Indikatoren

| Indikator | Bedeutung |
|---|---|
| `PHP_SESSION_UPLOAD_PROGRESS` in Access-Logs | Versuch, den Upload-Progress-Pfad zu missbrauchen (CVE-2026-109619-Vektor) |
| `Allowed memory size`, `Maximum execution time`, `Segmentation fault` | Hinweis auf die vorgelagerten Fehlerbedingungen |

---

## 3. Manuelle Zusatzschritte

Diese Schritte gehen über automatisierte Muster hinaus und gehören in die
Reaktion auf einen Treffer:

1. **Host isolieren** (Netzwerksegment trennen), **nicht** neu starten —
   Neustart vernichtet flüchtige Spuren.
2. **Logs forensisch sichern** (Apache/nginx access+error, PHP-FPM-Logs,
   `journalctl -u php*-fpm`, Auth-Logs, `last`/`lastlog`).
3. **Persistenz suchen:** Cronjobs (`/etc/cron*`, `crontab -u <user> -l`),
   systemd-Timer/Units, SSH-Keys (`authorized_keys`), Shell-Profile
   (`~/.bashrc`, `~/.profile`), init-Skripte.
4. **Dateisystem-Zeitachse:** Dateien mit mtime **nach** dem Zeitpunkt der
   ersten Anomalie in den Logs.
5. **Container prüfen:** Images, Volumes, `docker inspect` auf verdächtige
   Mounts/Entrypoints.
6. **Entscheidung:** Bei bestätigtem Befund ist **Neuaufsetzen** (Restore aus
   verifiziertem Backup) sicherer als Bereinigung.

---

## 4. Ausgabe interpretieren

| Schweregrad | Bedeutung | Maßnahme |
|---|---|---|
| `KRITISCH` | Webshell-Muster oder PHP-Code in Bilddatei | Host isolieren, neu aufsetzen |
| `HOCH` | Konfiguration im Web-Root, Schreibrechte | prüfen und korrigieren |
| `MITTEL` | kürzlich geänderte Datei, Log-Indikator | zeitlich einordnen |

Beispiel:

```bash
php2shell-guard ioc --since-days 30
```

```
  [KRITISCH] webshell-muster          /var/www/html/uploads/x.php
             verdächtiger PHP-Code (eval/exec mit Request-Daten oder base64)
```

---

## 5. Continuous Detection

Für den dauerhaften Betrieb:

```bash
# wöchentlich auf jedem Webhost
php2shell-guard ioc --since-days 7 --json > /var/log/p2s/ioc-$(date +%F).json
```

Ergänzend sinnvoll:

* **EDR/WAF-Regeln** auf `PHP_SESSION_UPLOAD_PROGRESS` und auf Requests mit
  ungewöhnlich vielen Multipart-Teilen
* **File-Integrity-Monitoring** (AIDE, Tripwire, Wazuh) auf Web-Roots
* **Inventar-Datenbank** fortlaufend pflegen (siehe [`FLEET.md`](FLEET.md)) —
  nur was im Inventar steht, kann gehärtet werden

---

## 6. Referenzen

* <https://www.php.net/archive/2026.php#2026-10-21-5>
* <https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp>
* <https://github.com/Is4yev/php2shell-poc> (öffentlicher PoC — nur zur Analyse,
  **nicht** gegen fremde Systeme einsetzen)
