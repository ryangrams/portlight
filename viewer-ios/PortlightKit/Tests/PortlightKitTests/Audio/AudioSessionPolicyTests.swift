import Testing
@testable import PortlightKit

@Suite("Audio · session policy")
struct AudioSessionPolicyTests {
    private func activePolicy() -> AudioSessionPolicy {
        var policy = AudioSessionPolicy()
        _ = policy.handle(.enable)
        _ = policy.handle(.activationSucceeded)
        return policy
    }

    @Test("enabling activates the playback session, then resumes output")
    func enable() {
        var policy = AudioSessionPolicy()
        #expect(policy.state == .off)
        #expect(policy.handle(.enable) == [.activate])
        #expect(policy.handle(.enable) == [])
        #expect(policy.handle(.activationSucceeded) == [.resumeOutput])
        #expect(policy.state == .active)
    }

    @Test("disabling stops output before deactivating (notifying other apps)")
    func disable() {
        var policy = activePolicy()
        #expect(policy.handle(.disable) == [.suspendOutput, .deactivate])
        #expect(policy.state == .off)
        #expect(policy.handle(.disable) == [])
    }

    @Test("an interruption suspends output and resumes only when the system says so")
    func interruption() {
        var policy = activePolicy()
        #expect(policy.handle(.interruptionBegan) == [.suspendOutput])
        #expect(policy.state == .interrupted)
        #expect(policy.handle(.interruptionEnded(shouldResume: true)) == [.activate])
        #expect(policy.handle(.activationSucceeded) == [.resumeOutput])
        #expect(policy.state == .active)

        _ = policy.handle(.interruptionBegan)
        #expect(policy.handle(.interruptionEnded(shouldResume: false)) == [])
        #expect(policy.state == .paused(.interruptionEnded))
        #expect(policy.handle(.userResume) == [.activate])
        #expect(policy.handle(.activationSucceeded) == [.resumeOutput])
    }

    @Test("Resume works while interrupted: the system may never report the interruption's end")
    func resumeWhileInterrupted() {
        var policy = activePolicy()
        _ = policy.handle(.interruptionBegan)
        #expect(policy.handle(.userResume) == [.activate])
        #expect(policy.handle(.activationSucceeded) == [.resumeOutput])
        #expect(policy.state == .active)
        // A late end for the interruption that was already resumed changes nothing.
        #expect(policy.handle(.interruptionEnded(shouldResume: true)) == [])
        #expect(policy.state == .active)
    }

    @Test("a Resume refused during an interruption still resumes automatically when it ends")
    func refusedResumeKeepsWaitingForTheEnd() {
        var policy = activePolicy()
        _ = policy.handle(.interruptionBegan)
        #expect(policy.handle(.userResume) == [.activate])
        #expect(policy.handle(.activationFailed("call in progress")) == [])
        #expect(policy.state == .interrupted)
        #expect(policy.handle(.interruptionEnded(shouldResume: true)) == [.activate])
        #expect(policy.handle(.activationSucceeded) == [.resumeOutput])
        #expect(policy.state == .active)
    }

    @Test("a failed activation after the interruption ended is reported, and Resume retries")
    func failureAfterTheEndIsReported() {
        var policy = activePolicy()
        _ = policy.handle(.interruptionBegan)
        #expect(policy.handle(.interruptionEnded(shouldResume: true)) == [.activate])
        #expect(policy.handle(.activationFailed("busy")) == [])
        #expect(policy.state == .failed("busy"))
        #expect(policy.handle(.userResume) == [.activate])
    }

    @Test("a media-services reset during an interruption can be resumed")
    func mediaServicesResetDuringAnInterruption() {
        var policy = activePolicy()
        _ = policy.handle(.interruptionBegan)
        _ = policy.handle(.mediaServicesLost)
        #expect(policy.handle(.mediaServicesReset) == [.suspendOutput])
        #expect(policy.handle(.userResume) == [.activate])
        #expect(policy.handle(.activationSucceeded) == [.resumeOutput])
        #expect(policy.state == .active)
    }

    @Test("losing the output device pauses until the user resumes")
    func outputDeviceRemoved() {
        var policy = activePolicy()
        #expect(policy.handle(.outputDeviceRemoved) == [.suspendOutput])
        #expect(policy.state == .paused(.outputDeviceRemoved))
        #expect(policy.handle(.outputDeviceRemoved) == [])
        #expect(policy.handle(.userResume) == [.activate])
        #expect(policy.handle(.activationSucceeded) == [.resumeOutput])
        #expect(policy.state == .active)
    }

    @Test("a device removed during an interruption keeps audio off the speaker when it ends")
    func deviceRemovedDuringInterruption() {
        var policy = activePolicy()
        _ = policy.handle(.interruptionBegan)
        #expect(policy.handle(.outputDeviceRemoved) == [])
        #expect(policy.handle(.interruptionEnded(shouldResume: true)) == [])
        #expect(policy.state == .paused(.outputDeviceRemoved))
    }

    @Test("an activation failure is reported and Resume retries")
    func activationFailure() {
        var policy = AudioSessionPolicy()
        _ = policy.handle(.enable)
        #expect(policy.handle(.activationFailed("busy")) == [])
        #expect(policy.state == .failed("busy"))
        #expect(policy.handle(.userResume) == [.activate])
    }

    @Test("a media-services reset rebuilds output and reactivates only when playing")
    func mediaServicesReset() {
        var active = activePolicy()
        #expect(active.handle(.mediaServicesLost) == [.suspendOutput])
        #expect(active.handle(.mediaServicesReset) == [.suspendOutput, .activate])

        var paused = activePolicy()
        _ = paused.handle(.outputDeviceRemoved)
        #expect(paused.handle(.mediaServicesReset) == [.suspendOutput])

        var off = AudioSessionPolicy()
        #expect(off.handle(.mediaServicesReset) == [])
    }

    @Test("system events are ignored while audio is off; a late activation is undone")
    func offIgnoresEvents() {
        var policy = AudioSessionPolicy()
        #expect(policy.handle(.interruptionBegan) == [])
        #expect(policy.handle(.interruptionEnded(shouldResume: true)) == [])
        #expect(policy.handle(.outputDeviceRemoved) == [])
        #expect(policy.handle(.userResume) == [])
        #expect(policy.state == .off)

        _ = policy.handle(.enable)
        _ = policy.handle(.disable)
        #expect(policy.handle(.activationSucceeded) == [.deactivate])
        #expect(policy.state == .off)
    }
}
