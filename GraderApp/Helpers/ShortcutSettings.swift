import Foundation
import Observation

/// A rebindable annotation-tool action. Each maps to a single, unmodified letter key
/// pressed while the PDF view has focus. Grade-entry digits and Cmd+arrow navigation
/// are intentionally not part of this set (they stay fixed).
enum ShortcutAction: String, CaseIterable, Identifiable {
    case pointer, comment, highlight, delete, grade, rotate, correct, incorrect, partial

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pointer:   "Pointer / Move"
        case .comment:   "Comment"
        case .highlight: "Highlight"
        case .delete:    "Delete"
        case .grade:     "Grade Stamp"
        case .rotate:    "Rotate Page"
        case .correct:   "Correct"
        case .incorrect: "Incorrect"
        case .partial:   "Partial / OK"
        }
    }

    /// Emoji shown alongside the stamp actions in the settings pane.
    var symbol: String? {
        switch self {
        case .correct:   "✅"
        case .incorrect: "❌"
        case .partial:   "🆗"
        default:         nil
        }
    }

    var defaultKey: String {
        switch self {
        case .pointer:   "m"
        case .comment:   "c"
        case .highlight: "h"
        case .delete:    "d"
        case .grade:     "g"
        case .rotate:    "r"
        case .correct:   "v"
        case .incorrect: "x"
        case .partial:   "k"
        }
    }
}

/// Persisted, observable store for the annotation-tool key bindings.
///
/// Bindings live in `UserDefaults` under a single dictionary key. An in-memory cache
/// (`keys`) is kept so the AppKit `keyDown` path can resolve a key → action synchronously
/// on every keystroke without hitting `UserDefaults`, and a reverse map (`reverse`) makes
/// that lookup O(1).
@Observable
final class ShortcutSettings {
    static let shared = ShortcutSettings()

    private static let defaultsKey = "keyboardShortcuts"

    /// action.rawValue → single lowercase letter.
    private(set) var keys: [String: String] = [:]
    /// letter → action, rebuilt whenever `keys` changes.
    private var reverse: [String: ShortcutAction] = [:]

    private init() {
        let stored = UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String]
        for action in ShortcutAction.allCases {
            let normalized = stored?[action.rawValue].flatMap(Self.normalize)
            keys[action.rawValue] = normalized ?? action.defaultKey
        }
        rebuildReverse()
    }

    // MARK: - Reads

    func key(for action: ShortcutAction) -> String {
        keys[action.rawValue] ?? action.defaultKey
    }

    /// Reverse lookup used by `keyDown`. Accepts the raw character; returns the bound action.
    func action(forKey character: String) -> ShortcutAction? {
        guard let key = Self.normalize(character) else { return nil }
        return reverse[key]
    }

    /// The action (other than `excluding`) currently bound to `key`, if any.
    func conflict(for key: String, excluding action: ShortcutAction) -> ShortcutAction? {
        guard let normalized = Self.normalize(key), let owner = reverse[normalized] else { return nil }
        return owner == action ? nil : owner
    }

    // MARK: - Writes

    /// Assigns `key` to `action`. Returns false (no change) if the key is invalid or already
    /// bound to a different action — the caller surfaces the conflict.
    @discardableResult
    func setKey(_ key: String, for action: ShortcutAction) -> Bool {
        guard let normalized = Self.normalize(key) else { return false }
        if let owner = reverse[normalized], owner != action { return false }
        keys[action.rawValue] = normalized
        persist()
        rebuildReverse()
        return true
    }

    func resetToDefaults() {
        for action in ShortcutAction.allCases { keys[action.rawValue] = action.defaultKey }
        persist()
        rebuildReverse()
    }

    // MARK: - Helpers

    /// A valid binding is exactly one letter a–z. Digits and "." are rejected so they can't
    /// shadow direct grade entry. Returns the lowercased letter, or nil if invalid.
    static func normalize(_ raw: String) -> String? {
        let lower = raw.lowercased()
        guard lower.count == 1, let scalar = lower.unicodeScalars.first,
              ("a"..."z").contains(Character(scalar)) else { return nil }
        return lower
    }

    private func rebuildReverse() {
        var map: [String: ShortcutAction] = [:]
        for action in ShortcutAction.allCases {
            map[key(for: action)] = action
        }
        reverse = map
    }

    private func persist() {
        UserDefaults.standard.set(keys, forKey: Self.defaultsKey)
    }
}
