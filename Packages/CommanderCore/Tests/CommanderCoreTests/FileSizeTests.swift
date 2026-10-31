import Testing
@testable import CommanderCore

@Test(arguments: [
    (Int64(0), "0 B"),
    (999, "999 B"),
    (1_000, "1.0 KB"),
    (412_600_000, "412.6 MB"),
    (1_670_000_000, "1.67 GB"),
    (999_949, "999.9 KB"),
    (999_950, "1.0 MB"),
    (999_949_999, "999.9 MB"),
    (999_950_000, "1.00 GB"),
])
func formatsSizes(bytes: Int64, expected: String) {
    #expect(FileSize.format(bytes) == expected)
}
