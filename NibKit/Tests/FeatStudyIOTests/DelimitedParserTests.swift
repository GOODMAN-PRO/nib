import XCTest
@testable import FeatStudyIO

final class DelimitedParserTests: XCTestCase {
    // MARK: DelimitedParser

    func testQuotedFieldsHoldDelimitersAndEscapedQuotes() {
        XCTAssertEqual(DelimitedParser.parse("\"a,b\",c\n\"say \"\"hi\"\"\",x", delimiter: ","),
                       [["a,b", "c"], ["say \"hi\"", "x"]])
    }

    func testQuotedFieldsHoldEmbeddedNewlinesAndTabs() {
        XCTAssertEqual(DelimitedParser.parse("\"line1\nline2\",\"tab\there\"\r\nq,a", delimiter: ","),
                       [["line1\nline2", "tab\there"], ["q", "a"]])
        XCTAssertEqual(DelimitedParser.parse("\"a\tb\"\tc\n", delimiter: "\t"), [["a\tb", "c"]])
    }

    func testByteOrderMarkIsStripped() {
        XCTAssertEqual(DelimitedParser.parse("\u{FEFF}q,a", delimiter: ","), [["q", "a"]])
        XCTAssertEqual(StudyImport.rows(from: "\u{FEFF}q\ta", format: .tsv), [StudyRow(front: "q", back: "a")])
    }

    func testEmptyLinesAndEveryLineEndingAreHandled() {
        XCTAssertEqual(DelimitedParser.parse("q1,a1\r\n\r\n\nq2,a2\rq3,a3", delimiter: ","),
                       [["q1", "a1"], ["q2", "a2"], ["q3", "a3"]])
        XCTAssertEqual(DelimitedParser.parse("", delimiter: ","), [])
        XCTAssertEqual(DelimitedParser.parse("a,", delimiter: ","), [["a", ""]])
    }

    func testStrayQuotesAreLiteralText() {
        XCTAssertEqual(DelimitedParser.parse("\"Hello\" in French\tBonjour\n\"unterminated\tfin", delimiter: "\t"),
                       [["\"Hello\" in French", "Bonjour"], ["\"unterminated", "fin"]])
        XCTAssertEqual(DelimitedParser.parse("  \"padded\" , next", delimiter: ","), [["padded", " next"]])
    }

    func testDelimiterDetection() {
        XCTAssertEqual(DelimitedParser.detectDelimiter("dog\tchien\ncat, the animal\tchat", candidates: ["\t", ",", ";"]), "\t")
        XCTAssertEqual(DelimitedParser.detectDelimiter("1 < 2;wahr\n3 > 4;falsch", candidates: [",", ";"]), ";")
        XCTAssertEqual(DelimitedParser.detectDelimiter("single column", candidates: ["\t", ",", ";"]), "\t")
    }

    // MARK: Rows, Anki headers and HTML

    func testRowsTakeColumnsAAndBAndSkipBlankRows() {
        XCTAssertEqual(StudyImport.rows(from: "Q1\tA1\textra\tmore\n \t \nQ2\n", format: .txt),
                       [StudyRow(front: "Q1", back: "A1"), StudyRow(front: "Q2", back: "")])
        XCTAssertEqual(StudyImport.rows(from: "1 < 2;wahr\n3 > 4;falsch\n", format: .csv),
                       [StudyRow(front: "1 < 2", back: "wahr"), StudyRow(front: "3 > 4", back: "falsch")])
        XCTAssertEqual(StudyImport.rows(from: "dog,chien\ncat,chat", format: .txt),
                       [StudyRow(front: "dog", back: "chien"), StudyRow(front: "cat", back: "chat")])
    }

    func testAnkiNotesInPlainTextHeaderColumnsAndHTML() {
        let export = "#separator:tab\n#html:true\n#guid column:1\n#notetype column:2\n#tags column:5\n"
            + "qF9$x\tBasic\tWhat is <b>ATP</b>?\tAdenosine&nbsp;triphosphate<br>energy currency\tbio::cells\n"
        XCTAssertEqual(StudyImport.rows(from: export, format: .txt),
                       [StudyRow(front: "What is ATP?", back: "Adenosine triphosphate\nenergy currency")])

        let noHeader = "Front<div>more</div>\tBack [sound:x.mp3]\n#1: not a header\tanswer\n"
        XCTAssertEqual(StudyImport.rows(from: noHeader, format: .txt),
                       [StudyRow(front: "Front\nmore", back: "Back"), StudyRow(front: "#1: not a header", back: "answer")])

        let (header, body) = AnkiHeader.split("#separator:Pipe\n#html:false\na|<b>b</b>")
        XCTAssertEqual(header.separator, "|")
        XCTAssertEqual(header.html, false)
        XCTAssertEqual(String(body), "a|<b>b</b>")
        XCTAssertEqual(StudyImport.rows(from: "#separator:Pipe\n#html:false\na|<b>b</b>", format: .txt),
                       [StudyRow(front: "a", back: "<b>b</b>")])
    }

    func testHTMLStrippingKeepsPlainComparisonsAndDecodesEntities() {
        XCTAssertEqual(HTMLText.strip("x < 5 and y > 3", anyTag: false), "x < 5 and y > 3")
        XCTAssertEqual(HTMLText.strip("a &amp; b &#233; &#x41; &eacute;", anyTag: false), "a & b é A &eacute;")
        XCTAssertEqual(HTMLText.strip("<span style=\"color: red\">red</span><img src=\"a.png\"/>", anyTag: false), "red")
    }

    func testTextDecodingFallsBackForUTF16AndWindows1252() {
        XCTAssertEqual(StudyImport.decode(Data("café\tcoffee".utf8)), "café\tcoffee")
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("né\tborn".data(using: .utf16LittleEndian) ?? Data())
        XCTAssertEqual(StudyImport.decode(utf16), "né\tborn")
        XCTAssertEqual(StudyImport.decode(Data([0x63, 0x61, 0x66, 0xE9])), "café")
    }
}
