LABEL      := io.github.olalatab
APP        := $(HOME)/Applications/Olalatab.app
APP_BIN    := $(APP)/Contents/MacOS/olalatab
# Command-line shortcut to the app's executable (for --debug, --print-default-config).
BIN        := $(HOME)/.local/bin/olalatab
PLIST      := $(HOME)/Library/LaunchAgents/$(LABEL).plist
CONFIG     := $(HOME)/.config/olalatab/config.json
LOG        := $(HOME)/Library/Logs/olalatab.log
DOMAIN     := gui/$(shell id -u)
# A real certificate (Apple Development or Developer ID) makes macOS keep the Accessibility and
# Screen Recording grants across rebuilds. Without one, the app is ad-hoc signed and must be
# re-allowed after each install. Override with: make install SIGN_IDENTITY="Apple Development: Name (TEAMID)"
SIGN_IDENTITY ?= $(or $(shell security find-identity -v -p codesigning 2>/dev/null \
	| grep -E '"(Apple Development|Developer ID Application):' | head -1 | sed -E 's/.*"(.*)"/\1/'),-)

.PHONY: build test app install uninstall restart stop logs permissions bench idle

build:
	swift build -c release

test:
	swift test

## Wraps the binary in an .app bundle: macOS tracks Accessibility and Screen Recording far more
## reliably for a bundle with an identifier than for a bare executable.
## The app is only rebuilt when the binary or Info.plist actually changed, to keep its grants.
BUILD_ID   := $(APP)/Contents/Resources/build-id

app: build
	@id=$$(cat .build/release/olalatab support/Info.plist | shasum -a 256 | cut -d' ' -f1); \
	if [ "$$(cat $(BUILD_ID) 2>/dev/null)" = "$$id" ] && codesign --verify $(APP) 2>/dev/null; then \
		echo "Olalatab.app is up to date: keeping it (and its permissions)."; \
	else \
		set -e; \
		rm -rf $(APP); \
		install -d $(APP)/Contents/MacOS $(APP)/Contents/Resources; \
		install -m 644 support/Info.plist $(APP)/Contents/Info.plist; \
		install -m 755 .build/release/olalatab $(APP_BIN); \
		echo "$$id" > $(BUILD_ID); \
		codesign --force --options runtime --sign "$(SIGN_IDENTITY)" --identifier $(LABEL) $(APP); \
		if [ "$(SIGN_IDENTITY)" = "-" ]; then \
			echo "Olalatab.app updated, signed ad hoc: turn it off and on in Accessibility and Screen Recording, then make restart."; \
		else \
			echo "Olalatab.app updated, signed with $(SIGN_IDENTITY)."; \
		fi; \
	fi

## Installs Olalatab.app, a default config and a LaunchAgent that starts it at login.
install: app
	install -d $(dir $(BIN)) $(dir $(PLIST)) $(dir $(CONFIG))
	ln -sf $(APP_BIN) $(BIN)
	@test -f $(CONFIG) || $(APP_BIN) --print-default-config > $(CONFIG)
	sed -e 's|@BIN@|$(APP_BIN)|g' -e 's|@LABEL@|$(LABEL)|g' -e 's|@LOG@|$(LOG)|g' \
		support/launchagent.plist > $(PLIST)
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	@# bootout is asynchronous: wait until the old agent is gone before loading the new one.
	@while launchctl print $(DOMAIN)/$(LABEL) >/dev/null 2>&1; do sleep 0.2; done
	launchctl bootstrap $(DOMAIN) $(PLIST)
	@echo "Installed. Allow Olalatab in Accessibility and Screen Recording (make permissions), then run: make restart"

uninstall:
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true
	rm -rf $(PLIST) $(BIN) $(APP)
	@echo "Removed. Your config is kept at $(CONFIG)."

## Reload after editing the config or granting permissions.
restart:
	launchctl kickstart -k $(DOMAIN)/$(LABEL)

## Stops olalatab until the next login or make restart / make install.
stop:
	@launchctl bootout $(DOMAIN)/$(LABEL) 2>/dev/null || true

logs:
	tail -f $(LOG)

## Opens Accessibility, then Screen Recording, and reveals Olalatab.app to drag into each list.
permissions:
	open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
	open -R $(APP)
	@printf "Drag Olalatab.app into Accessibility, then press Return for Screen Recording… "; read _
	open "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
	open -R $(APP)

## Latency benchmark: 10, 100 and 300 windows of TextEdit and Chrome (see bench/run.sh).
## Takes over the keyboard and screen for a few minutes. Results in bench/results/.
bench: app
	swift build -c release --product olala-fixture
	bench/run.sh $(ARGS)

## CPU and memory at rest of the installed agent.
idle:
	bench/idle.sh
