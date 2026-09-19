import Foundation
import Testing
@testable import Origami

struct ProfileCycleTests {
    @Test func orderedCycleWrapsInBothDirections() {
        let ids = [UUID(), UUID(), UUID()]
        #expect(ProfileCycle.next(ids, current: ids[0], forward: true) == ids[1])
        #expect(ProfileCycle.next(ids, current: ids[2], forward: true) == ids[0])
        #expect(ProfileCycle.next(ids, current: ids[0], forward: false) == ids[2])
        #expect(ProfileCycle.next(ids, current: ids[2], forward: false) == ids[1])
        #expect(ProfileCycle.next([ids[0]], current: ids[0], forward: true) == nil)
        #expect(ProfileCycle.next(ids, current: UUID(), forward: true) == nil)
    }
}
