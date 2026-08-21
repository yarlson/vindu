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
SWIFT_TEST_FLAGS ?=
BORDER_TEST_BINARY := .build/vindu-tests/border-engine-tests

.PHONY: build test test-border check-template release install uninstall clean

build:
	swift build

test: check-template test-border
	swift test $(TEST_FLAGS) $(SWIFT_TEST_FLAGS)

test-border:
	@mkdir -p $(dir $(BORDER_TEST_BINARY))
	xcrun clang -std=c11 -g -O1 -fsanitize=address,undefined -fno-omit-frame-pointer \
		-I Sources/VinduBorderEngine -I Sources/VinduBorderEngine/include \
		-framework CoreFoundation -framework CoreGraphics \
		Tests/VinduBorderEngineTests/BorderEngineTests.c -o $(BORDER_TEST_BINARY)
	$(BORDER_TEST_BINARY)

release:
	swift build -c release
	# Ad-hoc signing keeps a stable code identity so the Accessibility grant
	# survives rebuilds of the same source tree.
	codesign --force --sign - .build/release/vindud
	codesign --force --sign - .build/release/vinductl

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
