struct WorkspaceSidebarDropPreviewTabItem: Hashable {
    let title: String
    let appName: String
    let appBundleIdentifier: String?
    let appBundlePath: String?
}

struct WorkspaceSidebarDropPreviewViewModel: Hashable {
    let sourceWindowId: UInt32?
    let sourceSubject: WorkspaceSidebarSurfaceDragSubject?
    let label: String
    let appName: String
    let appBundleIdentifier: String?
    let appBundlePath: String?
    let targetWorkspaceName: String?
    let targetsNewWorkspace: Bool
    let targetProjectId: WorkspaceProjectId?
    let targetMonitorScopeId: String?
    let isTabGroup: Bool
    let windowCount: Int
    let tabItems: [WorkspaceSidebarDropPreviewTabItem]
    var intentLabel: String?

    init(
        sourceWindowId: UInt32? = nil,
        sourceSubject: WorkspaceSidebarSurfaceDragSubject? = nil,
        label: String,
        appName: String,
        appBundleIdentifier: String? = nil,
        appBundlePath: String? = nil,
        targetWorkspaceName: String?,
        targetsNewWorkspace: Bool,
        targetProjectId: WorkspaceProjectId? = nil,
        targetMonitorScopeId: String? = nil,
        isTabGroup: Bool,
        windowCount: Int,
        tabItems: [WorkspaceSidebarDropPreviewTabItem] = []
    ) {
        self.sourceWindowId = sourceWindowId
        self.sourceSubject = sourceSubject
        self.label = label
        self.appName = appName
        self.appBundleIdentifier = appBundleIdentifier
        self.appBundlePath = appBundlePath
        self.targetWorkspaceName = targetWorkspaceName
        self.targetsNewWorkspace = targetsNewWorkspace
        self.targetProjectId = targetProjectId
        self.targetMonitorScopeId = targetMonitorScopeId
        self.isTabGroup = isTabGroup
        self.windowCount = windowCount
        self.tabItems = tabItems
    }
}
