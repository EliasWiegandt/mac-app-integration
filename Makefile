APP := .build/LocalCalendarMCP.app
BIN := .build/release/LocalCalendarMCP

.PHONY: build run clean
build:
	swift build -c release
	mkdir -p $(APP)/Contents/MacOS
	cp $(BIN) $(APP)/Contents/MacOS/LocalCalendarMCP
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --deep --sign - $(APP)

run: build
	$(APP)/Contents/MacOS/LocalCalendarMCP --host 127.0.0.1 --port 8765

clean:
	swift package clean
