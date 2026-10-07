import Foundation
import XCTest
@testable import WorkspaceCore

final class SurfacePaneTests: XCTestCase {
    private let a = SurfaceID.nativeWindow(UUID())
    private let b = SurfaceID.browserTab(profile: UUID(), tab: UUID())
    private let c = SurfaceID.nativeWindow(UUID())
    private let d = SurfaceID.browserTab(profile: UUID(), tab: UUID())

    func testWholeStackPlacementPreservesIdentitySelectionAndOtherArrangements() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b, c, d], in: "work")
        XCTAssertTrue(tree.group(b, with: a, layout: .stack))
        let stack = try XCTUnwrap(tree.stack(containing: a))
        tree.select(b)
        XCTAssertTrue(tree.group(d, with: c, layout: .vertical))
        let split = try XCTUnwrap(tree.containingGroup(of: c))
        tree.setWeights([SurfacePane.group(stack).weightKey: 300, SurfacePane.group(split).weightKey: 700])

        XCTAssertTrue(tree.place(.group(stack), beside: .surface(d), toward: .down))

        XCTAssertEqual(tree.group(stack)?.surfaces, [a, b])
        XCTAssertEqual(tree.activeSurfaces[stack], b)
        XCTAssertEqual(tree.group(split)?.surfaces, [c, d, a, b])
        XCTAssertEqual(tree.layouts[split], .vertical)
        XCTAssertEqual(tree.weights[SurfacePane.group(stack).weightKey], 300)
        XCTAssertEqual(tree.weights[SurfacePane.group(split).weightKey], 700)
        XCTAssertEqual(try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)), tree)
    }

    func testPlacementTargetsStackAsAUnitAndRejectsAncestorOverlap() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "work")
        XCTAssertTrue(tree.group(b, with: a, layout: .stack))
        let stack = try XCTUnwrap(tree.stack(containing: a))
        let before = tree
        XCTAssertFalse(tree.place(.group(stack), beside: .surface(a), toward: .left))
        XCTAssertFalse(tree.swap(.group(stack), .surface(a)))
        XCTAssertEqual(tree, before)

        XCTAssertTrue(tree.place(.surface(c), beside: .surface(b), toward: .down))
        let parent = try XCTUnwrap(tree.containingGroup(of: c))
        XCTAssertNotEqual(parent, stack)
        XCTAssertEqual(tree.layouts[parent], .vertical)
        XCTAssertEqual(tree.group(stack)?.surfaces, [a, b])
        XCTAssertEqual(tree.ancestors(of: .group(stack)).map(\.pane), [.group(parent)])
    }

    func testProportionsSizeNestedStackOrAncestorAxisWithoutChangingOtherWeights() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b, c, d], in: "work")
        XCTAssertTrue(tree.group(b, with: a, layout: .stack))
        let stack = try XCTUnwrap(tree.stack(containing: a))
        XCTAssertTrue(tree.place(.surface(c), beside: .group(stack), toward: .down))
        let split = try XCTUnwrap(tree.containingGroup(of: c))
        tree.setWeights([a.description: 9, b.description: 11])

        XCTAssertTrue(tree.setProportion(0.75, of: .surface(a), axis: .vertical))
        XCTAssertEqual(try XCTUnwrap(tree.allocation(of: .surface(b), axis: .vertical)).ratio, 0.75, accuracy: 0.00001)
        XCTAssertEqual(tree.weights[a.description], 9)
        XCTAssertEqual(tree.weights[b.description], 11)
        XCTAssertTrue(tree.setProportion(0.2, of: .surface(a), axis: .horizontal))
        XCTAssertEqual(try XCTUnwrap(tree.allocation(of: .group(split))).ratio, 0.2, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(tree.allocation(of: .group(stack))).ratio, 0.75, accuracy: 0.00001)
        let before = tree
        for invalid in [Double.nan, .infinity, 0, -1, 1.01] { XCTAssertFalse(tree.setProportion(invalid, of: .surface(a))) }
        XCTAssertFalse(tree.setProportion(0.5, of: .surface(a), axis: .stack))
        XCTAssertEqual(tree, before)
    }

    func testCrossViewSwapKeepsInternalSelectionAndReplacesInvalidAncestorSelection() throws {
        var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "work"); tree.reconcile([d], in: "other")
        XCTAssertTrue(tree.group(b, with: a, layout: .stack))
        let stack = try XCTUnwrap(tree.stack(containing: a))
        XCTAssertTrue(tree.place(.surface(c), beside: .group(stack), toward: .down))
        let split = try XCTUnwrap(tree.containingGroup(of: c))
        tree.select(b)
        tree.setWeights([SurfacePane.group(stack).weightKey: 70, d.description: 30])

        XCTAssertTrue(tree.swap(.group(stack), .surface(d)))

        XCTAssertEqual(tree.workspace(of: a), "other")
        XCTAssertEqual(tree.workspace(of: d), "work")
        XCTAssertEqual(tree.activeSurfaces[stack], b)
        XCTAssertEqual(tree.activeSurfaces[split], d)
        XCTAssertEqual(tree.weights[SurfacePane.group(stack).weightKey], 30)
        XCTAssertEqual(tree.weights[d.description], 70)
        XCTAssertEqual(try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)), tree)
    }

    func testRepeatedMixedPaneEditsPreserveEveryMemberAndValidMetadata() throws {
        var tree = SurfaceTree(); let members = [a, b, c, d]
        tree.reconcile(members, in: "work")
        for index in 0..<160 {
            let first = members[index % members.count], second = members[(index + 1) % members.count]
            let source = index % 3 == 0 ? tree.containingGroup(of: first).map(SurfacePane.group) ?? .surface(first) : .surface(first)
            _ = tree.place(source, beside: .surface(second), toward: [.left, .down, .right, .up][index % 4])
            _ = tree.setProportion(Double((index % 9) + 1) / 10, of: .surface(first))
            _ = tree.swap(.surface(first), .surface(second))
            XCTAssertEqual(Set(tree.roots.values.flatMap { $0.flatMap(\.surfaces) }), Set(members))
            XCTAssertEqual(try JSONDecoder().decode(SurfaceTree.self, from: JSONEncoder().encode(tree)), tree)
        }
    }

    func testCollapsingStackPreservesItsOuterAllocationInsteadOfAnInnerWeight() throws {
        for operation in ["place", "arrange", "remove"] {
            var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "work")
            XCTAssertTrue(tree.group(b, with: a))
            let group = try XCTUnwrap(tree.stack(containing: a))
            tree.setWeights([SurfacePane.group(group).weightKey: 70, c.description: 30, a.description: 200, b.description: 100])
            switch operation {
            case "place": XCTAssertTrue(tree.place(.surface(b), beside: .surface(c), toward: .down))
            case "arrange": XCTAssertTrue(tree.arrange([.surface(b)], in: "other"))
            default: tree.remove(b)
            }
            XCTAssertEqual(tree.weights[a.description], 70, operation)
            XCTAssertEqual(try XCTUnwrap(tree.allocation(of: .surface(a))).ratio, 0.7, accuracy: 0.00001, operation)
        }
        var tree = SurfaceTree(); tree.reconcile([a, b, c], in: "work")
        XCTAssertTrue(tree.group(b, with: a))
        tree.setWeights([a.description: 200, c.description: 30])
        tree.remove(b)
        XCTAssertNil(tree.weights[a.description], "An unspecified outer weight must not inherit an unrelated inner weight")
        XCTAssertEqual(try XCTUnwrap(tree.allocation(of: .surface(a))).ratio, 0.5, accuracy: 0.00001)
    }
}
