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

.PHONY: build test release install uninstall clean

build:
	swift build

test:
	swift test $(TEST_FLAGS)

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
