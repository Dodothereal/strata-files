import AppKit

/// Sidebar | one or two panes (with the status bar under them) | inspector.
final class MainSplitViewController: NSSplitViewController {
    let sidebar = SidebarViewController()
    let panes: PaneContainerViewController
    let inspector = InspectorViewController()
    let status = StatusBarController()
    let scopeBar = SearchScopeBar()
    let inspectorItem: NSSplitViewItem

    init(firstPane: PaneHostViewController) {
        panes = PaneContainerViewController(first: firstPane)
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        super.init(nibName: nil, bundle: nil)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        sidebarItem.addBottomAlignedAccessoryViewController(SidebarFooterController())

        let contentItem = NSSplitViewItem(viewController: panes)
        contentItem.minimumThickness = 380
        contentItem.addBottomAlignedAccessoryViewController(status)
        scopeBar.isHidden = true
        contentItem.addTopAlignedAccessoryViewController(scopeBar)

        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 440

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(inspectorItem)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.autosaveName = "StrataMainSplit"
    }
}
