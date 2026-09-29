import Foundation

public enum ExpenseCategory: String, CaseIterable, Codable, Sendable {
    case transport = "交通"
    case meals = "餐食"
    case lodging = "住宿"
    case purchases = "道具采购"
    case other = "其他"
    case uncategorized = "待分类"
}

public struct Expense: Identifiable, Codable, Sendable {
    public let id: UUID
    public var number: Int
    public var sourceURL: URL
    public var amount: Decimal?
    public var category: ExpenseCategory
    public var purpose: String
    public var date: String
    public var warning: String?
    public var isDuplicate: Bool

    public init(
        id: UUID = UUID(),
        number: Int,
        sourceURL: URL,
        amount: Decimal? = nil,
        category: ExpenseCategory = .uncategorized,
        purpose: String = "",
        date: String = "",
        warning: String? = nil,
        isDuplicate: Bool = false
    ) {
        self.id = id
        self.number = number
        self.sourceURL = sourceURL
        self.amount = amount
        self.category = category
        self.purpose = purpose
        self.date = date
        self.warning = warning
        self.isDuplicate = isDuplicate
    }
}

public enum ExpenseDate {
    public static func formattedInput(_ value: String, previous: String) -> String {
        var digits = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(8))
        if previous.hasSuffix("-"), value == String(previous.dropLast()) {
            digits = String(digits.dropLast())
        }
        var result = String(digits.prefix(4))
        if digits.count >= 4 { result += "-" }
        if digits.count > 4 { result += digits.dropFirst(4).prefix(2) }
        if digits.count >= 6 { result += "-" }
        if digits.count > 6 { result += digits.dropFirst(6) }
        return result
    }

    public static func normalized(year: Int, month: Int, day: Int) -> String? {
        guard (1900...2099).contains(year) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard parts.year == year, parts.month == month, parts.day == day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func isValid(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
        return normalized(year: year, month: month, day: day) == value
    }
}
