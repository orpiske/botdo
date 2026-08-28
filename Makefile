# botdo — build and install
#
# Common usage:
#   make                 # build the release binary
#   make install         # install to /usr/local/bin (use: sudo make install)
#   make install PREFIX=$HOME/.local   # install to ~/.local/bin
#   make install BINDIR=$HOME/bin      # install to a specific directory
#   make uninstall
#   make clean

CARGO  ?= cargo
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin

BIN    := botdo
TARGET := target/release/$(BIN)

.PHONY: all build install uninstall clean

all: build

build:
	$(CARGO) build --release

install: build
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 755 "$(TARGET)" "$(DESTDIR)$(BINDIR)/$(BIN)"
	@echo "Installed $(BIN) -> $(DESTDIR)$(BINDIR)/$(BIN)"

uninstall:
	rm -f "$(DESTDIR)$(BINDIR)/$(BIN)"
	@echo "Removed $(DESTDIR)$(BINDIR)/$(BIN)"

clean:
	$(CARGO) clean
