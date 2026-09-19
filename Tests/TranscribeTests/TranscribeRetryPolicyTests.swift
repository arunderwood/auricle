import Foundation
import Testing
@testable import Transcribe

/// Plays back a fixed list of terminations, one per attempt, and records how
/// many attempts were asked for and the numbers they were given.
private actor AttemptScript {
    private var remaining: [TranscribeRetryPolicy.Termination]
    private(set) var attemptNumbers: [Int] = []

    init(_ terminations: [TranscribeRetryPolicy.Termination]) {
        remaining = terminations
    }

    func next(_ attemptNumber: Int) -> TranscribeRetryPolicy.Termination {
        attemptNumbers.append(attemptNumber)
        return remaining.isEmpty ? .exited(0) : remaining.removeFirst()
    }
}

private struct LaunchFailure: Error, Equatable {}

private func run(_ script: AttemptScript) async -> TranscribeRetryPolicy.Outcome {
    await TranscribeRetryPolicy.run { attemptNumber in
        await script.next(attemptNumber)
    }
}

@Test func aFirstAttemptThatSucceedsIsNotRetried() async {
    let script = AttemptScript([.exited(0)])

    let outcome = await run(script)

    #expect(outcome == .succeeded(attempts: 1))
    #expect(await script.attemptNumbers == [1])
}

@Test func anExit75ThenASuccessSucceedsOnTheSecondAttempt() async {
    let script = AttemptScript([.exited(75), .exited(0)])

    let outcome = await run(script)

    #expect(outcome == .succeeded(attempts: 2))
    #expect(await script.attemptNumbers == [1, 2])
}

@Test func aSignalKillThenASuccessSucceedsOnTheSecondAttempt() async {
    let script = AttemptScript([.signaled(9), .exited(0)])

    let outcome = await run(script)

    #expect(outcome == .succeeded(attempts: 2))
    #expect(await script.attemptNumbers == [1, 2])
}

@Test func twoRetryableFailuresStopAfterExactlyTwoAttempts() async {
    let script = AttemptScript([.exited(75), .exited(75), .exited(0)])

    let outcome = await run(script)

    #expect(outcome == .exhausted(attempts: 2, lastTermination: .exited(75)))
    #expect(await script.attemptNumbers == [1, 2])
}

@Test func aSignalKilledLastAttemptIsReportedAsSuch() async {
    let script = AttemptScript([.exited(75), .signaled(11)])

    let outcome = await run(script)

    #expect(outcome == .exhausted(attempts: 2, lastTermination: .signaled(11)))
}

@Test func aPermanentFailureIsNotRetried() async {
    let script = AttemptScript([.exited(2), .exited(0)])

    let outcome = await run(script)

    #expect(outcome == .failed(attempts: 1, termination: .exited(2)))
    #expect(await script.attemptNumbers == [1])
}

@Test func aPermanentFailureOnTheRetryEndsTheRunAsFailedNotExhausted() async {
    let script = AttemptScript([.signaled(9), .exited(2)])

    let outcome = await run(script)

    #expect(outcome == .failed(attempts: 2, termination: .exited(2)))
}

@Test(arguments: [Int32(1), 2, 3, 74, 76, 130])
func onlyExit75IsRetryableAmongExitCodes(status: Int32) async {
    let script = AttemptScript([.exited(status)])

    let outcome = await run(script)

    #expect(outcome == .failed(attempts: 1, termination: .exited(status)))
}

@Test(arguments: [SIGINT, SIGTERM, SIGHUP, SIGQUIT])
func aUserOrParentCancellationSignalIsNeverRetried(signal: Int32) async {
    let script = AttemptScript([.signaled(signal), .exited(0)])

    let outcome = await run(script)

    #expect(outcome == .failed(attempts: 1, termination: .signaled(signal)))
    #expect(await script.attemptNumbers == [1])
}

@Test(arguments: [SIGINT, SIGTERM, SIGHUP, SIGQUIT])
func aCancellationSignalOnTheRetryEndsTheRunAsFailedNotExhausted(signal: Int32) async {
    let script = AttemptScript([.exited(75), .signaled(signal)])

    let outcome = await run(script)

    #expect(outcome == .failed(attempts: 2, termination: .signaled(signal)))
}

@Test(arguments: [SIGABRT, SIGBUS, SIGILL, SIGKILL, SIGSEGV, SIGTRAP])
func aCrashStyleSignalIsRetried(signal: Int32) async {
    let script = AttemptScript([.signaled(signal), .exited(0)])

    let outcome = await run(script)

    #expect(outcome == .succeeded(attempts: 2))
}

@Test func anErrorFromAnAttemptPropagatesWithoutARetry() async {
    let script = AttemptScript([])

    await #expect(throws: LaunchFailure()) {
        _ = try await TranscribeRetryPolicy.run { attemptNumber in
            _ = await script.next(attemptNumber)
            throw LaunchFailure()
        }
    }

    #expect(await script.attemptNumbers == [1])
}

@Test func theMaximumIsOneInitialAttemptPlusOneRetry() {
    #expect(TranscribeRetryPolicy.maximumAttempts == 2)
}
