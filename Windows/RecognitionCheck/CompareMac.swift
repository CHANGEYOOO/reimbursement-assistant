import Foundation

@main struct CompareMac {
    struct Fixture: Codable {
        let text: String
        var amount: String? = nil
        var category: String? = nil
        var date: String? = nil
        var warning: String? = nil
    }
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let values = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url)).map { input -> Fixture in
            let result = Recognition.suggest(from: input.text)
            return Fixture(text: input.text, amount: result.amount.map { NSDecimalNumber(decimal: $0).stringValue },
                           category: result.category.rawValue, date: result.date, warning: result.warning)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(values).write(to: url)
        print("Generated \(values.count) fixtures from frozen Mac rules")
    }
}
