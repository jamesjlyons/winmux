import Foundation

extension PinnedDesktop {
    /// One migration boundary for the former separate app/page pin records.
    public func savedView(browserPins: [BrowserSidebarPin], appPins: [NativeAppSidebarPin]) -> SavedView? {
        let pages = browserPins.filter { $0.workspaceName == workspaceName }
        let apps = appPins.filter { $0.workspaceName == workspaceName }
        let records = pages.map { ViewMember(id: $0.id, title: $0.title,
            launch: .browser(profileID: $0.profileID, url: $0.url), surfaceID: $0.surfaceID, iconPNGBase64: $0.iconPNGBase64) } +
            apps.map { ViewMember(id: $0.id, title: $0.title,
                launch: .application(bundleIdentifier: $0.bundleIdentifier, bundlePath: $0.bundlePath), surfaceID: $0.surfaceID) }
        guard Set(records.map(\.id)).count == records.count else { return nil }
        let indexed = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let members = memberIDs.compactMap { indexed[$0] }
        guard members.count == memberIDs.count else { return nil }
        let view = SavedView(id: id, spaceID: spaceID, workspaceName: workspaceName, title: title,
            isPinned: true, members: members, layout: layout, selectedMember: selectedMember, formerRegularIndex: formerRegularIndex)
        return view.isValid ? view : nil
    }
}

extension PinnedViewGroup {
    /// Legacy templates include closed members that cannot be recovered from
    /// the live tree. Convert the template itself, without waiting for owners.
    public func savedView(spaceID: String, workspaceName: String,
                          browserPins: [BrowserSidebarPin], appPins: [NativeAppSidebarPin]) -> SavedView? {
        guard isValid(in: workspaceName), let nodes = template.roots[workspaceName] else { return nil }
        let desktop = PinnedDesktop(id: id, spaceID: spaceID, workspaceName: workspaceName,
            title: title, kind: .group, memberIDs: nodes.flatMap(\.surfaces).compactMap { members[$0] },
            layout: nodes.compactMap { ViewLayoutNode.capture($0, tree: template, members: members) },
            selectedMember: template.activeSurfaces[id].flatMap { members[$0] })
        return desktop.savedView(browserPins: browserPins, appPins: appPins)
    }
}
