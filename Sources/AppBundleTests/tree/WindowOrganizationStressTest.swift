@testable import AppBundle
import Common
import WorkspaceCore
import XCTest

@MainActor
final class WindowOrganizationStressTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests(); config.windowTabs.enabled = true }
    override func tearDown() async throws { setUpWorkspacesForTests() }

    /// Seeded state-machine stress: a real controller and native bindings, with
    /// invariants checked after every arrival, close, move, split and reorder.
    func testNativeWindowChurnAcrossThreeSpaces() throws {
        for seed: UInt64 in [7, 19, 73] {
            setUpWorkspacesForTests(); config.windowTabs.enabled = true; config.newItemPlacement = .tile
            let controller = BrowserWorkspaceController()
            controller.usesSurfaceTree = true
            let spaces = (0..<3).map { index in
                let workspace = Workspace.get(byName: "Stress \(index)")
                workspace.assignProject(createWorkspaceProject().id)
                workspace.retainsEmptyView = true
                return workspace
            }
            var state = seed
            func pick(_ count: Int) -> Int {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Int((state >> 32) % UInt64(count))
            }
            var windows: [TestWindow] = []
            var nextID: UInt32 = 5000
            for step in 0..<600 {
                let space = spaces[pick(spaces.count)]
                _ = space.focusWorkspace()
                let operation = windows.count < 6 ? 0 : pick(8)
                switch operation {
                case 0 where windows.count < 30:
                    nextID += 1
                    let window = TestWindow.new(id: nextID, parent: space.rootTilingContainer)
                    windows.append(window)
                    controller.placeOrdinaryNativeArrival(window, in: space)
                case 1:
                    let window = windows[pick(windows.count)]
                    XCTAssertTrue(controller.editOrganization(of: window.surfaceID, movingTo: space) { _ in true })
                case 2, 3:
                    let local = windows.filter { $0.nodeWorkspace === space }
                    if local.count >= 2 {
                        let source = local[pick(local.count)].surfaceID
                        let target = local.first { $0.surfaceID != source }!.surfaceID
                        XCTAssertTrue(controller.editOrganization(of: source) { tree in
                            operation == 2 ? tree.insertIntoStack(source, with: target)
                                : tree.split(source, beside: target, layout: pick(2) == 0 ? .horizontal : .vertical, before: pick(2) == 0)
                        })
                    }
                case 4:
                    let removed = windows.remove(at: pick(windows.count))
                    removed.unbindFromParent()
                case 5:
                    let window = windows[pick(windows.count)]
                    if let group = controller.surfaceTree.stack(containing: window.surfaceID),
                       case .group(_, let children) = controller.surfaceTree.group(group),
                       let original = children.firstIndex(where: { $0.pane == .surface(window.surfaceID) }), children.count > 1 {
                        let destination = (original + 1) % children.count
                        XCTAssertTrue(reorderSharedStackTab(.surface(window.surfaceID), stack: group, to: destination,
                            expectedOrder: children.map(\.pane), controller: controller))
                        let changed = controller.surfaceTree
                        XCTAssertFalse(reorderSharedStackTab(.surface(window.surfaceID), stack: group, to: original,
                            expectedOrder: children.map(\.pane), controller: controller))
                        XCTAssertEqual(controller.surfaceTree, changed)
                    }
                case 6:
                    let snapshot = try XCTUnwrap(controller.capturePlacementSnapshot()).validated()
                    let decoded = try JSONDecoder().decode(SurfaceWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot)).validated()
                    XCTAssertEqual(decoded, snapshot)
                default:
                    let window = windows[pick(windows.count)]
                    if let group = controller.surfaceTree.stack(containing: window.surfaceID),
                       controller.workspaceName(forGroup: group) != space.name {
                        let members = controller.surfaceTree.group(group)
                        XCTAssertTrue(controller.moveGroup(group, to: space))
                        XCTAssertEqual(controller.surfaceTree.group(group), members)
                    }
                }
                controller.reconcileSharedOrganization()
                let all = controller.surfaceTree.roots.values.flatMap { $0.flatMap(\.surfaces) }
                XCTAssertEqual(all.count, windows.count, "seed=\(seed) step=\(step)")
                XCTAssertEqual(Set(all), Set(windows.map(\.surfaceID)), "seed=\(seed) step=\(step)")
                XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated(), "seed=\(seed) step=\(step)")
                for window in windows {
                    XCTAssertEqual(controller.surfaceTree.workspace(of: window.surfaceID), window.nodeWorkspace?.name)
                    XCTAssertEqual(controller.workspaceName(for: window.surfaceID), window.nodeWorkspace?.name)
                }
                for workspace in spaces {
                    let plan = controller.plannedLayout(in: workspace)
                    XCTAssertTrue(plan.surfaces.allSatisfy { $0.frame.isValid })
                    XCTAssertTrue(plan.surfaces.filter(\.visible).allSatisfy { _ in workspace.isVisible })
                }
            }
        }
    }

    func testNewWindowArrivalRetainsCapturedSpaceDuringSpaceSwitches() throws {
        for placement: NewItemPlacement in [.newView, .tile, .stackNative, .floatNative] {
            setUpWorkspacesForTests(); config.newItemPlacement = placement
            let controller = BrowserWorkspaceController(); controller.usesSurfaceTree = true
            let spaces = (0..<3).map { index in
                let workspace = Workspace.get(byName: "Arrival \(index)")
                workspace.assignProject(createWorkspaceProject().id)
                workspace.retainsEmptyView = true
                return workspace
            }
            for index in 0..<90 {
                let captured = spaces[index % 3]
                _ = captured.focusWorkspace()
                let window = TestWindow.new(id: UInt32(8000 + index), parent: captured.rootTilingContainer)
                if placement == .floatNative { window.bindAsFloatingWindow(to: captured) }
                _ = spaces[(index + 1) % 3].focusWorkspace()
                controller.placeOrdinaryNativeArrival(window, in: captured)
                controller.reconcileSharedOrganization()
                XCTAssertEqual(window.nodeWorkspace?.projectId, captured.projectId)
                if placement == .newView { XCTAssertEqual(window.nodeWorkspace?.allLeafWindowsRecursive.count, 1) }
            }
            XCTAssertNoThrow(try controller.capturePlacementSnapshot()?.validated())
        }
    }
}
