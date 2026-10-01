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
        let quizlet = "mitochondria\tpowerhouse of the cell, makes ATP\nribosome\tmakes proteins, reads mRNA\nnucleus\tDNA\n"
        XCTAssertEqual(DelimitedParser.detectDelimiter(quizlet, candidates: ["\t", ",", ";"]), "\t")
    }

    func testScanFlagsQuotesThatAWrongDelimiterStrands() {
        let text = "a,\"x;\ny\"\n"
        XCTAssertEqual(DelimitedParser.scan(Array(text.unicodeScalars), delimiter: ",", limit: .max),
                       [DelimitedParser.Row(fields: ["a", "x;\ny"], strayQuote: false)])
        XCTAssertEqual(DelimitedParser.scan(Array(text.unicodeScalars), delimiter: ";", limit: .max),
                       [DelimitedParser.Row(fields: ["a,\"x", ""], strayQuote: true),
                        DelimitedParser.Row(fields: ["y\""], strayQuote: true)])
        XCTAssertEqual(DelimitedParser.scan(Array("1,2\n\n3,4\n5,6".unicodeScalars), delimiter: ",", limit: 2).map(\.fields),
                       [["1", "2"], ["3", "4"]])
    }

    /// Quoted multi-line cells full of the other delimiter (code, chemistry, Excel cells) must not outvote the real one.
    func testDelimiterDetectionKeepsQuotedMultilineCellsWhole() {
        let code = [StudyRow(front: "Sum 0..n in C", back: "int s = 0;\nfor (int i = 0; i < n; i++)\n    s += i;\nreturn s;"),
                    StudyRow(front: "Swap a and b", back: "t = a;\na = b;\nb = t;")]
        let csv = StudyExport.encode(code.map { [$0.front, $0.back] })
        XCTAssertEqual(StudyImport.rows(from: csv, format: .csv), code)
        XCTAssertEqual(StudyImport.rows(from: csv, format: .txt), code)

        // Files from other apps that leave ";" unquoted.
        let unquoted = "a;b,\"x;\ny;\nz;\"\r\nc;d,\"p;\nq;\"\r\n"
        XCTAssertEqual(StudyImport.rows(from: unquoted, format: .csv),
                       [StudyRow(front: "a;b", back: "x;\ny;\nz;"), StudyRow(front: "c;d", back: "p;\nq;")])

        // The reverse: a semicolon CSV (Excel in comma-decimal locales) whose multi-line cells hold commas.
        let semicolon = "Frage;Antwort\r\n\"Nenne drei Farben\";\"rot, grün,\nblau\"\r\nPi;3,14159\r\n"
        let expected = [StudyRow(front: "Frage", back: "Antwort"), StudyRow(front: "Nenne drei Farben", back: "rot, grün,\nblau"),
                        StudyRow(front: "Pi", back: "3,14159")]
        XCTAssertEqual(StudyImport.rows(from: semicolon, format: .csv), expected)
        XCTAssertEqual(StudyImport.rows(from: semicolon, format: .txt), expected)
    }

    // MARK: Export quoting

    func testExportQuotesHashStartsAndEveryImportDelimiter() {
        XCTAssertEqual(StudyExport.field("plain text"), "plain text")
        XCTAssertEqual(StudyExport.field("#tags: list them"), "\"#tags: list them\"")
        XCTAssertEqual(StudyExport.field("a;b"), "\"a;b\"")
        XCTAssertEqual(StudyExport.field("a\tb"), "\"a\tb\"")
        XCTAssertEqual(StudyExport.field("say \"hi\""), "\"say \"\"hi\"\"\"")

        // A first card that looks like an Anki header line stays a card (and cannot switch the delimiter).
        let rows = [StudyRow(front: "#tags: list them", back: "a, b"), StudyRow(front: "#separator:semicolon", back: "x;y"),
                    StudyRow(front: "#1", back: "first")]
        let csv = StudyExport.encode(rows.map { [$0.front, $0.back] })
        XCTAssertEqual(StudyImport.rows(from: csv, format: .csv), rows)
        XCTAssertEqual(StudyImport.rows(from: csv, format: .txt), rows)
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

    /// Without an `#html:` header, a file with no Anki markup is not HTML: cards about markup keep their text.
    func testPlainFilesKeepMarkupAndEntitiesVerbatim() {
        XCTAssertEqual(StudyImport.rows(from: "What does <b> do?\tbold\n&lt; means\tless than\n", format: .txt),
                       [StudyRow(front: "What does <b> do?", back: "bold"), StudyRow(front: "&lt; means", back: "less than")])
        let nibExport = StudyExport.encode([["What does <b> do?", "Makes text <b>bold</b> & strong"]])
        XCTAssertEqual(StudyImport.rows(from: nibExport, format: .csv),
                       [StudyRow(front: "What does <b> do?", back: "Makes text <b>bold</b> & strong")])
        // One Anki marker anywhere in the body turns stripping on for the whole file.
        XCTAssertEqual(StudyImport.rows(from: "What is <b>ATP</b>?\tenergy\nLine<BR>break\tx\n", format: .txt),
                       [StudyRow(front: "What is ATP?", back: "energy"), StudyRow(front: "Line\nbreak", back: "x")])
        XCTAssertTrue(HTMLText.hasAnkiMarkup("a&nbsp;b"))
        XCTAssertTrue(HTMLText.hasAnkiMarkup(Substring("x [sound:a.mp3]")))
        XCTAssertFalse(HTMLText.hasAnkiMarkup("x < 5 & <b>"))
    }

    func testHTMLStrippingKeepsPlainComparisonsAndDecodesEntities() {
        XCTAssertEqual(HTMLText.strip("x < 5 and y > 3", anyTag: false), "x < 5 and y > 3")
        XCTAssertEqual(HTMLText.strip("a &amp; b &#233; &#x41; &eacute;", anyTag: false), "a & b é A &eacute;")
        XCTAssertEqual(HTMLText.strip("<span style=\"color: red\">red</span><img src=\"a.png\"/>", anyTag: false), "red")
        XCTAssertEqual(HTMLText.strip("<P>one<BR/>two</p>[sound:a.mp3]<x-y>z</x-y>", anyTag: true), "\none\ntwoz")
        XCTAssertEqual(HTMLText.strip("<x-y>z</x-y>", anyTag: false), "<x-y>z</x-y>")
    }

    func testTextDecodingFallsBackForUTF16AndWindows1252() {
        XCTAssertEqual(StudyImport.decode(Data("café\tcoffee".utf8)), "café\tcoffee")
        var utf16 = Data([0xFF, 0xFE])
        utf16.append("né\tborn".data(using: .utf16LittleEndian) ?? Data())
        XCTAssertEqual(StudyImport.decode(utf16), "né\tborn")
        XCTAssertEqual(StudyImport.decode(Data([0x63, 0x61, 0x66, 0xE9])), "café")
    }
}
