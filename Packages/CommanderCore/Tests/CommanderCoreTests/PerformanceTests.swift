import Foundation
import Testing
import CommanderCore

/// Measures the M1 target. Run with: COMMANDER_PERF=1 swift test -c release -Xswiftc -enable-testing --filter hundredThousand
@Test(.enabled(if: ProcessInfo.processInfo.environment["COMMANDER_PERF"] != nil))
func hundredThousandFiles() async throws {
    let temp = try TempFolder()
    for index in 0..<100_000 {
        FileManager.default.createFile(atPath: temp.url.appending(path: "file-\(index).txt").path, contents: nil)
    }
    let clock = ContinuousClock()
    let listing = try await clock.measure {
        let listing = try await LocalSource().list(temp.url, sort: FileSort())
        #expect(listing.entries.count == 100_000)
    }
    print("Listed and sorted 100,000 files in \(listing)")
    // The app must stay responsive, so a full load has to finish within a beat.
    #expect(listing < .seconds(3))
}
