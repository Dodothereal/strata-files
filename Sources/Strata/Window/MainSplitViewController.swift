import AppKit

/// Sidebar | one or two panes (with the status bar under them) | inspector.
final class MainSplitViewController: NSSplitViewController {
    let sidebar = SidebarViewController()
    let panes: PaneContainerViewController
    let inspector = InspectorViewController()
    let status = StatusBarController()
    let scopeBar = SearchScopeBar()
    let noticeBar = NoticeBar()
    let inspectorItem: NSSplitViewItem

    init(firstPane: PaneHostViewController) {
        panes = PaneContainerViewController(first: firstPane)
        inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        super.init(nibName: nil, bundle: nil)

        // The minimums (180 + 320 + 240) fit inside the window's minimum width (760), so the panes never make the
        // window resize itself: a collapsed inspector peeking out in a narrow window did, and crashed AppKit mid-peek.
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320
        sidebarItem.addBottomAlignedAccessoryViewController(SidebarFooterController())

        let contentItem = NSSplitViewItem(viewController: panes)
        contentItem.minimumThickness = 320
        contentItem.addBottomAlignedAccessoryViewController(status)
        scopeBar.isHidden = true
        contentItem.addTopAlignedAccessoryViewController(scopeBar)
        noticeBar.isHidden = true
        contentItem.addTopAlignedAccessoryViewController(noticeBar)

        inspectorItem.minimumThickness = 240
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
