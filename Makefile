# Topaz Trading Dashboard — Build Targets
#
# Usage:
#   make          Build debug with Cocoa (default)
#   make qt6      Build debug with Qt6
#   make release  Build optimized release (Cocoa)
#   make clean    Remove build artifacts
#   make run      Build and run

LAZBUILD  := /Applications/lazarus/lazbuild
LAZDIR    := /Applications/lazarus
PROJECT   := TopazDashboard.lpi
BINARY    := TopazDashboard
SYMLINK   := libapollo.a
APOLLO_LIB := $(HOME)/Development/apollo/target/release/libapollo.a

.PHONY: all debug qt6 release clean run

all: debug

$(SYMLINK):
	@ln -sf $(APOLLO_LIB) $(SYMLINK)

debug: $(SYMLINK)
	@$(LAZBUILD) --lazarusdir=$(LAZDIR) --build-mode=Debug $(PROJECT) 2>&1 \
		| grep -v "^Info:\|^Hint:\|^Note:\|^Search\|^Setup\|^SetPrimary\|^TProject" \
		|| true
	@test -f $(BINARY) && echo "Build OK [Cocoa]: $(BINARY) ($$(du -h $(BINARY) | cut -f1))" || echo "BUILD FAILED"

qt6: $(SYMLINK)
	@$(LAZBUILD) --lazarusdir=$(LAZDIR) --ws=qt6 --build-mode=Debug $(PROJECT) 2>&1 \
		| grep -v "^Info:\|^Hint:\|^Note:\|^Search\|^Setup\|^SetPrimary\|^TProject" \
		|| true
	@test -f $(BINARY) && echo "Build OK [Qt6]: $(BINARY) ($$(du -h $(BINARY) | cut -f1))" || echo "BUILD FAILED"

release: $(SYMLINK)
	@$(LAZBUILD) --lazarusdir=$(LAZDIR) --build-mode=Release $(PROJECT) 2>&1 \
		| grep -v "^Info:\|^Hint:\|^Note:\|^Search\|^Setup\|^SetPrimary\|^TProject" \
		|| true
	@test -f $(BINARY) && echo "Build OK [Release]: $(BINARY) ($$(du -h $(BINARY) | cut -f1))" || echo "BUILD FAILED"

run: debug
	./$(BINARY)

run-qt6: qt6
	DYLD_FRAMEWORK_PATH=/opt/homebrew/lib ./$(BINARY)

clean:
	rm -rf lib/
	rm -f $(BINARY)
	rm -f $(SYMLINK)
	rm -f linkfiles*.res symbol_order*.fpc
	rm -f *.res *.lps
	rm -rf $(BINARY).app
