APP := dist/AgentHUD.app
BIN := app/.build/release/AgentHUD
SWIFT_FLAGS ?= -Xswiftc -warnings-as-errors
# Stamped into the bundle so the app can answer "what am I running" — the
# update check has nothing to compare against otherwise.
COMMIT := $(shell git rev-parse HEAD 2>/dev/null || echo unknown)
VERSION ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)

.PHONY: build bundle run playground playground-edge demo preview hooks hooks-cursor hooks-codex watch test clean uninstall update

build:
	cd app && swift build -c release $(SWIFT_FLAGS)

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/AgentHUD
	cp app/Info.plist $(APP)/Contents/Info.plist
	cp -R bin $(APP)/Contents/Resources/bin
	find $(APP)/Contents/Resources/bin -name __pycache__ -type d -prune -exec rm -rf {} +
	/usr/libexec/PlistBuddy -c "Add :AgentHUDVersion string $(VERSION)" $(APP)/Contents/Info.plist >/dev/null 2>&1 \
	  || /usr/libexec/PlistBuddy -c "Set :AgentHUDVersion $(VERSION)" $(APP)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Add :AgentHUDCommit string $(COMMIT)" $(APP)/Contents/Info.plist
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

# The side notch on the MacBook's own (notched) screen: the sandbox forced
# into edge mode, so clamshell behaviour can be tried with the lid open.
playground-edge: bundle
	rm -rf $(PLAY)
	cp -R $(APP) $(PLAY)
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.dhruv.agenthud.playground" $(PLAY)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleName AgentHUD Playground" $(PLAY)/Contents/Info.plist
	codesign --force --sign - $(PLAY)
	-pkill -f "AgentHUD-Playground" 2>/dev/null || true
	AGENT_HUD_PLAYGROUND=1 AGENT_HUD_EDGE=$${EDGE:-right} open -n $(PLAY)
	@echo "playground in edge mode on the $${EDGE:-right} edge (EDGE=left to flip)"

# The sandbox filled with invented sessions, for staging the README's
# screenshots — no real names, hostnames or clipboard ever reach a PNG.
demo: bundle
	rm -rf $(PLAY)
	cp -R $(APP) $(PLAY)
	/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier dev.dhruv.agenthud.playground" $(PLAY)/Contents/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleName AgentHUD Playground" $(PLAY)/Contents/Info.plist
	codesign --force --sign - $(PLAY)
	-pkill -f "AgentHUD-Playground" 2>/dev/null || true
	AGENT_HUD_PLAYGROUND=1 AGENT_HUD_NO_REPORTER=1 AGENT_HUD_PREVIEW=1 open -n $(PLAY)
	@sleep 6
	python3 bin/agent-hud-demo
	@echo "playground seeded with synthetic sessions — the live HUD is untouched"

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
	python3 -m unittest discover -s tests -p 'test_*.py'
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

# Optional richer Codex lifecycle hooks require review in Codex /hooks.
hooks-codex:
	python3 bin/install-hooks.py --codex --with-hooks

watch:
	xcodegen generate --spec watch/project.yml
	xcodebuild -project watch/AgentHUDWatch.xcodeproj -scheme AgentHUDWatch -sdk watchsimulator -configuration Release -derivedDataPath watch/build CODE_SIGNING_ALLOWED=NO build
