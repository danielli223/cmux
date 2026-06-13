import Darwin
import Foundation
import XCTest

/// End-to-end UI test that launches the real app, enables niri-mode, opens terminals, and
/// asserts the core niri invariant against the live workspace: **opening a terminal appends a
/// fixed-width column and pans the viewport — it never shrinks existing terminals.**
///
/// Assertions are made against the app's authoritative strip model via the `niri_status`
/// control-socket query (column intrinsic widths, x positions, scroll offset, focus), which is
/// far more robust than scraping GPU-portal terminal frames out of the accessibility tree.
final class NiriStripModeUITests: XCTestCase {
    private var socketPath = ""
    private let launchTag = "ui-tests-niri-strip"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        socketPath = "/tmp/cmux-debug-niri-ui-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    func testOpeningColumnsNeverShrinksTerminalsAndPansViewport() throws {
        let app = launchApp()
        defer { app.terminate() }
        XCTAssertTrue(waitForPong(timeout: 8.0), "control socket never answered ping at \(socketPath)")

        // Enable niri-mode on the selected workspace.
        XCTAssertEqual(socketCommand("niri_mode on"), "OK strip")

        var status = try requireStatus()
        XCTAssertEqual(status.mode, "strip")
        XCTAssertGreaterThanOrEqual(status.columns.count, 1, "expected a seeded column for the initial terminal")
        let firstColumnWidth = status.columns[0].width

        // Open two more terminals -> three columns total.
        XCTAssertTrue(socketCommand("niri_open")?.hasPrefix("OK") == true)
        XCTAssertTrue(socketCommand("niri_open")?.hasPrefix("OK") == true)

        status = try requireStatus()
        XCTAssertEqual(status.columns.count, 3, "each open should append a column")

        // Invariant 1: no existing terminal shrank — every column kept its intrinsic width.
        for (index, column) in status.columns.enumerated() {
            XCTAssertEqual(
                column.width, firstColumnWidth, accuracy: 0.5,
                "column \(index) width changed (\(column.width) != \(firstColumnWidth)) — opening must not resize"
            )
        }

        // Invariant 2: the strip is now wider than the viewport (columns laid end to end).
        XCTAssertGreaterThan(
            status.totalContentWidth, status.viewportWidth,
            "three columns should make the strip exceed the viewport"
        )
        // Columns are laid left-to-right at increasing x positions, none overlapping.
        let xs = status.columns.map(\.x)
        XCTAssertEqual(xs, xs.sorted(), "columns must be ordered left to right")

        // Invariant 3: opening the (off-screen) new column panned the viewport to reveal it.
        XCTAssertGreaterThan(status.scrollOffset, 0, "opening an off-screen column should pan the viewport")
        XCTAssertEqual(status.focusedColumnIndex, 2, "the newest column should be focused")

        // focus-column-left pans back toward the previous column without resizing.
        XCTAssertEqual(socketCommand("niri_focus left"), "OK")
        let afterFocus = try requireStatus()
        XCTAssertEqual(afterFocus.focusedColumnIndex, 1)
        for column in afterFocus.columns {
            XCTAssertEqual(column.width, firstColumnWidth, accuracy: 0.5, "focus must not resize columns")
        }

        // move-column-left reorders on the strip; widths still unchanged.
        XCTAssertEqual(socketCommand("niri_move left"), "OK")
        let afterMove = try requireStatus()
        XCTAssertEqual(afterMove.columns.count, 3)
        for column in afterMove.columns {
            XCTAssertEqual(column.width, firstColumnWidth, accuracy: 0.5, "move must not resize columns")
        }

        // Toggling the mode off returns to tiling (and leaves terminals intact).
        XCTAssertEqual(socketCommand("niri_mode off"), "OK tiling")
        let afterDisable = try requireStatus()
        XCTAssertEqual(afterDisable.mode, "tiling")
    }

    func testStackedWindowAddsWithinColumn() throws {
        let app = launchApp()
        defer { app.terminate() }
        XCTAssertTrue(waitForPong(timeout: 8.0))
        XCTAssertEqual(socketCommand("niri_mode on"), "OK strip")

        let before = try requireStatus()
        let columnsBefore = before.columns.count

        XCTAssertTrue(socketCommand("niri_open_stacked")?.hasPrefix("OK") == true)
        let after = try requireStatus()

        // A stacked window does not add a column; it stacks inside the focused one.
        XCTAssertEqual(after.columns.count, columnsBefore, "stacked window must not create a column")
        XCTAssertTrue(
            after.columns.contains { $0.windowPanelIds.count >= 2 },
            "the focused column should now hold a vertical stack of >= 2 windows"
        )
    }

    /// Render-level: columns derive their width from the live content area (≈ half), and the
    /// terminal actually renders at full width — its grid reports tens of columns, not the
    /// 1-character sliver the SwiftUI `.position()` hosting used to produce.
    func testColumnsRenderFullWidthAtHalfContentArea() throws {
        let app = launchApp()
        defer { app.terminate() }
        XCTAssertTrue(waitForPong(timeout: 8.0))
        XCTAssertEqual(socketCommand("niri_mode on"), "OK strip")
        XCTAssertTrue(socketCommand("niri_open")?.hasPrefix("OK") == true) // two columns

        let status = try requireStatus()
        XCTAssertGreaterThanOrEqual(status.columns.count, 2)
        let half = status.viewportWidth / 2
        for (index, column) in status.columns.enumerated() {
            XCTAssertEqual(column.width, half, accuracy: 6,
                           "column \(index) width should be half the content area (\(half)), not a constant")
        }
        // The focused terminal's grid is full-width — the definitive anti-sliver render check.
        let focused = status.columns.first(where: { $0.focused })
        let gridCols = focused?.gridCols ?? 0
        XCTAssertGreaterThan(gridCols, 20,
                             "focused terminal must render at full width (grid \(gridCols) cols), not a sliver")
    }

    /// Render-level: opening the overview captures one text thumbnail per column.
    func testOverviewCapturesOneThumbnailPerColumn() throws {
        let app = launchApp()
        defer { app.terminate() }
        XCTAssertTrue(waitForPong(timeout: 8.0))
        XCTAssertEqual(socketCommand("niri_mode on"), "OK strip")
        XCTAssertTrue(socketCommand("niri_open")?.hasPrefix("OK") == true)

        let before = try requireStatus()
        XCTAssertEqual(socketCommand("niri_overview on"), "OK overview")
        let overview = try requireStatus()
        XCTAssertTrue(overview.overviewActive)
        XCTAssertEqual(overview.overviewThumbnailCount, before.columns.count,
                       "overview should capture one thumbnail per column")

        // Selecting commits and routes focus; a keystroke after lands in the selected terminal.
        XCTAssertEqual(socketCommand("niri_overview_move right"), "OK 1")
        XCTAssertTrue(socketCommand("niri_overview_select")?.hasPrefix("OK") == true)
        let after = try requireStatus()
        XCTAssertFalse(after.overviewActive)
        XCTAssertEqual(after.focusedColumnIndex, 1)
    }

    // MARK: - Launch / socket helpers

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-socketControlMode", "automation"]
        app.launchEnvironment["CMUX_SOCKET_PATH"] = socketPath
        app.launchEnvironment["CMUX_UI_TEST_SOCKET_SANITY"] = "1"
        app.launchEnvironment["CMUX_TAG"] = launchTag
        app.launch()
        if !app.wait(for: .runningForeground, timeout: 12.0), app.state == .runningBackground {
            app.activate()
        }
        return app
    }

    private func waitForPong(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if socketCommand("ping") == "PONG" { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return socketCommand("ping") == "PONG"
    }

    private func socketCommand(_ command: String) -> String? {
        ControlSocketClient(path: socketPath, responseTimeout: 2.0).sendLine(command)
    }

    // MARK: - niri_status parsing

    private struct StripColumnStatus {
        let width: Double
        let x: Double
        let focused: Bool
        let gridCols: Int?
        let windowPanelIds: [String]
    }

    private struct StripStatus {
        let mode: String
        let viewportWidth: Double
        let scrollOffset: Double
        let totalContentWidth: Double
        let focusedColumnIndex: Int
        let overviewActive: Bool
        let overviewThumbnailCount: Int
        let columns: [StripColumnStatus]
    }

    private func requireStatus(file: StaticString = #filePath, line: UInt = #line) throws -> StripStatus {
        guard let raw = socketCommand("niri_status") else {
            XCTFail("niri_status returned nil", file: file, line: line)
            throw XCTSkip("no status")
        }
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("niri_status was not JSON: \(raw)", file: file, line: line)
            throw XCTSkip("bad status")
        }
        let columnsRaw = object["columns"] as? [[String: Any]] ?? []
        let columns = columnsRaw.map { column in
            StripColumnStatus(
                width: (column["width"] as? Double) ?? 0,
                x: (column["x"] as? Double) ?? 0,
                focused: (column["focused"] as? Bool) ?? false,
                gridCols: column["gridCols"] as? Int,
                windowPanelIds: (column["windowPanelIds"] as? [String]) ?? []
            )
        }
        return StripStatus(
            mode: (object["mode"] as? String) ?? "",
            viewportWidth: (object["viewportWidth"] as? Double) ?? 0,
            scrollOffset: (object["scrollOffset"] as? Double) ?? 0,
            totalContentWidth: (object["totalContentWidth"] as? Double) ?? 0,
            focusedColumnIndex: (object["focusedColumnIndex"] as? Int) ?? 0,
            overviewActive: (object["overviewActive"] as? Bool) ?? false,
            overviewThumbnailCount: (object["overviewThumbnailCount"] as? Int) ?? 0,
            columns: columns
        )
    }

    /// Minimal blocking Unix-domain-socket line client (mirrors `AutomationSocketUITests`).
    private final class ControlSocketClient {
        private let path: String
        private let responseTimeout: TimeInterval

        init(path: String, responseTimeout: TimeInterval) {
            self.path = path
            self.responseTimeout = responseTimeout
        }

        func sendLine(_ line: String) -> String? {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return nil }
            defer { close(fd) }

            var timeout = timeval(
                tv_sec: Int(responseTimeout),
                tv_usec: Int32((responseTimeout - floor(responseTimeout)) * 1_000_000)
            )
            withUnsafePointer(to: &timeout) { ptr in
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            }

            var addr = sockaddr_un()
            memset(&addr, 0, MemoryLayout<sockaddr_un>.size)
            addr.sun_family = sa_family_t(AF_UNIX)

            let pathBytes = Array(path.utf8CString)
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            guard pathBytes.count <= maxLen else { return nil }
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let raw = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                for index in 0..<pathBytes.count {
                    raw[index] = pathBytes[index]
                }
            }

            let pathOffset = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 0
            let addrLen = socklen_t(pathOffset + pathBytes.count)
            let connected = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.connect(fd, sockaddrPtr, addrLen)
                }
            }
            guard connected == 0 else { return nil }

            let payload = Array((line + "\n").utf8)
            let wrote = payload.withUnsafeBytes { rawBuffer -> Bool in
                guard let baseAddress = rawBuffer.baseAddress else { return true }
                return Darwin.write(fd, baseAddress, rawBuffer.count) == rawBuffer.count
            }
            guard wrote else { return nil }

            var response = [UInt8]()
            var buffer = [UInt8](repeating: 0, count: 8192)
            // niri_status JSON can exceed one read; loop until newline-terminated or EOF.
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                response.append(contentsOf: buffer[0..<count])
                if response.last == UInt8(ascii: "\n") { break }
            }
            guard !response.isEmpty else { return nil }
            return String(bytes: response, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
