import Foundation
import TypingAccuracyMetrics

// No network or dependencies: reads an explicit exported session, emits JSON.
guard (2...3).contains(CommandLine.arguments.count) else {
    FileHandle.standardError.write(Data("Usage: swift run typing-accuracy-report session.json [accepted-references.json]\n".utf8))
    exit(2)
}
do {
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let policy = CommandLine.arguments.count == 3 ? try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])) : nil
    let report = try TypingAccuracyReport.generate(from: data, referencePolicyData: policy)
    FileHandle.standardOutput.write(report)
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    FileHandle.standardError.write(Data("Invalid accuracy session: \(error)\n".utf8))
    exit(1)
}
