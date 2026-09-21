// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Who made this and what it is called. Kept in the library so the app, the
/// installer scripts and the tests all read the same values.
public enum GaugeVersion {
    public static let string = "1.0"
    public static let author = "Wefreefly"
    public static let authorEmail = "wefreefly@thaisimply.com"
    public static let builtWith = "Built with Claude Code"
    public static let licence = "Apache License 2.0"
    public static let licenceURL = "https://www.apache.org/licenses/LICENSE-2.0"
    public static let copyright = "Copyright 2026 Wefreefly"
    public static let tagline = "A menu bar system monitor for macOS."

    /// What the About pane and the disk image both print.
    public static var credit: String { "\(author) · \(authorEmail)" }
}
