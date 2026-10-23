// Port of Filee.Engines/Office/SpreadsheetConverter.cs.
import Foundation

final class SpreadsheetConverter: Converter {
    let id = "spreadsheet"
    let displayName = "Spreadsheets (built-in)"
    let maxParallelism = 0
    let edges = ["xlsx", "xlsm", "xltx", "xls", "ods", "csv", "tsv"].flatMap { from in
        ["xlsx", "ods", "csv", "tsv"].filter { $0 != from && !($0 == "xlsx" && ["xlsm", "xltx"].contains(from)) }.map {
            ConversionEdge(from, $0)
        }
    }
    func status() -> EngineStatus {
        .available(detail: "XLSX, XLS, ODS, CSV, TSV → XLSX, ODS, CSV, TSV", version: EngineVersions.builtIn)
    }
    func convert(_ step: ConversionStep, progress: ProgressHandler?) async throws -> [String] {
        try Task.checkCancellation()
        progress?(0.1)
        let book = try Self.read(step.inputPath, step.from)
        try Task.checkCancellation()
        progress?(0.6)
        var outputs: [String] = []
        switch step.to {
        case "xlsx", "ods":
            if let path = try step.output.allocate(step.to) {
                if step.to == "xlsx" { try XlsxWriter.write(book, path) } else { try OdsWriter.write(book, path) }
                outputs.append(path)
            }
        default:
            var sheets = book.sheets.filter { $0.usedRange() != nil }
            if sheets.isEmpty, let first = book.sheets.first { sheets = [first] }
            for sheet in sheets {
                let clean = String(sheet.name.map { $0 == "/" || $0 == "\0" ? "_" : $0 }).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let suffix = sheets.count > 1 ? "_" + (clean.isEmpty ? "Sheet" : clean) : nil
                guard let file = try step.output.allocate(step.to, suffix: suffix) else { continue }
                try CsvFormat.write(sheet, file, step.to == "tsv" ? CsvFormat.tab : ",")
                outputs.append(file)
            }
        }
        progress?(1)
        return outputs
    }
    static func read(_ path: String, _ format: String) throws -> Workbook {
        switch format {
        case "xls": return try XlsReader.read(path)
        case "ods": return try OdsReader.read(path)
        case "csv": return try CsvFormat.read(path)
        case "tsv": return try CsvFormat.readTsv(path)
        default: return try XlsxReader.read(path)
        }
    }
}
