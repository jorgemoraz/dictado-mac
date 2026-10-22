import Foundation

enum ImportedDictionaryRow {
    case term(String)
    case correction(String, String)
}

enum DictionaryImportParser {
    static func parse(_ text: String, separator: Character? = nil) -> ([ImportedDictionaryRow], Int) {
        // Swift Characters treat CRLF as one grapheme cluster, so normalize line endings before scanning.
        let normalized = text.replacingOccurrences(of:"\r\n",with:"\n").replacingOccurrences(of:"\r",with:"\n")
        let delimiter = separator ?? (normalized.contains("\t") ? "\t" : ",")
        var rows = [[String]](), row = [String](), field = "", quoted = false
        let chars = Array(normalized); var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { quoted = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty { quoted = true }
            else if c == delimiter { row.append(field); field = "" }
            else if c == "\n" || c == "\r" { if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }; row.append(field); rows.append(row); row=[]; field="" }
            else { field.append(c) }
            i += 1
        }
        if quoted { return ([], max(1, rows.count + 1)) }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        var result = [ImportedDictionaryRow](), invalid = 0
        for (index, cells) in rows.enumerated() {
            let cleaned = cells.map { $0.replacingOccurrences(of:"\u{FEFF}",with:"").trimmingCharacters(in:.whitespacesAndNewlines) }
            if cleaned.allSatisfy(\.isEmpty) { continue }
            if index == 0 && cleaned.count >= 2 && ["phrase","word","term","spoken form"].contains(cleaned[0].lowercased()) && ["replacement","correction","correct form"].contains(cleaned[1].lowercased()) { continue }
            if cleaned.count == 1, let word = cleaned.first, !word.isEmpty { result.append(.term(word)) }
            else if cleaned.count == 2, !cleaned[0].isEmpty {
                if cleaned[1].isEmpty { result.append(.term(cleaned[0])) }
                else { result.append(.correction(cleaned[0],cleaned[1])) }
            } else { invalid += 1 }
        }
        return (result,invalid)
    }
}
