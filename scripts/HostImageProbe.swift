import Foundation
import AppKit
import SDWebImage
@testable import pag_swift

/// 独立宿主链路探针，不启动 Demo 窗口；检查 SD 解码、provider 和真实 PAG 帧计划。
@main struct HostImageProbe {
    /// 从参数读取资源根和报告路径，任何断言失败返回非零退出状态。
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("宿主探针失败：\(error)\n".utf8))
            exit(1)
        }
    }

    /// 执行完整探针并输出报告，错误由入口转为可读诊断而非顶层崩溃。
    static func run() async throws {
        let root = URL(filePath: CommandLine.arguments[1], directoryHint: .isDirectory)
        let file = try await PAGLoader().load(from: root.appending(path: "editing/replace.pag"))
        guard let slot = file.contentSlots.first(where: { $0.tag == "scene.png" }) else {
            throw PAGError.invalidArgument("probeSceneSlot")
        }
        var rows: [ResultRow] = []
        for name in ["bear.gif", "webp01.webp", "optimized-disposal.gif"] {
            let image = try await DemoSDWebImage.load(from: root.appending(path: "media/\(name)"))
            guard let animation = image.animation, let source = animation.externalSource,
                  let first = try source.frame(at: 0), let second = try source.frame(at: 1),
                  first.pixels != second.pixels else { throw PAGError.mediaFailure("probeAnimatedFrames:\(name)") }
            if name == "optimized-disposal.gif" {
                let expected: [[UInt8]] = [[255,0,0,255,255,0,0,255], [255,0,0,255,0,0,255,255],
                    [255,0,0,255,0,255,0,255], [0,0,255,255,0,0,0,255]]
                for (index, pixels) in expected.enumerated() {
                    let actual = try source.frame(at: index)?.pixels
                    guard actual == Data(pixels) else {
                        let raw = SDAnimatedImage(data: try Data(contentsOf: root.appending(path: "media/\(name)")))
                        let native = raw?.animatedImageFrame(at: UInt(index))
                        let bitmap = native?.representations.compactMap { $0 as? NSBitmapImageRep }.first
                        let rawBytes = bitmap?.cgImage?.dataProvider?.data as Data?
                        throw PAGError.mediaFailure("probeGIFDisposal:\(index) expected=\(pixels) actual=\(actual.map(Array.init) ?? []) space=\(String(describing: bitmap?.cgImage?.colorSpace)) raw=\(rawBytes.map { Array($0.prefix(16)) } ?? [])")
                    }
                }
            }
            let player = PAGPlayer()
            try await player.setComposition(file.composition)
            var events = await player.contentUpdates().makeAsyncIterator()
            try await player.setContentProvider { requested in requested.tag == slot.tag ? .image(image) : .unchanged }
            var installed = false
            while let event = await events.next(isolation: #isolation) {
                if event.tag == slot.tag {
                    if event.status == .applied { installed = true; break }
                    if event.status == .failed { throw PAGError.mediaFailure(event.detail ?? "probeProvider") }
                }
            }
            guard installed, let composition = await player.contentComposition else {
                throw PAGError.mediaFailure("probeNotInstalled")
            }
            let scene = try await PreparedScene.prepare(composition)
            var distinct: Set<DocumentIdentity> = []
            for time: Int64 in [0, 100_000, 250_000, 500_000, 1_000_000] {
                let frame = try await FramePlanner.prepare(scene, at: PAGTime(microseconds: time),
                    targetSize: composition.size, scale: 1, mode: .aspectFit,
                    imageAnimationTime: PAGTime(microseconds: time))
                for image in frame.images.values where image.storage.sourceType == "pag.hostFrame" {
                    distinct.insert(image.storage.identity)
                }
            }
            guard distinct.count > 1, composition.edits.visibility.isEmpty else {
                throw PAGError.mediaFailure("probePAGFrameChange:\(name)")
            }
            rows.append(ResultRow(file: name, frames: animation.ends.count, totalPlays: animation.playCount,
                width: first.width, height: first.height, uniquePAGFrames: distinct.count,
                adjacentPixelsDiffer: first.pixels != second.pixels))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(rows)
        try data.write(to: URL(filePath: CommandLine.arguments[2]))
        print(String(decoding: data, as: UTF8.self))
    }
}

/// 机器可读报告仅声明解码和生产帧计划证据，不冒充 Metal 提交或真实屏幕画面。
private struct ResultRow: Encodable {
    /// 实际由宿主加载的资源相对名。
    let file: String
    /// SD 返回的帧数，必须大于一。
    let frames: Int
    /// 有限总播放轮数，nil 表示无限。
    let totalPlays: Int?
    /// 完整画布宽度。
    let width: Int
    /// 完整画布高度。
    let height: Int
    /// 真实 PAG 在五个采样时刻中实际消费的不同动态纹理输入数。
    let uniquePAGFrames: Int
    /// 相邻完整帧像素是否发生变化。
    let adjacentPixelsDiffer: Bool
}
