import Foundation
import Testing

@testable import computer_use_mcp

@Suite struct AppResolverTests {
    @Test func pidScanReachesOldestAndNewestProcesses() {
        let pids = allProcessIDs()

        // launchd (pid 1) predates every other process. The kernel lists pids
        // newest-first, so it only shows up when the full return count is
        // honored — misreading the count as bytes truncated it away.
        #expect(pids.contains(1))
        #expect(pids.contains(getpid()))
        #expect(pids.allSatisfy { $0 > 0 })
    }
}
