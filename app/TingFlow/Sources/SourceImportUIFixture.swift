#if DEBUG
import Foundation

/// Generated locally only when the native picker UI test explicitly opts in.
/// Release has no fixture type, bundled sample, or Documents-sharing change.
enum SourceImportUIFixture {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("-TingFlowImportPickerFixture") }
    static func prepare() throws -> URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SourceImportUITest", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let text = "/* @name 文件导入测试源 */\nthrow new Error('import-must-not-execute-script');\n"
        try Data(text.utf8).write(to: base.appendingPathComponent("TingFlow-Import-Check.JS"), options: .atomic)
        try Data("This is not a .js file.".utf8).write(to: base.appendingPathComponent("TingFlow-Wrong-Type.txt"), options: .atomic)
        return base
    }
}
#endif
