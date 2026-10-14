APP_NAME := Quick Chat
APP      := build/$(APP_NAME).app
PREFIX   ?= /Applications
DEST     := $(PREFIX)/$(APP_NAME).app

# Quit any running copy (any bundle id/location). SIGTERM makes the app restore ChatGPT's keymap.
QUIT := pkill -x QuickChat && while pgrep -xq QuickChat; do sleep 0.2; done; true

.PHONY: app build run install uninstall clean

app:
	./scripts/build-app.sh

build: app

run: app
	@$(QUIT)
	open "$(APP)"

install: app
	@$(QUIT)
	mkdir -p "$(PREFIX)"
	rm -rf "$(DEST)"
	ditto "$(APP)" "$(DEST)"
	@echo "Installed $(DEST)"

uninstall:
	@$(QUIT)
	rm -rf "$(DEST)"

clean:
	rm -rf .build build
