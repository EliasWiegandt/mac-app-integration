APP := .build/LocalCalendarMCP.app
BIN := .build/release/LocalCalendarMCP

.PHONY: build run clean
build:
	swift build -c release
	mkdir -p $(APP)/Contents/MacOS
	mkdir -p $(APP)/Contents/Resources
	cp $(BIN) $(APP)/Contents/MacOS/LocalCalendarMCP
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	cp Resources/MailBridge.applescript $(APP)/Contents/Resources/MailBridge.applescript
	cp Resources/CalendarInviteBridge.applescript $(APP)/Contents/Resources/CalendarInviteBridge.applescript
	codesign --force --deep --sign - $(APP)

run: build
	$(APP)/Contents/MacOS/LocalCalendarMCP --host 127.0.0.1 --port 8765

clean:
	swift package clean
