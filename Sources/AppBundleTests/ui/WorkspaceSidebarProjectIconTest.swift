@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class WorkspaceSidebarProjectIconTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParsesIconsAndPreservesUnavailableNames() {
        let (parsed, errors) = parseConfig("""
        [workspace-sidebar.project-icons]
        default = 'house.fill'
        project-1 = 'future.symbol.winmux'
        """)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(parsed.workspaceSidebar.projectIcons, ["default": "house.fill", "project-1": "future.symbol.winmux"])
        let (legacy, legacyErrors) = parseConfig("[workspace-sidebar]\nenabled = true")
        XCTAssertTrue(legacyErrors.isEmpty)
        XCTAssertTrue(legacy.workspaceSidebar.projectIcons.isEmpty)
        let (_, invalidErrors) = parseConfig("[workspace-sidebar.project-icons]\ndefault = 42")
        XCTAssertFalse(invalidErrors.isEmpty)
    }

    func testConfigEditsRoundTripAndResetWithoutChangingOtherSections() {
        let initial = """
        # Keep my settings
        [workspace-sidebar.project-colors]
        default = '#FF8844'
        [mode.main.binding]
        alt-h = 'focus left'
        """
        let added = updateWorkspaceSidebarProjectIconConfig(in: initial, projectId: "project-1", symbolName: "house")
        let other = updateWorkspaceSidebarProjectIconConfig(in: added, projectId: "default", symbolName: "star")
        let replaced = updateWorkspaceSidebarProjectIconConfig(in: other, projectId: "project-1", symbolName: "folder.fill")
        let (parsed, errors) = parseConfig(replaced)
        XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(parsed.workspaceSidebar.projectIcons, ["default": "star", "project-1": "folder.fill"])
        XCTAssertTrue(replaced.contains(initial))
        let removed = updateWorkspaceSidebarProjectIconConfig(in: replaced, projectId: "project-1", symbolName: nil)
        XCTAssertEqual(parseConfig(removed).0.workspaceSidebar.projectIcons, ["default": "star"])
        let reset = updateWorkspaceSidebarProjectIconConfig(in: removed, projectId: "default", symbolName: nil)
        XCTAssertFalse(reset.contains("[workspace-sidebar.project-icons]"))
        XCTAssertTrue(reset.contains(initial))
    }

    func testFailedPersistenceLeavesExistingIconUnchanged() throws {
        config.workspaceSidebar.projectIcons["default"] = "star"
        enum WriteFailure: Error { case denied }
        for name: String? in ["house", nil] {
            XCTAssertThrowsError(try setWorkspaceSidebarProjectIcon(workspaceProjectDefaultId, symbolName: name) { _, _ in
                throw WriteFailure.denied
            })
            XCTAssertEqual(config.workspaceSidebar.projectIcons["default"], "star")
        }
    }

    func testSetNormalizesAndPersistsBeforePublishingThenClears() throws {
        try setWorkspaceSidebarProjectIcon(workspaceProjectDefaultId, symbolName: "  house.fill  ") { id, name in
            XCTAssertEqual(id, "default")
            XCTAssertEqual(name, "house.fill")
            XCTAssertNil(config.workspaceSidebar.projectIcons[id])
        }
        XCTAssertEqual(buildWorkspaceSidebarProjectViewModels().first?.iconName, "house.fill")
        try setWorkspaceSidebarProjectIcon(workspaceProjectDefaultId, symbolName: nil)
        XCTAssertNil(config.workspaceSidebar.projectIcons["default"])
    }

    func testUnsupportedSymbolFallsBackWithoutDeletingStoredName() {
        let unknown = "winmux.unavailable.symbol"
        config.workspaceSidebar.projectIcons["default"] = unknown
        let project = buildWorkspaceSidebarProjectViewModels().first
        XCTAssertEqual(project?.iconName, unknown)
        XCTAssertNil(WorkspaceSidebarSymbolImages.image(named: project?.iconName))
        XCTAssertNil(WorkspaceSidebarSymbolImages.image(named: nil))
        XCTAssertNotNil(WorkspaceSidebarSymbolImages.image(named: "house"))
        XCTAssertThrowsError(try setWorkspaceSidebarProjectIcon(workspaceProjectDefaultId, symbolName: unknown))
        XCTAssertEqual(config.workspaceSidebar.projectIcons["default"], unknown)
    }

    func testRenameAndReorderPreserveIconAndDeletionCleansItUp() throws {
        let project = createWorkspaceProject()
        try setWorkspaceSidebarProjectIcon(project.id, symbolName: "hammer.fill")
        try renameWorkspaceProject(project.id, displayName: "Research")
        reorderWorkspaceProject(project.id, to: workspaceProjectDefaultId)
        XCTAssertEqual(buildWorkspaceSidebarProjectViewModels().first?.iconName, "hammer.fill")
        XCTAssertEqual(config.workspaceSidebar.projectIcons[project.id.rawValue], "hammer.fill")
        try deleteWorkspaceProject(project.id)
        XCTAssertNil(config.workspaceSidebar.projectIcons[project.id.rawValue])
    }

    func testDeletedProjectCannotRecreateIconMetadata() throws {
        var didPersist = false
        try setWorkspaceSidebarProjectIcon("deleted", symbolName: "star") { _, _ in didPersist = true }
        XCTAssertFalse(didPersist)
        XCTAssertNil(config.workspaceSidebar.projectIcons["deleted"])
    }

    func testIconFollowsProjectAcrossMonitorSelections() throws {
        let left = WorkspaceNamingTestMonitor(
            monitorAppKitNsScreenScreensId: 1, name: "Left",
            rect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080), isMain: true
        )
        let right = WorkspaceNamingTestMonitor(
            monitorAppKitNsScreenScreensId: 2, name: "Right",
            rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080),
            visibleRect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080), isMain: false
        )
        setMonitorsForTests([left, right])
        let project = createWorkspaceProject()
        try setWorkspaceSidebarProjectIcon(project.id, symbolName: "music.note")
        _ = try XCTUnwrap(switchWorkspaceProject(project.id, on: left))
        _ = try XCTUnwrap(switchWorkspaceProject(project.id, on: right))
        XCTAssertEqual(activeWorkspaceProjectId(for: left), project.id)
        XCTAssertEqual(activeWorkspaceProjectId(for: right), project.id)
        XCTAssertEqual(buildWorkspaceSidebarProjectViewModels().first { $0.id == project.id }?.iconName, "music.note")
    }

    func testNativeMenuImageRetainsItsColorAndFitsFourteenPoints() throws {
        let project = WorkspaceSidebarProjectViewModel(id: "default", displayName: "Default", colorHex: "#FF0000", iconName: "star.fill")
        let image = WorkspaceSidebarSymbolImages.menuImage(for: project)
        XCTAssertFalse(image.isTemplate)
        XCTAssertEqual(image.size, NSSize(width: 14, height: 14))
        // lockFocus uses the current display profile. Compare with a solid sRGB control
        // rendered through the same path, rather than assuming a fixed resulting red value.
        let control = NSImage(size: image.size)
        control.lockFocus()
        NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1).setFill()
        NSRect(origin: .zero, size: image.size).fill()
        control.unlockFocus()
        func centerColor(_ image: NSImage) throws -> NSColor {
            let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            return try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        }
        let color = try centerColor(image)
        let expected = try centerColor(control)
        XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.03)
        XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.03)
        XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.03)
        XCTAssertGreaterThan(color.alphaComponent, 0.9)
        XCTAssertGreaterThan(color.redComponent - color.greenComponent, 0.5)
        XCTAssertGreaterThan(color.redComponent - color.blueComponent, 0.5)
    }

    func testWrittenIconsSurviveReload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try setWorkspaceSidebarProjectIcon(workspaceProjectDefaultId, symbolName: "pencil") { id, name in
            try updateWorkspaceSidebarProjectIconConfig(in: "", projectId: id, symbolName: name)
                .write(to: url, atomically: true, encoding: .utf8)
        }
        setUpWorkspacesForTests()
        let (restored, errors) = parseConfig(try String(contentsOf: url, encoding: .utf8))
        XCTAssertTrue(errors.isEmpty)
        config = restored
        XCTAssertEqual(buildWorkspaceSidebarProjectViewModels().first?.iconName, "pencil")
    }

    func testCatalogIsCompleteSortedUniqueAndIncludesKeywords() {
        let catalog = WorkspaceSidebarSymbolCatalog.bundled
        XCTAssertEqual(catalog.version, "27.0")
        XCTAssertGreaterThan(catalog.symbols.count, 9000)
        let names = catalog.symbols.map(\.name)
        XCTAssertEqual(names, names.sorted())
        XCTAssertEqual(names.count, Set(names).count)
        XCTAssertTrue(catalog.symbols.contains { !$0.keywords.isEmpty })
        XCTAssertTrue(catalog.symbols.contains { $0.macOS == "27.0" })
    }

    func testNameKeywordTokenSearchAndStableRanking() {
        let entries: [WorkspaceSidebarSymbolCatalog.Entry] = [
            .init(name: "calendar", keywords: ["date", "schedule"], macOS: "11.0"),
            .init(name: "star", keywords: ["favorite"], macOS: "11.0"),
            .init(name: "star.fill", keywords: ["favorite"], macOS: "11.0"),
        ]
        XCTAssertEqual(WorkspaceSidebarSymbolCatalog.search(" STAR ", in: entries).map(\.name), ["star", "star.fill"])
        XCTAssertEqual(WorkspaceSidebarSymbolCatalog.search("star fill", in: entries).map(\.name), ["star.fill"])
        XCTAssertEqual(WorkspaceSidebarSymbolCatalog.search("date", in: entries).map(\.name), ["calendar"])
        XCTAssertEqual(WorkspaceSidebarSymbolCatalog.search("favorite fill", in: entries).map(\.name), ["star.fill"])
        XCTAssertTrue(WorkspaceSidebarSymbolCatalog.search("qzxmissing", in: entries).isEmpty)
        XCTAssertEqual(WorkspaceSidebarSymbolCatalog.search("", in: entries), entries)
    }

    func testExactNameLookupWorksWithoutCatalogEntryAndAvoidsDuplicates() {
        let results = WorkspaceSidebarAvailableSymbols.search(" HOUSE.FILL ", in: [])
        XCTAssertEqual(results.map(\.name), ["house.fill"])
        XCTAssertEqual(WorkspaceSidebarAvailableSymbols.search("house.fill", in: results).count, 1)
        XCTAssertTrue(WorkspaceSidebarAvailableSymbols.search("winmux.missing.symbol", in: []).isEmpty)
    }

    func testOSAvailabilityAndGridNavigationBoundaries() {
        let symbol = WorkspaceSidebarSymbolCatalog.Entry(name: "example", keywords: [], macOS: "15.4")
        XCTAssertFalse(symbol.isAvailable(on: "13.0"))
        XCTAssertFalse(symbol.isAvailable(on: "15.3.9"))
        XCTAssertTrue(symbol.isAvailable(on: "15.4"))
        XCTAssertTrue(symbol.isAvailable(on: "15.10"))
        XCTAssertEqual(workspaceSidebarSymbolSelectionIndex(current: 0, offset: -1, count: 10), 0)
        XCTAssertEqual(workspaceSidebarSymbolSelectionIndex(current: 0, offset: 7, count: 10), 7)
        XCTAssertEqual(workspaceSidebarSymbolSelectionIndex(current: 7, offset: 7, count: 10), 9)
        XCTAssertEqual(workspaceSidebarSymbolSelectionIndex(current: 8, offset: -7, count: 10), 1)
        XCTAssertEqual(workspaceSidebarSymbolSelectionIndex(current: 0, offset: 1, count: 0), 0)
    }
}
