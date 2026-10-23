import Foundation
import XCTest
@testable import ScribePilot

final class MarkdownRenderingTests: XCTestCase {
    func testHeadingsParagraphsAndInlineFormattingKeepAllWords() throws {
        let document = ScribeMarkdownDocument("# Meeting overview\n\nThe **project timeline** is *confirmed*.\n\nNext paragraph: café, 日本語, 📝.")
        XCTAssertEqual(document.blocks.count, 3)
        XCTAssertEqual(document.blocks[0].kind, .heading(1))
        XCTAssertEqual(String(document.blocks[0].text.characters), "Meeting overview")
        let body = document.blocks[1].text
        XCTAssertEqual(String(body.characters), "The project timeline is confirmed.")
        XCTAssertTrue(body.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(body.runs.contains { $0.inlinePresentationIntent?.contains(.emphasized) == true })
        XCTAssertEqual(String(document.blocks[2].text.characters), "Next paragraph: café, 日本語, 📝.")
    }

    func testNestedAndOrderedListsPreserveMarkersAndContinuationParagraphs() {
        let document = ScribeMarkdownDocument("- Parent\n  - Child\n\n    Child continuation.\n\n7. First numbered\n8. Second numbered")
        XCTAssertEqual(document.blocks.map { String($0.text.characters) },
                       ["Parent", "Child", "Child continuation.", "First numbered", "Second numbered"])
        XCTAssertEqual(document.blocks.map(\.marker), ["•", "•", nil, "7.", "8."])
        XCTAssertEqual(document.blocks.map(\.listDepth), [0, 1, 1, 0, 0])
        XCTAssertTrue(document.blocks.allSatisfy(\.inList))
    }

    func testTablesKeepHeadersCellsEmptyValuesAndAdjacentParagraphs() throws {
        let document = ScribeMarkdownDocument("Before.\n\n| Owner | Due |\n| :--- | ---: |\n| **Alex** | Friday |\n| Jamie | |\n\nAfter.")
        XCTAssertEqual(document.blocks.count, 3)
        XCTAssertEqual(String(document.blocks[0].text.characters), "Before.")
        let table = document.blocks[1]
        XCTAssertEqual(table.kind, .table)
        XCTAssertEqual(table.columnCount, 2)
        XCTAssertEqual(table.columnAlignments, [.left, .right])
        XCTAssertEqual(table.rows.count, 3)
        XCTAssertTrue(table.rows[0].header)
        XCTAssertFalse(table.rows[1].header)
        XCTAssertEqual(table.rows.map { $0.cells.map { String($0.characters) } },
                       [["Owner", "Due"], ["Alex", "Friday"], ["Jamie", ""]])
        XCTAssertTrue(table.rows[1].cells[0].runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertEqual(String(document.blocks[2].text.characters), "After.")
    }

    func testQuotedAndFencedCodeContentStaysLiteral() throws {
        let document = ScribeMarkdownDocument("> Review **before** sharing.\n\n```text\n**literal** [not a link](file:///private)\nsecond line\n```")
        XCTAssertEqual(document.blocks.count, 2)
        XCTAssertTrue(document.blocks[0].quoted)
        XCTAssertEqual(String(document.blocks[0].text.characters), "Review before sharing.")
        XCTAssertEqual(document.blocks[1].kind, .code)
        XCTAssertTrue(String(document.blocks[1].text.characters).contains("**literal** [not a link](file:///private)\nsecond line"))
        XCTAssertTrue(document.blocks[1].text.runs.allSatisfy { $0.link == nil })
    }

    func testLinksKeepLabelsAndOnlyUserOpenedWebOrMailDestinations() throws {
        let document = ScribeMarkdownDocument("[Reference](https://example.com/protocol) and [Mail](mailto:team@example.com). [Local](file:///private) [Action](scribe-pilot://record) ![Diagram](https://example.com/image.png)")
        let text = try XCTUnwrap(document.blocks.first?.text)
        XCTAssertTrue(String(text.characters).contains("Reference"))
        let links = text.runs.compactMap(\.link)
        XCTAssertTrue(links.contains(URL(string: "https://example.com/protocol")!))
        XCTAssertTrue(links.contains(URL(string: "mailto:team@example.com")!))
        XCTAssertTrue(links.allSatisfy { ["http", "https", "mailto"].contains($0.scheme ?? "") })
    }
}
