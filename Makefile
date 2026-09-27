lint:
	@command -v swiftlint >/dev/null 2>&1 || brew install swiftlint
	swiftlint lint --strict --no-cache

test-lint: lint

test:
	swift test --disable-swift-testing

ios-example:
	xcodebuild -project Example/iOS/KronosExample.xcodeproj -scheme KronosExample -destination 'generic/platform=iOS Simulator' build
