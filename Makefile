APP := dist/AgentHUD.app
BIN := app/.build/release/AgentHUD
# Stamped into the bundle so the app can answer "what am I running" — the
# update check has nothing to compare against otherwise.
VERSION := $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

.PHONY: build bundle run playground preview hooks hooks-cursor test clean uninstall update

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

# A sandboxed copy to try things in: separate bundle id (so macOS lets both
# run and they get separate settings), port 48086, its own reporter, and the
# panel hung 180pt below the notch so the live one is untouched.
PLAY := dist/AgentHUD-Playground.app

playground: bundle
	rm -rf $(PLAY)
	cp -R $(APP) $(PLAY)
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.dhruv.agenthud.playground" $(PLAY)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleName AgentHUD Playground" $(PLAY)/Contents/Info.plist
	codesign --force --sign - $(PLAY)
	-pkill -f "AgentHUD-Playground" 2>/dev/null || true
	AGENT_HUD_PLAYGROUND=1 open -n $(PLAY)
	@echo "playground on :48086, floating clear of the notch — the live HUD is untouched"

# Same sandbox, but framed in a drawn MacBook window instead of floating.
# One or the other: both at once renders the same panel twice.
preview: playground
	@sleep 1
	-pkill -f "AgentHUD-Playground" 2>/dev/null || true
	AGENT_HUD_PLAYGROUND=1 AGENT_HUD_PREVIEW=1 open -n $(PLAY)
	@echo "MacBook preview window open"

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
