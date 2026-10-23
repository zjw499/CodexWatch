import SwiftUI

struct ScribeMarkdownView: View {
    let source: String
    init(_ source: String) { self.source = source }

    var body: some View {
        let document = ScribeMarkdownDocument(source)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(document.blocks) { block in
                HStack(alignment: .top, spacing: 8) {
                    if block.quoted { Rectangle().fill(ScribeTheme.muted).frame(width: 3) }
                    if let marker = block.marker {
                        Text(verbatim: marker).monospacedDigit().accessibilityHidden(marker == "•")
                            .frame(minWidth: 18, alignment: .trailing)
                    } else if block.inList { Color.clear.frame(width: 18) }
                    blockContent(block)
                }
                .padding(.leading, CGFloat(min(block.listDepth, 6)) * 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tint(ScribeTheme.red)
    }

    @ViewBuilder private func blockContent(_ block: ScribeMarkdownDocument.Block) -> some View {
        switch block.kind {
        case .heading(let level):
            Text(block.text).font(headingFont(level)).accessibilityAddTraits(.isHeader)
                .fixedSize(horizontal: false, vertical: true)
        case .code:
            ScrollView(.horizontal) {
                Text(block.text).font(.system(.caption, design: .monospaced)).fixedSize()
                    .padding(10)
            }.background(ScribeTheme.background, in: RoundedRectangle(cornerRadius: 8))
        case .table:
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(block.rows) { row in
                        GridRow {
                            ForEach(0..<block.columnCount, id: \.self) { column in
                                Text(row.cells[column]).bold(row.header)
                                    .frame(minWidth: 96, idealWidth: 150, maxWidth: 200,
                                           alignment: cellAlignment(block.columnAlignments[column]))
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(8)
                                    .background(row.header ? ScribeTheme.raised : ScribeTheme.background.opacity(0.45))
                                    .overlay { Rectangle().stroke(ScribeTheme.border, lineWidth: 0.5) }
                            }
                        }
                    }
                }
            }.accessibilityIdentifier("scribe-markdown-table")
        case .divider: Divider().overlay(ScribeTheme.border)
        case .paragraph:
            Text(block.text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func cellAlignment(_ alignment: PresentationIntent.TableColumn.Alignment) -> Alignment {
        switch alignment {
        case .left: return .leading
        case .center: return .center
        case .right: return .trailing
        @unknown default: return .leading
        }
    }

    private func headingFont(_ level: Int) -> Font {
        #if os(watchOS)
        return level <= 2 ? .headline : .subheadline.bold()
        #else
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        default: return .headline
        }
        #endif
    }
}
