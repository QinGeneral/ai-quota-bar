APP := QuotaBar.app
BIN := $(APP)/Contents/MacOS/QuotaBar
SOURCES := Sources/decrypt.c Sources/Models.swift Sources/Service.swift Sources/App.swift Sources/SelfTest.swift
INSTALL := $(HOME)/Applications/QuotaBar.app
ARCH := $(shell uname -m)

.PHONY: all test install open clean

all: $(BIN)

$(BIN): $(SOURCES) Info.plist Sources/Bridging.h
	mkdir -p $(APP)/Contents/MacOS
	cp Info.plist $(APP)/Contents/Info.plist
	swiftc -swift-version 5 -O -parse-as-library -target $(ARCH)-apple-macosx13.0 \
		-I Sources -import-objc-header Sources/Bridging.h \
		-framework AppKit -framework Security -framework ServiceManagement -lsqlite3 \
		-o $(BIN) $(SOURCES)
	codesign --force --sign - $(APP)

test: $(BIN)
	$(BIN) --self-test

install: test
	mkdir -p "$(HOME)/Applications"
	-killall QuotaBar 2>/dev/null || true
	rm -rf "$(INSTALL)"
	cp -R $(APP) "$(INSTALL)"
	xattr -cr "$(INSTALL)"
	codesign --force --sign - "$(INSTALL)"
	open "$(INSTALL)"

open: $(BIN)
	open $(APP)

clean:
	rm -rf $(APP)
