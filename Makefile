# code-router -- run Claude Code against an OAuth-gated gateway via
# claude-code-router (CCR), with token refresh handled by systemd.
#
# Just type `make install`:
#   - As root (or sudo)  -> system-wide install: ccr in /usr/local, dedicated
#                           code-router system user, daemon at boot, state
#                           under /var/lib/code-router. Any user on the box
#                           can run `icode`.
#   - As a normal user   -> per-user install: nvm/Node 22 in $HOME, daemon
#                           launched lazily by `ccr code`, state under
#                           ~/.claude-code-router, user-systemd timer.
#
# `make install` dispatches based on the calling uid; the underlying targets
# are install-system and install-user if you ever need to be explicit (e.g.
# a per-user install under the root account: ALLOW_ROOT_USER_INSTALL=1).
#
# Uninstall:    make uninstall   /  sudo make uninstall-system
# Status:       make status            # per-user only
# Manual mint:  make refresh           # per-user only

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

# System-mode paths (used by install-system / uninstall-system targets).
SYS_BIN_DIR     ?= /usr/local/bin
SYS_SHARE_DIR   ?= /usr/local/share/code-router
SYS_PLUGIN_DIR  ?= $(SYS_SHARE_DIR)/plugins
SYS_CA_FILE     ?= $(SYS_SHARE_DIR)/ca.pem
SYS_CFG_DIR     ?= /etc/icode
SYS_CFG         ?= $(SYS_CFG_DIR)/config.json
SYS_STATE_DIR   ?= /var/lib/code-router
SYS_SYSTEMD_DIR ?= /etc/systemd/system
SYS_USER        ?= code-router

.PHONY: install install-user uninstall status refresh check-prereqs install-node \
        install-router install-bin install-plugin install-ca install-systemd \
        configure \
        install-system uninstall-system check-prereqs-system \
        install-system-user install-system-dirs install-system-bin \
        install-system-plugin install-system-router install-system-ca \
        install-system-systemd configure-system

# `make install` dispatches based on caller: root -> system install (the
# obvious thing for a sudo'd "install everything" run), non-root -> per-user
# install. The system path expects the caller to have root, so we just
# re-invoke the explicit target rather than embedding the dispatch in every
# downstream target. Override with ALLOW_ROOT_USER_INSTALL=1 if you really
# want a per-user install under the root account (rare).
install:
	@if [ "$$(id -u)" = "0" ] && [ -z "$(ALLOW_ROOT_USER_INSTALL)" ]; then \
		$(MAKE) install-system; \
	else \
		$(MAKE) install-user; \
	fi

install-user: check-prereqs install-node install-router install-bin install-plugin \
              install-systemd configure
	@echo
	@if test -r $(ICODE_CFG); then \
		echo "code-router installed."; \
		echo "  Try: icode -p 'say OK'"; \
		echo "  Status: make status"; \
	else \
		echo "code-router installed (config pending)."; \
		echo ""; \
		echo "  Next: create or edit $(ICODE_CFG) with your provider entries"; \
		echo "        (template at $(CURDIR)/config.example.json),"; \
		echo "        then run: make configure"; \
	fi

check-prereqs:
	@command -v python3 >/dev/null || { echo "ERROR: python3 not installed (apt-get install python3)"; exit 1; }
	@command -v openssl >/dev/null || { echo "ERROR: openssl not installed"; exit 1; }

# Config-dependent finishing steps. Safe to re-run after editing the config.
configure:
	@if ! test -r $(ICODE_CFG); then \
		echo "configure: $(ICODE_CFG) not present yet -- skipping CA fetch + token mint."; \
	elif grep -q "REPLACE_ME\|gateway\.example\.com\|your-okta-tenant" $(ICODE_CFG); then \
		echo "ERROR: $(ICODE_CFG) still has placeholder values from the example."; \
		echo "       Edit it with real values, then re-run: make configure"; \
		exit 1; \
	else \
		$(MAKE) install-ca refresh; \
	fi

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
	echo "claude-code-router installed from vendored source." && \
	if ! command -v claude >/dev/null 2>&1; then \
		echo "Installing Claude Code (@anthropic-ai/claude-code)..."; \
		npm i -g @anthropic-ai/claude-code >/dev/null && \
		echo "claude-code installed."; \
	else \
		echo "claude-code already installed."; \
	fi

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
	@install -m 0644 systemd/code-router.service $(SYSTEMD_DIR)/code-router.service
	@install -m 0644 systemd/code-router.timer   $(SYSTEMD_DIR)/code-router.timer
	@if systemctl --user daemon-reload 2>/dev/null; then \
		systemctl --user enable --now code-router.timer; \
		echo "Enabled code-router.timer (refreshes every 30 min)."; \
	else \
		echo ""; \
		echo "WARNING: systemctl --user is not reachable on this machine."; \
		echo "  Unit files installed to $(SYSTEMD_DIR), but the timer is NOT enabled."; \
		echo "  Token refresh will need to be triggered manually with 'make refresh'"; \
		echo "  until the user-systemd instance is available."; \
		echo ""; \
		echo "  Common cause: linger isn't enabled for this user. Fix with:"; \
		echo "    sudo loginctl enable-linger \$$(whoami)"; \
		echo "  Then log out and back in, and re-run:"; \
		echo "    make install-systemd"; \
		echo ""; \
	fi

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

# ----------------------------------------------------------------------------
# System-wide install (sudo). Sets up a shared CCR daemon owned by a
# dedicated `code-router` system user and started at boot. Per-user state
# (~/.claude-code-router etc.) is untouched.
# ----------------------------------------------------------------------------

install-system: check-prereqs-system install-system-user install-system-dirs \
                install-system-router install-system-bin install-system-plugin \
                install-system-systemd configure-system
	@echo
	@if test -r $(SYS_CFG); then \
		echo "code-router system install complete."; \
		echo "  Daemon: systemctl status code-router.service"; \
		echo "  Timer:  systemctl status code-router-refresh.timer"; \
	else \
		echo "code-router system install complete (config pending)."; \
		echo ""; \
		echo "  Next: create or edit $(SYS_CFG) with your provider entries"; \
		echo "        (template at $(CURDIR)/config.example.json),"; \
		echo "        then run: sudo make configure-system"; \
	fi

check-prereqs-system:
	@if [ "$$(id -u)" != "0" ]; then \
		echo "ERROR: install-system requires root (try: sudo make install-system)"; exit 1; \
	fi
	@command -v python3 >/dev/null || { echo "ERROR: python3 not installed"; exit 1; }
	@command -v openssl >/dev/null || { echo "ERROR: openssl not installed"; exit 1; }
	@command -v node    >/dev/null || { echo "ERROR: node not installed (try: apt install nodejs npm)"; exit 1; }
	@command -v npm     >/dev/null || { echo "ERROR: npm not installed (try: apt install nodejs npm)"; exit 1; }
	@NODE_MAJOR=$$(node -p 'process.versions.node.split(".")[0]'); \
	if [ "$$NODE_MAJOR" -lt 20 ]; then \
		echo "ERROR: Node $$NODE_MAJOR is too old (the vendored router uses globals added in Node 20, e.g. File)."; \
		echo "       Debian 12's apt nodejs is 18 -- install Node 20+ from NodeSource instead:"; \
		echo "         curl -fsSL https://deb.nodesource.com/setup_22.x | bash -"; \
		echo "         apt install -y nodejs"; \
		exit 1; \
	fi

install-system-user:
	@if ! getent passwd $(SYS_USER) >/dev/null; then \
		echo "Creating system user '$(SYS_USER)' (home: $(SYS_STATE_DIR))..."; \
		useradd --system --home-dir $(SYS_STATE_DIR) --shell /usr/sbin/nologin \
			--comment "code-router daemon" $(SYS_USER); \
	else \
		echo "System user '$(SYS_USER)' already exists."; \
	fi

install-system-dirs:
	@install -d -m 0755 -o root -g root              $(SYS_BIN_DIR)
	@install -d -m 0755 -o root -g root              $(SYS_SHARE_DIR)
	@install -d -m 0755 -o root -g root              $(SYS_PLUGIN_DIR)
	@install -d -m 0750 -o root -g $(SYS_USER)       $(SYS_CFG_DIR)
	@install -d -m 0750 -o $(SYS_USER) -g $(SYS_USER) $(SYS_STATE_DIR)
	@install -d -m 0750 -o $(SYS_USER) -g $(SYS_USER) $(SYS_STATE_DIR)/.claude-code-router

install-system-bin:
	@install -m 0755 bin/icode                     $(SYS_BIN_DIR)/icode
	@install -m 0755 bin/code-router-refresh-token $(SYS_BIN_DIR)/code-router-refresh-token

install-system-plugin:
	@install -m 0644 plugins/strip-reasoning.js $(SYS_PLUGIN_DIR)/strip-reasoning.js
	@install -m 0644 plugins/inject-token.js    $(SYS_PLUGIN_DIR)/inject-token.js

install-system-router:
	@if ! command -v pnpm >/dev/null 2>&1; then \
		echo "Installing pnpm globally (required to build the vendored router)..."; \
		npm i -g pnpm@9 >/dev/null; \
	fi
	@echo "Building vendored claude-code-router from $(ROUTER_SRC)..."
	@cd $(ROUTER_SRC) && pnpm install --silent && pnpm build >/dev/null
	@echo "Installing globally (system Node)..."
	@npm i -g $(ROUTER_SRC) >/dev/null
	@echo "claude-code-router installed system-wide."
	@if ! command -v claude >/dev/null 2>&1; then \
		echo "Installing Claude Code (@anthropic-ai/claude-code) system-wide..."; \
		npm i -g @anthropic-ai/claude-code >/dev/null && \
		echo "claude-code installed."; \
	else \
		echo "claude-code already installed."; \
	fi

install-system-ca:
	@HOSTS=$$(python3 -c "import json,urllib.parse,sys;cfg=json.load(open('$(SYS_CFG)'));print('\n'.join(sorted({urllib.parse.urlparse(p['base_url']).hostname for p in cfg['providers']})))"); \
	test -n "$$HOSTS" || { echo "ERROR: no provider base_urls found in $(SYS_CFG)"; exit 1; }; \
	: > $(SYS_CA_FILE); \
	for HOST in $$HOSTS; do \
		echo "Fetching CA chain from $$HOST..."; \
		echo | openssl s_client -connect $$HOST:443 -showcerts 2>/dev/null | \
			awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' \
			>> $(SYS_CA_FILE); \
	done; \
	chmod 0644 $(SYS_CA_FILE); \
	test -s $(SYS_CA_FILE) || { echo "ERROR: CA fetch failed"; exit 1; }; \
	echo "Wrote $(SYS_CA_FILE) ($$(grep -c BEGIN $(SYS_CA_FILE)) cert(s) from $$(echo $$HOSTS | wc -w) host(s))"

install-system-systemd:
	@install -m 0644 systemd/system/code-router.service         $(SYS_SYSTEMD_DIR)/code-router.service
	@install -m 0644 systemd/system/code-router-refresh.service $(SYS_SYSTEMD_DIR)/code-router-refresh.service
	@install -m 0644 systemd/system/code-router-refresh.timer   $(SYS_SYSTEMD_DIR)/code-router-refresh.timer
	@systemctl daemon-reload
	@systemctl enable --now code-router-refresh.timer
	@systemctl enable code-router.service
	@echo "System units installed and enabled."

# Config-dependent: needs $(SYS_CFG) populated. Fetches the corporate CA
# chain into $(SYS_CA_FILE), mints the initial token, and (re)starts the
# daemon so it picks up the populated config.
configure-system:
	@if [ "$$(id -u)" != "0" ]; then \
		echo "ERROR: configure-system requires root (try: sudo make configure-system)"; \
		exit 1; \
	elif ! test -r $(SYS_CFG); then \
		echo "configure-system: $(SYS_CFG) not present yet -- skipping CA fetch + token mint."; \
	elif grep -q "REPLACE_ME\|gateway\.example\.com\|your-okta-tenant" $(SYS_CFG); then \
		echo "ERROR: $(SYS_CFG) still has placeholder values from the example."; \
		echo "       Edit the file with real values, then re-run: sudo make configure-system"; \
		exit 1; \
	else \
		$(MAKE) install-system-ca; \
		systemctl start code-router-refresh.service; \
		systemctl restart code-router.service; \
		echo "Daemon restarted with active provider; check 'systemctl status code-router'."; \
	fi

uninstall-system:
	@if [ "$$(id -u)" != "0" ]; then \
		echo "ERROR: uninstall-system requires root (try: sudo make uninstall-system)"; exit 1; \
	fi
	-systemctl disable --now code-router.service code-router-refresh.timer 2>/dev/null
	-rm -f $(SYS_SYSTEMD_DIR)/code-router.service \
	       $(SYS_SYSTEMD_DIR)/code-router-refresh.service \
	       $(SYS_SYSTEMD_DIR)/code-router-refresh.timer
	-systemctl daemon-reload
	-rm -f $(SYS_BIN_DIR)/icode $(SYS_BIN_DIR)/code-router-refresh-token
	-rm -rf $(SYS_PLUGIN_DIR)
	-rm -f $(SYS_CA_FILE)
	-rmdir --ignore-fail-on-non-empty $(SYS_SHARE_DIR) 2>/dev/null
	@echo
	@echo "System install removed. The following were left in place:"
	@echo "  - $(SYS_CFG_DIR)/  (your provider credentials)"
	@echo "  - $(SYS_STATE_DIR)/ (token file, active-provider, daemon's CCR config)"
	@echo "  - $(SYS_USER) system user"
	@echo "  - npm-global @musistudio/claude-code-router"
	@echo "Remove manually if desired:"
	@echo "  sudo rm -rf $(SYS_CFG_DIR) $(SYS_STATE_DIR)"
	@echo "  sudo userdel $(SYS_USER)"
	@echo "  sudo npm uninstall -g @musistudio/claude-code-router"
