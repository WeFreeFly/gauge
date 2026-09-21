import Foundation

/// A minimal test harness.
///
/// XCTest is part of Xcode, not of the Command Line Tools, and this project is
/// built to need only the latter. The suite is therefore a plain executable:
/// `swift run GaugeTests`, exit code 0 when everything passes.
final class Harness {
    private var currentSuite = ""
    private var failures: [String] = []
    private var checks = 0

    func suite(_ name: String, _ body: () -> Void) {
        currentSuite = name
        print("\n\(name)")
        body()
    }

    func test(_ name: String, _ body: () -> Void) {
        let before = failures.count
        body()
        let symbol = failures.count == before ? "  ✓" : "  ✗"
        print("\(symbol) \(name)")
    }

    // MARK: Assertions

    func expect(_ condition: Bool, _ message: @autoclosure () -> String,
                line: UInt = #line) {
        checks += 1
        guard !condition else { return }
        failures.append("\(currentSuite):\(line) — \(message())")
    }

    func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String = "",
                             line: UInt = #line) {
        checks += 1
        guard actual != expected else { return }
        let prefix = label.isEmpty ? "" : "\(label): "
        failures.append("\(currentSuite):\(line) — \(prefix)expected \(expected), got \(actual)")
    }

    func close(_ actual: Double, _ expected: Double, accuracy: Double = 0.001,
               _ label: String = "", line: UInt = #line) {
        checks += 1
        guard abs(actual - expected) > accuracy else { return }
        let prefix = label.isEmpty ? "" : "\(label): "
        failures.append("\(currentSuite):\(line) — \(prefix)expected \(expected) ±\(accuracy), got \(actual)")
    }

    func isNil<T>(_ value: T?, _ label: String = "", line: UInt = #line) {
        checks += 1
        guard let value else { return }
        let prefix = label.isEmpty ? "" : "\(label): "
        failures.append("\(currentSuite):\(line) — \(prefix)expected nil, got \(value)")
    }

    func notNil<T>(_ value: T?, _ label: String = "", line: UInt = #line) {
        checks += 1
        guard value == nil else { return }
        let prefix = label.isEmpty ? "" : "\(label): "
        failures.append("\(currentSuite):\(line) — \(prefix)expected a value, got nil")
    }

    // MARK: Result

    func finish() -> Int32 {
        print("\n" + String(repeating: "─", count: 48))
        if failures.isEmpty {
            print("\(checks) checks passed")
            return 0
        }
        print("\(failures.count) of \(checks) checks failed:\n")
        for failure in failures { print("  • \(failure)") }
        return 1
    }
}
