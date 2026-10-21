SHELL := /bin/bash
PREFIX ?= /usr/local
VERSION := $(shell grep -E '^P2S_VERSION=' bin/php2shell-guard | head -1 | cut -d'"' -f2)

.PHONY: help bundle test lint fmt install clean scan verify ioc

help:
	@echo "php2shell-guard $(VERSION)"
	@echo ""
	@echo "Ziele:"
	@echo "  bundle    Single-File-Bundle nach dist/ bauen"
	@echo "  test      Testsuite ausführen"
	@echo "  lint      shellcheck (falls installiert)"
	@echo "  fmt       shfmt -w (falls installiert)"
	@echo "  install   nach \$$PREFIX installieren"
	@echo "  scan      lokalen Host scannen"
	@echo "  verify    effektive Konfiguration prüfen"
	@echo "  ioc       Kompromittierungs-Indikatoren suchen"
	@echo "  clean     dist/ und Ergebnisse entfernen"

bundle:
	@./tools/build-bundle.sh

test:
	@./tests/run-tests.sh

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck -x -S warning bin/php2shell-guard bin/php2shell-fleet lib/*.sh tools/*.sh tests/run-tests.sh; \
	else \
		echo "shellcheck nicht installiert — übersprungen"; \
	fi

fmt:
	@if command -v shfmt >/dev/null 2>&1; then \
		shfmt -w -i 0 -ci bin/ lib/ tools/ tests/; \
	else \
		echo "shfmt nicht installiert — übersprungen"; \
	fi

install: bundle
	@install -d $(DESTDIR)$(PREFIX)/bin $(DESTDIR)$(PREFIX)/share/php2shell-guard
	@install -m 0755 dist/php2shell-guard.sh $(DESTDIR)$(PREFIX)/bin/php2shell-guard
	@install -m 0755 bin/php2shell-fleet $(DESTDIR)$(PREFIX)/bin/php2shell-fleet
	@cp -r templates $(DESTDIR)$(PREFIX)/share/php2shell-guard/
	@echo "Installiert nach $(DESTDIR)$(PREFIX)/bin"

scan: bundle
	@./dist/php2shell-guard.sh scan

verify: bundle
	@./dist/php2shell-guard.sh verify

ioc: bundle
	@./dist/php2shell-guard.sh ioc

clean:
	@rm -rf dist fleet-results
	@echo "Aufgeräumt"
