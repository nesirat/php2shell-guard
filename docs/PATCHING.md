# Patching — der eigentliche Fix

Stand: 2026-10-21

---

## 1. Versionsmatrix

| Branch | Gepatchte Version | Upstream-Fix | Hinweis |
|---|---|---|---|
| 8.5 | **8.5.12** | ja | Release-Ankündigung [510/513](https://news-web.php.net/php.announce/513) |
| 8.4 | **8.4.27** | ja | |
| 8.3 | **8.3.36** | ja | |
| 8.2 | **8.2.35** | ja | EOL 31.12.2026 — danach Migration planen |
| 8.1 | — | **nein** | EOL. Minimaler Source-Backport: `php/php-src` Branch `PHP-8.1-CVE-2026-109618-109619` |
| 8.0 | — | **nein** | EOL. Branch `PHP-8.0-CVE-2026-109618-109619` |
| 7.4 | — | **nein** | EOL. Branch `PHP-7.4-CVE-2026-109618-109619` |
| 7.3 und älter | — | **nein** | EOL, kein offizieller Backport → **Migration auf 8.2+** |
| 5.x | — | **nein** | EOL → **Migration auf 8.2+** |

> Ein EOL-Branch ohne Backport ist **kein** akzeptabler Dauerzustand.
> Der Source-Backport ist die Brücke, nicht das Ziel.

---

## 2. Distributionsspezifisch

### Debian / Ubuntu

```bash
apt update
apt list --upgradable | grep php
sudo apt install -y --only-upgrade php8.3 php8.3-fpm php8.3-cli
```

* Paketnamen: `php8.3`, `php8.3-fpm`, `php8.3-cli`, `libapache2-mod-php8.3`
* Neuere PHP-Versionen auf älteren Debian/Ubuntu: **Sury-Repo**
  (`https://packages.sury.org/php`) — bei vorhandenem Repo ggf. `apt update` erzwingen
* `update-alternatives` prüfen, falls mehrere PHP-Versionen parallel installiert sind:
  ```bash
  update-alternatives --list php
  sudo update-alternatives --set php /usr/bin/php8.3.36
  ```

### RHEL / Rocky / AlmaLinux

```bash
sudo dnf check-update | grep php
sudo dnf -y upgrade php php-cli php-fpm
```

* Paketnamen: `php`, `php-cli`, `php-fpm`, `php-common` (AppStream bzw. Remi)
* Nach dem Update: `sudo systemctl restart php-fpm httpd`

### Alpine

```bash
apk update
apk upgrade php83 php83-fpm
rc-service php-fpm restart
```

* Paketnamen: `php82`, `php83`, `php84`, `php85`, `php83-fpm`

---

## 3. Werkzeug

```bash
# Prüfen, ohne etwas zu tun
php2shell-guard patch

# Anwenden (aktualisiert nur PHP-Pakete und startet die Dienste neu)
sudo php2shell-guard patch --apply
```

Das Werkzeug:

1. ermittelt den Paketmanager und die installierten PHP-Pakete,
2. listet verfügbare Updates,
3. warnt bei EOL-Branches **mit konkreter Handlungsempfehlung**,
4. aktualisiert ausschließlich PHP-Pakete (`--only-upgrade` bzw. `upgrade <paket>`),
5. startet PHP-FPM und Apache neu.

---

## 4. Nach dem Update prüfen

```bash
php2shell-guard scan                 # muss "gepatcht=ja" zeigen
php2shell-guard verify --url https://example.org/
```

Erwartet:

```
  SAPI           PHP          Fix ab     gepatcht   Risiko
  fpm            8.3.36       8.3.36    ja        low
```

---

## 5. EOL-Branche migrieren

Reihenfolge für einen EOL-Host:

1. **Mitigation** setzen (`mitigate`) — schließt das akute Fenster.
2. **Abhängigkeiten prüfen:** Welche Frameworks/Module laufen auf dem Branch?
   (TYPO3 11 → PHP 7.4–8.1, Magento 2.4 → PHP 8.1+, WordPress → 7.4+)
3. **Zielversion wählen:** 8.2 (EOL Ende 2026), 8.3 (langfristig), 8.4/8.5 (aktuell).
4. **Paketmanager-Wechsel:** `apt install php8.3-*` + `update-alternatives`,
   Modul-Pakete mitschalten, `a2dismod`/`a2enmod` für das Apache-Modul.
5. **Anwendung testen** (Kompatibilität, `php -m`-Module, Deprecated-Meldungen).
6. **Schrittweise umschalten:** FPM-Pool auf neue Version, `reload`, Test-Requests,
   danach alte Version entfernen.
7. **Mitigation zurückbauen:** Nach dem Update sind `memory_limit=-1` und
   `session.upload_progress.enabled=0` nicht mehr nötig — **aber** nur nach
   bewusster Entscheidung, nicht automatisch.

### Source-Backport als Brücke

Für 7.4/8.0/8.1 stellt das PHP-Team minimale Source-Patches bereit:

```bash
git clone --branch PHP-8.1-CVE-2026-109618-109619 https://github.com/php/php-src.git
```

Das ist **kein** fertiges Release — Build-Abhängigkeiten und Regressionen sind
selbst zu prüfen. Als Interim für Systeme, die kurzfristig nicht migrierbar
sind, mit Wartungsfenster und Migrationsplan.

---

## 6. Container-Images

Eigene Images bauen:

```dockerfile
FROM php:8.3-fpm
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpq-dev \
 && docker-php-ext-install pdo_pgsql \
 && rm -rf /var/lib/apt/lists/*
```

* Basis-Image **pinnen** (`php:8.3.36-fpm`), nicht `php:8.3-fpm` — sonst
  bekommt der Build ungeprüft neue Versionen.
* `docker pull` + `docker scan` in die Pipeline.
* Rebuild-Rhythmus: monatlich oder bei Security-Releases.

---

## 7. Automatisierung

```yaml
# Ansible-Beispiel (Rolle)
- name: PHP auf gepatchte Version aktualisieren
  ansible.builtin.package:
    name: "{{ php_packages }}"
    state: latest
  notify: restart php-fpm
```

Details: [`../examples/ansible-playbook.yml`](../examples/ansible-playbook.yml)
