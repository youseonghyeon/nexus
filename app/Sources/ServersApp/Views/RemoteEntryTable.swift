// 원격 탐색 시트의 목록 (AppKit NSTableView). SwiftUI List 는 macOS 에서 더블클릭 제스처를 붙이면 한 번 클릭 선택이 늦거나 빠진다 —
// NSTableView 는 클릭 선택·doubleAction·키보드 이동이 네이티브라 그대로 쓴다.

import AppKit
import ServersCore
import SwiftUI

struct RemoteEntryTable: NSViewRepresentable {
    let entries: [RemoteEntry]
    /// 폴더만 고르는 모드: 파일은 흐리게
    let dimFiles: Bool
    /// ⌘·⇧ 클릭으로 여러 개 고르기 (다운로드)
    let allowsMultiple: Bool
    @Binding var selected: Set<RemoteEntry.ID>
    /// 더블클릭 (폴더면 들어가기)
    let onOpen: (RemoteEntry) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        let column = NSTableColumn(identifier: .init("name"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.allowsMultipleSelection = allowsMultiple
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked(_:))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let table = scroll.documentView as? NSTableView else { return }
        if context.coordinator.entries != entries || context.coordinator.dimFiles != dimFiles {
            context.coordinator.entries = entries
            context.coordinator.dimFiles = dimFiles
            table.reloadData()
        }
        table.allowsMultipleSelection = allowsMultiple
        // 바깥에서 선택을 바꿨을 때(폴더 이동 뒤 비움 등) 표를 맞춘다. 표에서 바꾼 건 delegate 가 이미 binding 에 썼으므로 같아서 건너뛴다.
        let rows = IndexSet(entries.indices.filter { selected.contains(entries[$0].id) })
        if table.selectedRowIndexes != rows {
            if rows.isEmpty { table.deselectAll(nil) } else { table.selectRowIndexes(rows, byExtendingSelection: false) }
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: RemoteEntryTable
        var entries: [RemoteEntry] = []
        var dimFiles = false

        init(_ parent: RemoteEntryTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let id = NSUserInterfaceItemIdentifier("entry")
            let cell: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView {
                cell = reused
            } else {
                cell = NSTableCellView()
                cell.identifier = id
                let image = NSImageView()
                let text = NSTextField(labelWithString: "")
                text.lineBreakMode = .byTruncatingMiddle
                image.translatesAutoresizingMaskIntoConstraints = false
                text.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.addSubview(text)
                cell.imageView = image
                cell.textField = text
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
            }
            let entry = entries[row]
            cell.textField?.stringValue = entry.name
            cell.textField?.textColor = (dimFiles && !entry.isDirectory) ? .tertiaryLabelColor : .labelColor
            cell.imageView?.image = NSImage(systemSymbolName: symbol(entry), accessibilityDescription: nil)
            cell.imageView?.contentTintColor = entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            let ids = Set(table.selectedRowIndexes.filter { $0 < entries.count }.map { entries[$0].id })
            if parent.selected != ids { parent.selected = ids }
        }

        @MainActor @objc func doubleClicked(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard (0..<entries.count).contains(row) else { return }
            parent.onOpen(entries[row])
        }

        private func symbol(_ entry: RemoteEntry) -> String {
            switch entry.kind {
            case .drive: return "internaldrive"
            case .directory: return "folder.fill"
            case .link: return "link"
            case .file: return "doc"
            }
        }
    }
}
