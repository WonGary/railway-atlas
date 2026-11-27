// swift Scripts/build-station-transliterations.swift (from the repository root)
import Foundation

struct Directory: Decodable { var names: [String] }
let source = try String(contentsOfFile:"Web/station-directory/national.js", encoding:.utf8)
guard let start = source.firstIndex(of:"{"), let end = source.lastIndex(of:"}") else { fatalError("Missing directory") }
let directory = try JSONDecoder().decode(Directory.self, from:Data(source[start...end].utf8))
let locale = Locale(identifier:"en_US_POSIX")
let names = directory.names.map { station -> String in
    let latin = (station.applyingTransform(.mandarinToLatin,reverse:false) ?? station)
        .folding(options:.diacriticInsensitive,locale:locale).replacingOccurrences(of:" ",with:"").lowercased()
    return latin.prefix(1).uppercased() + latin.dropFirst()
}
let table = Dictionary(zip(directory.names,names),uniquingKeysWith:{first,_ in first})
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys,.withoutEscapingSlashes]
var output = Data("globalThis.atlasStationTransliterations=".utf8)
output.append(try encoder.encode(table))
output.append(Data(";\n".utf8))
try output.write(to:URL(fileURLWithPath:"Web/data/station-transliterations.js"),options:.atomic)
