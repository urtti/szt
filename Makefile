PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin

.PHONY: build install uninstall clean

build:
	swift build -c release

install: build
	install -d "$(BINDIR)"
	install -m 755 .build/release/szt "$(BINDIR)/szt"

uninstall:
	rm -f "$(BINDIR)/szt"

clean:
	rm -rf .build
