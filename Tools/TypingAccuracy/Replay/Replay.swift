import Foundation
import CoreGraphics

/// Re-resolves recorded coordinates using the production spatial resolver.
/// This is not a UIKit delivery replay and does not infer intended characters.
@main
struct AccuracySpatialReplay {
    struct Resolution: Codable {
        let contact: Int
        let downKey: String?
        let upKey: String?
        let downTime: Double
        let upTime: Double
        let overlapsEarlierContact: Bool
    }
    struct Trial: Codable {
        let id: Int
        let resolutions: [Resolution]
        let malformedContacts: [Int]
        let committedKeys: [String]
        let recordedLiftOffKeysMatchCommits: Bool?
    }
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("Usage: scripts/replay-accuracy-session.sh session.json\n".utf8))
            exit(2)
        }
        let session = try JSONDecoder().decode(AccuracySession.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        guard session.schemaVersion == 1 else { throw ReplayError.unsupportedSchema }
        let report = try session.trials.map { trial -> Trial in
            let groupedFrames = Dictionary(grouping: trial.frames, by: \.row)
            let rows = try groupedFrames.keys.sorted().map { row in
                try groupedFrames[row]!.map { frame in
                    KeyboardTouchKeyRegion(key: try key(frame.key), visualFrame: CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
                }
            }
            let bounds = CGRect(x: 0, y: 0, width: trial.surfaceWidth, height: trial.surfaceHeight)
            let grouped = Dictionary(grouping: trial.samples, by: \.contact)
            var malformed: [Int] = []
            var contacts: [(Int, AccuracyTouchSample, AccuracyTouchSample)] = []
            for (id, samples) in grouped {
                let downs = samples.filter { $0.phase == "down" }
                let ups = samples.filter { $0.phase == "up" }
                guard downs.count == 1, ups.count == 1,
                      downs[0].time <= ups[0].time,
                      !samples.contains(where: { $0.phase == "cancel" }) else {
                    malformed.append(id); continue
                }
                contacts.append((id, downs[0], ups[0]))
            }
            contacts.sort { $0.1.time != $1.1.time ? $0.1.time < $1.1.time : $0.0 < $1.0 }
            func resolve(_ sample: AccuracyTouchSample) -> String? {
                KeyboardTouchResolver.resolve(point: CGPoint(x: sample.x, y: sample.y), rows: rows, bounds: bounds).map { token($0.key) }
            }
            let resolutions = contacts.enumerated().map { index, contact in
                Resolution(contact: contact.0, downKey: resolve(contact.1), upKey: resolve(contact.2),
                           downTime: contact.1.time, upTime: contact.2.time,
                           overlapsEarlierContact: contacts[..<index].contains { $0.2.time > contact.1.time })
            }
            let comparable = malformed.isEmpty && !resolutions.contains(where: \.overlapsEarlierContact)
                && resolutions.count == trial.commits.count
            return Trial(id: trial.id, resolutions: resolutions, malformedContacts: malformed.sorted(),
                         committedKeys: trial.commits.map(\.key),
                         recordedLiftOffKeysMatchCommits: comparable ? resolutions.map(\.upKey) == trial.commits.map { Optional($0.key) } : nil)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    private static func key(_ token: String) throws -> KeyboardKey {
        if token.hasPrefix("character:") { return .character(String(token.dropFirst(10))) }
        if token.hasPrefix("mode:") { return .modeSwitch(String(token.dropFirst(5))) }
        switch token {
        case "space": return .space
        case "backspace": return .backspace
        case "shift": return .shift
        case "return": return .returnKey
        case "emoji": return .emoji
        case "globe": return .globe
        case "tab": return .tab
        case "capsLock": return .capsLock
        case "hideKeyboard": return .hideKeyboard
        default: throw ReplayError.unsupportedKey(token)
        }
    }
    private static func token(_ key: KeyboardKey) -> String {
        switch key {
        case .character(let value): return "character:" + value
        case .modeSwitch(let value): return "mode:" + value
        case .space: return "space"
        case .backspace: return "backspace"
        case .shift: return "shift"
        case .returnKey: return "return"
        case .emoji: return "emoji"
        case .globe: return "globe"
        case .tab: return "tab"
        case .capsLock: return "capsLock"
        case .hideKeyboard: return "hideKeyboard"
        case .symbol(let value): return "symbol:" + value.output
        }
    }
    private enum ReplayError: Error { case unsupportedSchema, unsupportedKey(String) }
}
