import Testing

// swift-testing fails the whole `swift test` run with "no tests found" if zero
// tests execute anywhere in the package, even when every other target's suite
// is intentionally empty pending the target's own story. This is that one test.
@Test func packageTestRunnerDiscoversAtLeastOneTest() {}
