# Topaz Trading Dashboard — Build Targets
#
# Usage:
#   make          Build debug (default)
#   make release  Build optimized release
#   make clean    Remove build artifacts
#   make run      Build and run

LAZBUILD  := /Applications/lazarus/lazbuild
LAZDIR    := /Applications/lazarus
PROJECT   := TopazDashboard.lpi
BINARY    := TopazDashboard
SYMLINK   := libapollo.a
APOLLO_LIB := $(HOME)/Development/apollo/target/release/libapollo.a

.PHONY: all debug release clean run

all: debug

$(SYMLINK):
	@ln -sf $(APOLLO_LIB) $(SYMLINK)

debug: $(SYMLINK)
	@$(LAZBUILD) --lazarusdir=$(LAZDIR) --build-mode=Debug $(PROJECT) 2>&1 \
		| grep -v "^Info:\|^Hint:\|^Note:\|^Search\|^Setup\|^SetPrimary\|^TProject" \
		|| true
	@test -f $(BINARY) && echo "Build OK: $(BINARY) ($$(du -h $(BINARY) | cut -f1))" || echo "BUILD FAILED"

release: $(SYMLINK)
	@$(LAZBUILD) --lazarusdir=$(LAZDIR) --build-mode=Release $(PROJECT) 2>&1 \
		| grep -v "^Info:\|^Hint:\|^Note:\|^Search\|^Setup\|^SetPrimary\|^TProject" \
		|| true
	@test -f $(BINARY) && echo "Build OK: $(BINARY) ($$(du -h $(BINARY) | cut -f1))" || echo "BUILD FAILED"

run: debug
	./$(BINARY)

clean:
	rm -rf lib/
	rm -f $(BINARY)
	rm -f $(SYMLINK)
	rm -f linkfiles*.res symbol_order*.fpc
	rm -f *.res *.lps
	rm -rf $(BINARY).app
