import Foundation
import Testing

/// 包内真实夹具的定位辅助；不生成任何自称合法的 PAG 字节。
enum PAGFixtures {
    /// 返回已拷入测试包的仓库资源根目录，不存在时使测试失败。
    static func rootURL() throws -> URL {
        try #require(Bundle.module.resourceURL).appendingPathComponent("Resources")
    }

    /// 读取指定真实资源，失败沿用 Foundation 的 IO 错误。
    static func data(named name: String) throws -> Data {
        try Data(contentsOf: rootURL().appendingPathComponent(name))
    }

    /// 枚举内容 magic 为 PAG 的真实文件，包含没有扩展名的资源。
    static func allPAGURLs() throws -> [URL] {
        let enumerator = try #require(FileManager.default.enumerator(
            at: rootURL(), includingPropertiesForKeys: [.isRegularFileKey]
        ))
        var result: [URL] = []
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let data = try Data(contentsOf: url)
            if data.prefix(3) == Data([0x50, 0x41, 0x47]) { result.append(url) }
        }
        return result.sorted { $0.path < $1.path }
    }
}
