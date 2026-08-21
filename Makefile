# Command Line Tools ship Testing.framework outside the default search paths;
# full Xcode wires it up automatically. `make test` injects the CLT paths when
# Xcode is absent so `swift test` works either way.
CLT_FRAMEWORKS := /Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_TESTING_LIBS := /Library/Developer/CommandLineTools/Library/Developer/usr/lib

ifeq ($(wildcard $(CLT_FRAMEWORKS)/Testing.framework),)
TEST_FLAGS :=
else
TEST_FLAGS := -Xswiftc -F -Xswiftc $(CLT_FRAMEWORKS) \
	-Xlinker -F -Xlinker $(CLT_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(CLT_FRAMEWORKS) \
	-Xlinker -rpath -Xlinker $(CLT_TESTING_LIBS)
endif

PREFIX ?= /usr/local
VINDU_CODESIGN_IDENTITY ?= -
VINDUD_CODESIGN_IDENTIFIER := com.vindu.daemon
VINDUCTL_CODESIGN_IDENTIFIER := com.vindu.control

.PHONY: build test check-template release install uninstall clean

build:
	swift build

test: check-template
	swift test $(TEST_FLAGS)

release:
	swift build -c release
	codesign --force --identifier $(VINDUD_CODESIGN_IDENTIFIER) \
		--sign "$(VINDU_CODESIGN_IDENTITY)" .build/release/vindud
	codesign --force --identifier $(VINDUCTL_CODESIGN_IDENTIFIER) \
		--sign "$(VINDU_CODESIGN_IDENTITY)" .build/release/vinductl

install: release
	install -d $(PREFIX)/bin
	install .build/release/vindud $(PREFIX)/bin/vindud
	install .build/release/vinductl $(PREFIX)/bin/vinductl

uninstall:
	rm -f $(PREFIX)/bin/vindud $(PREFIX)/bin/vinductl

clean:
	swift package clean

# The default config template ships inside the binary; the example file must
# stay byte-identical so docs and first-run behavior never drift apart.
check-template:
	@sed -n '/^let defaultConfigTemplate = """$$/,/^"""$$/p' Sources/vindud/DefaultConfig.swift | sed '1d;$$d' | diff -u - examples/vindu.conf \
		|| { echo "examples/vindu.conf is out of sync with Sources/vindud/DefaultConfig.swift"; exit 1; }
