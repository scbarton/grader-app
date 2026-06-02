import SwiftData
import Foundation
import UniformTypeIdentifiers

// MARK: - Course bundle UTType

extension UTType {
    static let gradercourse = UTType(exportedAs: "org.powrbox.gradercourse")
}

// MARK: - SwiftData models

@Model final class Assignment {
    var id: UUID = UUID()
    var name: String = ""
    var createdAt: Date = Date()
    var d2lColumnHeader: String = ""

    @Relationship(deleteRule: .cascade) var rubricItems: [RubricItem] = []
    @Relationship(deleteRule: .cascade) var students: [Student] = []

    var maxPoints: Double { rubricItems.reduce(0) { $0 + $1.maxPoints } }

    init(name: String) { self.name = name }
}

@Model final class RubricItem {
    var id: UUID = UUID()
    var name: String = ""
    var maxPoints: Double = 10
    var order: Int = 0

    init(name: String, maxPoints: Double, order: Int) {
        self.name = name; self.maxPoints = maxPoints; self.order = order
    }
}

@Model final class Student {
    var id: UUID = UUID()
    var name: String = ""
    var email: String = ""
    var fileName: String = ""
    /// Path relative to the course bundle root, e.g. "PDFs/HW1/smith_john.pdf"
    var pdfRelativePath: String = ""
    var orgDefinedId: String = ""
    var username: String = ""

    @Relationship(deleteRule: .cascade) var scores: [Score] = []

    var totalScore: Double { scores.compactMap(\.points).reduce(0, +) }

    init(name: String, email: String = "", fileName: String) {
        self.name = name; self.email = email; self.fileName = fileName
    }
}

@Model final class Score {
    var id: UUID = UUID()
    var rubricItemID: UUID = UUID()
    var points: Double?
    var comment: String = ""

    init(rubricItemID: UUID) { self.rubricItemID = rubricItemID }
}

@Model final class RosterEntry {
    var id: UUID = UUID()
    var lastName: String = ""
    var firstName: String = ""
    var email: String = ""
    var orgDefinedId: String = ""
    var username: String = ""

    var fullName: String { "\(firstName) \(lastName)" }
    var sortKey: String { "\(lastName), \(firstName)" }

    init(firstName: String, lastName: String, email: String) {
        self.firstName = firstName; self.lastName = lastName; self.email = email
    }
}
