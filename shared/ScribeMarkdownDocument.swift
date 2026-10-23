import Foundation

/// Uses Foundation's Markdown parser, retaining inline formatting and block structure.
/// The saved source remains untouched for editing, syncing and export.
struct ScribeMarkdownDocument {
    struct Block: Identifiable {
        enum Kind: Equatable { case paragraph, heading(Int), code, table, divider }
        let id: Int
        var kind: Kind = .paragraph
        var text = AttributedString()
        var marker: String?
        var inList = false
        var listDepth = 0
        var quoted = false
        var tableID: Int?
        var rows: [Row] = []
        var columnCount = 0
        var columnAlignments: [PresentationIntent.TableColumn.Alignment] = []
    }
    struct Row: Identifiable {
        let id: Int
        let header: Bool
        var cells: [AttributedString]
    }
    let blocks: [Block]

    init(_ source: String) {
        guard let parsed = try? AttributedString(markdown: source,
            options: .init(interpretedSyntax: .full, failurePolicy: .throwError)) else {
            blocks = [Block(id: 0, text: AttributedString(source))]
            return
        }
        var output: [Block] = []
        var seenListItems = Set<Int>()
        for (intent, range) in parsed.runs[\.presentationIntent] {
            let components = intent?.components ?? []
            var text = AttributedString(parsed[range])
            text.presentationIntent = nil
            // Text never fetches Markdown images or runs embedded HTML. Links open
            // only after a tap, and cannot invoke app actions or local-file URLs.
            for (url, linkRange) in Array(text.runs[\.link]) {
                if let url, !["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    text[linkRange].link = nil
                }
            }

            var block = Block(id: output.count, text: text)
            var tableID: Int?
            var rowID: Int?
            var column: Int?
            var header = false
            var columnCount = 0
            var columnAlignments: [PresentationIntent.TableColumn.Alignment] = []
            var listItem: (id: Int, ordinal: Int)?
            var listIsOrdered: Bool?
            var listCount = 0
            for component in components {
                switch component.kind {
                case .header(let level): block.kind = .heading(level)
                case .codeBlock: block.kind = .code
                case .blockQuote: block.quoted = true
                case .listItem(let ordinal):
                    if listItem == nil { listItem = (component.identity, ordinal) }
                case .orderedList:
                    listCount += 1
                    if listIsOrdered == nil { listIsOrdered = true }
                case .unorderedList:
                    listCount += 1
                    if listIsOrdered == nil { listIsOrdered = false }
                case .table(let columns):
                    tableID = component.identity; columnCount = columns.count
                    columnAlignments = columns.map(\.alignment)
                case .tableHeaderRow: rowID = component.identity; header = true
                case .tableRow: rowID = component.identity
                case .tableCell(let index): column = index
                case .thematicBreak: block.kind = .divider
                default: break
                }
            }
            block.listDepth = max(0, listCount - 1)
            block.inList = listItem != nil
            if let listItem, seenListItems.insert(listItem.id).inserted {
                block.marker = listIsOrdered == true ? "\(listItem.ordinal)." : "•"
            }

            if let tableID, let rowID, let column, column >= 0, column < columnCount {
                if output.last?.tableID != tableID {
                    block.kind = .table; block.tableID = tableID; block.columnCount = columnCount
                    block.columnAlignments = columnAlignments
                    output.append(block)
                }
                let index = output.count - 1
                if output[index].rows.last?.id != rowID {
                    output[index].rows.append(Row(id: rowID, header: header,
                        cells: Array(repeating: AttributedString(), count: columnCount)))
                }
                let row = output[index].rows.count - 1
                if !output[index].rows[row].cells[column].characters.isEmpty {
                    output[index].rows[row].cells[column].append(AttributedString("\n"))
                }
                output[index].rows[row].cells[column].append(text)
            } else if block.kind == .divider || !String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                output.append(block)
            }
        }
        blocks = output
    }
}

