# code-router -- run Claude Code against an OAuth-gated, OpenAI-compatible
# Azure-OpenAI gateway via claude-code-router (CCR), with OAuth token
# refresh handled by a systemd user timer.
#
# Usage:
#   make install      # full install (default)
#   make uninstall    # remove all files & disable timer
#   make status       # show service/timer/daemon status
#   make refresh      # mint a fresh token now (manual override)

SHELL := /bin/bash

PREFIX        ?= $(HOME)
BIN_DIR       ?= $(PREFIX)/.local/bin
SYSTEMD_DIR   ?= $(PREFIX)/.config/systemd/user
CCR_DIR       ?= $(PREFIX)/.claude-code-router
PLUGIN_DIR    ?= $(CCR_DIR)/plugins
CA_DIR        ?= $(PREFIX)/.local/share/ca-certs
NVM_DIR       ?= $(PREFIX)/.nvm
ICODE_CFG     ?= $(PREFIX)/.config/icode/config.json

NODE_VERSION  ?= 22
NVM_VERSION   ?= v0.40.3
ROUTER_SRC    := $(CURDIR)/router

.PHONY: install uninstall status refresh check-prereqs install-node \
        install-router install-bin install-plugin install-ca install-systemd

install: check-prereqs install-node install-router install-ca install-bin \
         install-plugin install-systemd refresh
	@echo
	@echo "code-router installed."
	@echo "  Try: icode -p 'say OK'"
	@echo "  Status: make status"

check-prereqs:
	@command -v python3 >/dev/null || { echo "ERROR: python3 not installed (apt-get install python3)"; exit 1; }
	@command -v openssl >/dev/null || { echo "ERROR: openssl not installed"; exit 1; }
	@test -r $(ICODE_CFG)          || { echo "ERROR: $(ICODE_CFG) not found -- create it with a 'providers' array (see README)"; exit 1; }

install-node:
	@if [ ! -s $(NVM_DIR)/nvm.sh ]; then \
		echo "Installing nvm $(NVM_VERSION)..."; \
		curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/$(NVM_VERSION)/install.sh | bash; \
	else \
		echo "nvm already installed."; \
	fi
	@. $(NVM_DIR)/nvm.sh; \
	if ! nvm ls $(NODE_VERSION) >/dev/null 2>&1; then \
		echo "Installing Node $(NODE_VERSION)..."; \
		nvm install $(NODE_VERSION); \
	else \
		echo "Node $(NODE_VERSION) already installed."; \
	fi

install-router:
	@. $(NVM_DIR)/nvm.sh && nvm use --delete-prefix --silent $(NODE_VERSION) && \
	if ! command -v pnpm >/dev/null 2>&1; then \
		echo "Installing pnpm (required to build the vendored router)..."; \
		npm i -g pnpm@9 >/dev/null 2>&1; \
	fi; \
	echo "Building vendored claude-code-router from $(ROUTER_SRC)..."; \
	cd $(ROUTER_SRC) && pnpm install --silent && pnpm build >/dev/null 2>&1 && \
	echo "Installing globally..." && \
	npm i -g $(ROUTER_SRC) >/dev/null 2>&1 && \
	echo "claude-code-router installed from vendored source."

install-bin: | $(BIN_DIR)
	install -m 0755 bin/icode                     $(BIN_DIR)/icode
	install -m 0755 bin/code-router-refresh-token $(BIN_DIR)/code-router-refresh-token

install-plugin: | $(PLUGIN_DIR)
	install -m 0644 plugins/strip-reasoning.js $(PLUGIN_DIR)/strip-reasoning.js
	install -m 0644 plugins/inject-token.js    $(PLUGIN_DIR)/inject-token.js

install-ca: | $(CA_DIR)
	@HOSTS=$$(python3 -c "import json,urllib.parse,sys;cfg=json.load(open('$(ICODE_CFG)'));print('\n'.join(sorted({urllib.parse.urlparse(p['base_url']).hostname for p in cfg['providers']})))"); \
	test -n "$$HOSTS" || { echo "ERROR: no provider base_urls found in $(ICODE_CFG)"; exit 1; }; \
	: > $(CA_DIR)/code-router-ca.pem; \
	for HOST in $$HOSTS; do \
		echo "Fetching CA chain from $$HOST..."; \
		echo | openssl s_client -connect $$HOST:443 -showcerts 2>/dev/null | \
			awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' \
			>> $(CA_DIR)/code-router-ca.pem; \
	done; \
	test -s $(CA_DIR)/code-router-ca.pem || { echo "ERROR: CA fetch failed"; exit 1; }; \
	echo "Wrote $(CA_DIR)/code-router-ca.pem ($$(grep -c BEGIN $(CA_DIR)/code-router-ca.pem) cert(s) from $$(echo $$HOSTS | wc -w) host(s))"

install-systemd: | $(SYSTEMD_DIR)
	install -m 0644 systemd/code-router.service $(SYSTEMD_DIR)/code-router.service
	install -m 0644 systemd/code-router.timer   $(SYSTEMD_DIR)/code-router.timer
	systemctl --user daemon-reload
	systemctl --user enable --now code-router.timer

refresh:
	@$(BIN_DIR)/code-router-refresh-token

status:
	@echo "=== timer ==="
	@systemctl --user status code-router.timer --no-pager 2>/dev/null | head -8 || echo "(timer not installed)"
	@echo
	@echo "=== last refresh ==="
	@systemctl --user status code-router.service --no-pager 2>/dev/null | sed -n '1,3p;/ExecStart=/d;/^\s*$$/d' | tail -10 || echo "(service not installed)"
	@echo
	@echo "=== ccr daemon ==="
	@. $(NVM_DIR)/nvm.sh 2>/dev/null && nvm use --delete-prefix --silent $(NODE_VERSION) >/dev/null 2>&1 && ccr status 2>&1 || echo "ccr: not on PATH"

uninstall:
	-systemctl --user disable --now code-router.timer 2>/dev/null
	-rm -f $(SYSTEMD_DIR)/code-router.service $(SYSTEMD_DIR)/code-router.timer
	-systemctl --user daemon-reload
	-rm -f $(BIN_DIR)/icode $(BIN_DIR)/code-router-refresh-token
	-rm -f $(PLUGIN_DIR)/strip-reasoning.js $(PLUGIN_DIR)/inject-token.js
	-rm -f $(CCR_DIR)/token.txt
	-rm -f $(CA_DIR)/code-router-ca.pem
	-. $(NVM_DIR)/nvm.sh 2>/dev/null && nvm use --delete-prefix --silent $(NODE_VERSION) >/dev/null 2>&1 && ccr stop 2>/dev/null || true
	@echo "Uninstalled. Note: nvm, Node $(NODE_VERSION), and CCR were not removed."
	@echo "  - To remove CCR: npm uninstall -g @musistudio/claude-code-router"
	@echo "  - To remove nvm: rm -rf $(NVM_DIR) and remove sourcing lines from ~/.bashrc"

$(BIN_DIR) $(PLUGIN_DIR) $(CA_DIR) $(SYSTEMD_DIR):
	@mkdir -p $@
