APP := dist/AgentHUD.app
BIN := app/.build/release/AgentHUD

.PHONY: build bundle run hooks test clean uninstall

build:
	cd app && swift build -c release

bundle: build
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/AgentHUD
	cp app/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

run: bundle
	-killall AgentHUD 2>/dev/null || true
	open $(APP)

hooks:
	python3 bin/install-hooks.py "$(CURDIR)/bin/agent-hud-send"

# App logic (Swift), the hook/reporter scripts (Python) and the extension's
# pacing policy (node). Run before pushing.
test:
	cd app && swift test
	python3 tests/test_scripts.py
	node tests/test_extension.mjs

clean:
	rm -rf app/.build dist

# Remove the app, LaunchAgents, hooks and caches from this Mac (repo stays).
uninstall:
	bash bin/agent-hud-uninstall
