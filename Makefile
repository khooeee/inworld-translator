.PHONY: xcodegen ipa

xcodegen:
	xcodegen generate

METHOD ?= app-store
ARCHIVE_PATH ?= build/Translator.xcarchive
EXPORT_PATH ?= build/ipa

ipa:
	xcodegen generate
	mkdir -p build
	TEAM_ID="$${TEAM_ID:-$$(grep '^DEVELOPMENT_TEAM' App/Config/Local.xcconfig 2>/dev/null | cut -d= -f2 | tr -d ' \t')}"; \
	if [ -z "$$TEAM_ID" ]; then echo "Set DEVELOPMENT_TEAM in App/Config/Local.xcconfig or pass TEAM_ID=..."; exit 1; fi; \
	printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0">' '<dict>' "	<key>method</key><string>$(METHOD)</string>" "	<key>teamID</key><string>$$TEAM_ID</string>" '	<key>signingStyle</key><string>automatic</string>' '	<key>destination</key><string>export</string>' '</dict>' '</plist>' > build/ExportOptions.plist
	xcodebuild -project Translator.xcodeproj -scheme Translator -configuration Release \
		-destination 'generic/platform=iOS' \
		-archivePath $(ARCHIVE_PATH) archive
	xcodebuild -exportArchive \
		-archivePath $(ARCHIVE_PATH) \
		-exportOptionsPlist build/ExportOptions.plist \
		-exportPath $(EXPORT_PATH)
