import Foundation
import Testing
@testable import pag_swift

/// 确认仓库 `resources/` 已作为测试资源打进测试包，样例 `.pag` 和替换用的 `.mp4` 可被测试直接打开。
@Test func copiedPagFixturesAreBundled() throws {
    let resources = try #require(Bundle.module.resourceURL).appendingPathComponent("Resources")
    let logo = resources.appendingPathComponent("PAG_LOGO.pag")
    let nested = resources.appendingPathComponent("list/0.pag")
    let video = resources.appendingPathComponent("game.mp4")
    #expect(FileManager.default.fileExists(atPath: logo.path))
    #expect(FileManager.default.fileExists(atPath: nested.path))
    #expect(FileManager.default.fileExists(atPath: video.path))
}
