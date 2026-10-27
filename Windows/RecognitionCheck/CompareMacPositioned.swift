import Foundation

@main struct CompareMacPositioned {
    struct Line: Codable { let text: String; let x: Double; let y: Double }
    struct Fixture: Codable {
        let name: String
        let lines: [Line]
        var amount: String? = nil
        var warning: String? = nil
        var candidates: [String] = []
    }
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let values = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: url)).map { input -> Fixture in
            let lines = input.lines.map { Recognition.PositionedText(text: $0.text, x: $0.x, y: $0.y) }
            let result = Recognition.positionedAmount(in: lines)
            return Fixture(name: input.name, lines: input.lines,
                           amount: result.map { NSDecimalNumber(decimal: $0.amount).stringValue },
                           warning: result?.warning,
                           candidates: Recognition.amountCandidates(in: lines).map { NSDecimalNumber(decimal: $0.amount).stringValue })
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(values).write(to: url)
        print("Generated \(values.count) positioned fixtures from frozen Mac rules")
    }
}
