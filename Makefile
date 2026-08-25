APP := dist/AgentHUD.app
BIN := app/.build/release/AgentHUD
# Stamped into the bundle so the app can answer "what am I running" — the
# update check has nothing to compare against otherwise.
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

.PHONY: build bundle run hooks hooks-cursor test clean uninstall update

build:
	cd app && swift build -c release

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/AgentHUD
	cp app/Info.plist $(APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :AgentHUDVersion string $(VERSION)" $(APP)/Contents/Info.plist >/dev/null 2>&1 \
	  || /usr/libexec/PlistBuddy -c "Set :AgentHUDVersion $(VERSION)" $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

run: bundle
	-killall AgentHUD 2>/dev/null || true
	open $(APP)

hooks:
	python3 bin/install-hooks.py "$(CURDIR)/bin/agent-hud-send"

# Cursor 1.7+ keeps its own hooks.json; reload the Cursor window afterwards.
hooks-cursor:
	python3 bin/install-hooks.py --cursor

# App logic (Swift), the hook/reporter scripts (Python) and the extension's
# pacing policy (node). Run before pushing.
test:
	cd app && swift test
	python3 tests/test_scripts.py
	node tests/test_extension.mjs

clean:
	rm -rf app/.build dist

# Pull, rebuild and relaunch — the app runs from this clone, so the repo is
# the update unit, not the .app.
update:
	bash bin/agent-hud-update

# Remove the app, LaunchAgents, hooks and caches from this Mac (repo stays).
uninstall:
	bash bin/agent-hud-uninstall
