import Testing
import XTouchOneCoreMIDI

struct AutoConnectionTests {
    @Test func choosesTheRememberedOnlineInputWithSeveralDevices() {
        #expect(XTouchOneAutoConnection.selectInput(preferred: 2, online: [1, 2]) == 2)
        #expect(XTouchOneAutoConnection.selectInput(preferred: 2, online: [1]) == nil)
    }

    @Test func discoveryRequiresExactlyOneCandidateWithoutAnExplicitSelection() {
        #expect(XTouchOneAutoConnection.selectInput(preferred: nil, online: [1]) == 1)
        #expect(XTouchOneAutoConnection.selectInput(preferred: nil, online: []) == nil)
        #expect(XTouchOneAutoConnection.selectInput(preferred: nil, online: [1, 2]) == nil)
    }
}
