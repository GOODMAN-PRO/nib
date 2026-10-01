import Foundation
import CryptoKit
import NibContracts

/// Stable student identity keeps two students with the same display name distinct.
struct LessonStudent: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var email: String?
}

/// RFC 4180 CSV, including quoted commas, escaped quotes, CRLF and multiline names.
/// A header is required: name (or first_name + last_name), with optional id and email.
enum RosterImport {
    static let maxBytes = 2_000_000
    static let maxStudents = 1_000

    static func parse(_ csv: String) throws -> [LessonStudent] {
        guard csv.utf8.count <= maxBytes else { throw invalid("The roster is too large.") }
        var text = csv
        if text.first == "\u{FEFF}" { text.removeFirst() }
        let headerLine = String(text.prefix { $0 != "\n" && $0 != "\r" && $0 != "\r\n" })
        let delimiter = [Character(","), ";", "\t"].max { lhs, rhs in
            headerLine.filter { $0 == lhs }.count < headerLine.filter { $0 == rhs }.count
        } ?? ","
        let rows = try records(text, delimiter: delimiter)
        guard let header = rows.first else { throw invalid("The roster is empty.") }
        let keys = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "_") }
        guard Set(keys).count == keys.count else { throw invalid("The roster has duplicate column headings.") }
        func column(_ names: [String]) -> Int? { keys.firstIndex { names.contains($0) } }
        let name = column(["name", "student", "student_name", "full_name"])
        let first = column(["first_name", "given_name"]), last = column(["last_name", "family_name", "surname"])
        guard name != nil || (first != nil && last != nil) else {
            throw invalid("Add a name column, or first_name and last_name columns.")
        }
        let id = column(["id", "student_id"]), email = column(["email", "email_address"])
        var students: [LessonStudent] = [], ids = Set<String>(), emails = Set<String>()
        for (offset, row) in rows.dropFirst().enumerated() {
            guard row.count == header.count else { throw invalid("Row \(offset + 2) has a different number of columns.") }
            func value(_ index: Int?) -> String { index.map { row[$0].trimmingCharacters(in: .whitespacesAndNewlines) } ?? "" }
            let fullName = name.map { value($0) } ?? [value(first), value(last)].filter { !$0.isEmpty }.joined(separator: " ")
            let address = value(email).lowercased(), explicit = value(id)
            guard !fullName.isEmpty, fullName.count <= 200 else { throw invalid("Row \(offset + 2) needs a name of at most 200 characters.") }
            if !address.isEmpty {
                guard address.count <= 254, address.split(separator: "@").count == 2, !address.contains(where: \.isWhitespace) else {
                    throw invalid("Check the email address on row \(offset + 2).")
                }
                guard emails.insert(address).inserted else { throw invalid("The email address on row \(offset + 2) appears twice.") }
            }
            let identity = explicit.isEmpty ? stableID(address.isEmpty ? fullName : address) : explicit
            guard NibID.isValid(identity) else { throw invalid("Row \(offset + 2) has an invalid student id; use letters, numbers, underscores or hyphens.") }
            guard ids.insert(identity).inserted else {
                throw invalid("Row \(offset + 2) repeats a student. Give students with the same name different ids.")
            }
            students.append(LessonStudent(id: identity, name: fullName, email: address.isEmpty ? nil : address))
            guard students.count <= maxStudents else { throw invalid("Import at most \(maxStudents) students at a time.") }
        }
        guard !students.isEmpty else { throw invalid("Add at least one student below the headings.") }
        return students
    }

    static func csv(_ students: [LessonStudent]) -> String {
        func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        return "id,name,email\n" + students.map { [quote($0.id), quote($0.name), quote($0.email ?? "")].joined(separator: ",") }.joined(separator: "\n")
    }

    static func stableID(_ value: String) -> String {
        "student_" + SHA256.hash(data: Data(value.precomposedStringWithCanonicalMapping.lowercased().utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func invalid(_ message: String) -> NibError {
        NibError(.invalidParams, message, path: "$.csv", hint: "use CSV headed id,name,email; quote names containing commas")
    }

    static func text(_ bytes: Data) throws -> String {
        guard bytes.count <= maxBytes else { throw invalid("Choose a CSV file no larger than 2 MB.") }
        let encoding: String.Encoding
        if bytes.starts(with: [0xFF, 0xFE]) { encoding = .utf16LittleEndian }
        else if bytes.starts(with: [0xFE, 0xFF]) { encoding = .utf16BigEndian }
        else if let value = String(data: bytes, encoding: .utf8) { return value }
        else { encoding = .windowsCP1252 }
        guard let value = String(data: bytes, encoding: encoding) else { throw invalid("The roster encoding could not be read.") }
        return value
    }

    private static func records(_ text: String, delimiter: Character) throws -> [[String]] {
        enum State { case field, quoted, closed }
        var state = State.field, field = "", row: [String] = [], rows: [[String]] = []
        let chars = Array(text)
        var index = 0
        func endField() { row.append(field); field = ""; state = .field }
        func endRow() {
            endField()
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { rows.append(row) }
            row = []
        }
        while index < chars.count {
            let c = chars[index]
            switch state {
            case .quoted:
                if c == "\"" {
                    if index + 1 < chars.count, chars[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { state = .closed }
                } else { field.append(c) }
            case .closed:
                if c == delimiter { endField() }
                else if c == "\n" || c == "\r" || c == "\r\n" { endRow() }
                else if c == " " || c == "\t" { }
                else { throw invalid("There is text after a closing quote.") }
            case .field:
                if c == "\"" {
                    guard field.trimmingCharacters(in: .whitespaces).isEmpty else { throw invalid("A quote must start a field; double quotes inside quoted names.") }
                    field = ""
                    state = .quoted
                } else if c == delimiter { endField() }
                else if c == "\n" || c == "\r" || c == "\r\n" { endRow() }
                else { field.append(c) }
            }
            if c == "\r", index + 1 < chars.count, chars[index + 1] == "\n", state != .quoted { index += 1 }
            index += 1
        }
        guard state != .quoted else { throw invalid("A quoted field has no closing quote.") }
        if !field.isEmpty || !row.isEmpty || state == .closed { endRow() }
        return rows
    }
}
