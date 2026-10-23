import Dispatch
import Foundation
import Metal
@testable import pag_swift

/// 将真实慢素材的 CPU 成本拆为场景、帧计划、管线和 Metal 输入准备，不创建显示窗口。
@main struct VectorPreparationProbe {
    /// 使用固定构建的库；输出所有采样，不以自然播放结束代替性能验证。
    static func main() async {
        do {
            let root = URL(filePath: CommandLine.arguments[1])
            var reports: [VectorPreparationMeasurement] = []
            for path in ["list/14.pag", "list/17.pag", "TextDirection.pag"] {
                let file = try await PAGLoader().load(from: root.appending(path: path))
                let started = ContinuousClock.now
                let scene = try await PreparedScene.prepare(file.composition)
                let sceneMS = milliseconds(started.duration(to: .now))
                let owner = try VectorProbeOwner()
                let pipelineMS = try await owner.preparePipelines()
                var previousGeometries: Set<ObjectIdentifier> = []
                for round in 0..<2 {
                    for progress in [0.0, 0.0, 0.25, 0.5, 0.75, 0.99] {
                        let time = PAGTime(microseconds: Int64(Double(file.composition.duration.microseconds) * progress))
                        let planStart = ContinuousClock.now
                        let frame = try await FramePlanner.prepare(scene, at: time,
                            targetSize: PAGSize(width: 500, height: 500), scale: 1, mode: .aspectFit)
                        let planMS = milliseconds(planStart.duration(to: .now))
                        let metal = try await owner.prepare(frame)
                        let geometries = Set(frame.shapes.values.map(ObjectIdentifier.init))
                        let shared = geometries.intersection(previousGeometries).count
                        let sources = Set(frame.shapes.keys.filter { $0.sampleFrame != nil }.map(\.source)).count
                        previousGeometries = geometries
                        let sample = VectorPreparationMeasurement(path: path, round: round, progress: progress,
                            sceneMilliseconds: sceneMS, pipelineMilliseconds: pipelineMS,
                            planMilliseconds: planMS, metalMilliseconds: metal.milliseconds,
                            commands: frame.plan.commands.count, draws: metal.draws, inputCacheBytes: metal.bytes,
                            dynamicShapeSources: sources, geometries: geometries.count, sharedWithPrevious: shared)
                        reports.append(sample)
                        print("\(path) round=\(round) progress=\(progress) plan=\(planMS) metal=\(metal.milliseconds) draws=\(metal.draws) sources=\(sources) geometries=\(geometries.count) shared=\(shared)")
                    }
                }
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let artifact = try JSONDecoder().decode([String: String].self,
                from: Data(contentsOf: URL(filePath: CommandLine.arguments[3])))
            let report = VectorPreparationReport(artifact: artifact, date: Date(),
                system: ProcessInfo.processInfo.operatingSystemVersionString, samples: reports)
            try encoder.encode(report).write(to: URL(filePath: CommandLine.arguments[2]), options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("Vector preparation probe failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// 将单调时钟间隔转换为毫秒，避免把秒单位和诊断报告混淆。
    static func milliseconds(_ duration: Duration) -> Double {
        let value = duration.components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
}

/// 独占 Metal 资源和几何 LRU；只返回数值，不跨 actor 传裸 Metal 对象。
private actor VectorProbeOwner {
    /// 同步 Metal 工作使用与生产相同类型的专用串行执行器。
    nonisolated private let executor = DispatchSerialQueue(label: "pag.probe.vector", qos: .userInitiated)
    /// 所有 GPU 输入创建和缓存读取均在专用队列执行。
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    /// 单素材两轮共用输入和几何缓存；不发布未执行 GPU 的 Picture。
    private let resources: MetalResources

    /// 创建独占资源，无设备时明确失败，不生成空的成功报告。
    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw PAGError.graphicsUnavailable }
        resources = try MetalResources(device: device)
    }

    /// 单独测量懒管线构建，后续帧输入成本不再混入首次编译。
    func preparePipelines() throws -> Double {
        let start = ContinuousClock.now
        _ = try resources.pipelines()
        return VectorPreparationProbe.milliseconds(start.duration(to: .now))
    }

    /// 直接调用生产准备入口；未编码批次立即归还附件，Picture 缓存明确关闭。
    func prepare(_ frame: PreparedFrame) throws -> (milliseconds: Double, draws: Int, bytes: Int) {
        let start = ContinuousClock.now
        let batch = try MetalFramePreparation.prepare(frame, width: 500, height: 500,
            resources: resources, disablePictureCache: true)
        let elapsed = VectorPreparationProbe.milliseconds(start.duration(to: .now))
        defer { batch.releaseTransients() }
        // 无真实 GPU 完成不能 publishPictures；此探针只定位未命中快照时的 CPU 准备热点。
        return (elapsed, batch.drawCount, resources.byteCount)
    }
}

/// 单帧 CPU 诊断样本；500×500、关闭 Picture，实际配置由报告记录，不代表屏幕帧率。
private struct VectorPreparationMeasurement: Codable {
    /// 仓库相对资源路径。
    let path: String
    /// 首轮或相同进度的第二轮，用于观察已有几何复用。
    let round: Int
    /// 本次 PAG 根进度，最后采样 0.99 避免把结束空帧当作低成本。
    let progress: Double
    /// 该素材初始 PreparedScene 准备成本，各帧重复保存便于单条报告读取。
    let sceneMilliseconds: Double
    /// 此 owner 的首次 Metal 管线准备成本。
    let pipelineMilliseconds: Double
    /// 该帧时间求值和计划生成成本。
    let planMilliseconds: Double
    /// 该帧网格、输入上传和绘制常量准备成本，不含 GPU 执行。
    let metalMilliseconds: Double
    /// 计划命令数量，包含成对作用域。
    let commands: Int
    /// 实际输入批次包含的绘制数量。
    let draws: Int
    /// 帧准备后 GPU 输入 LRU 计费，不代表进程内存。
    let inputCacheBytes: Int
    /// 此计划实际可见的动态源层数量，用于核对是否超过源层缓存容量。
    let dynamicShapeSources: Int
    /// 本帧不同几何对象的数量；展开实例共享对象只计一次。
    let geometries: Int
    /// 与上一计划仍保活的几何对象交集；零进度重复采样可暴露缓存颠簸。
    let sharedWithPrevious: Int
}

/// 保留构建、系统和测量限制，避免把内部准备诊断当作真实显示 FPS。
private struct VectorPreparationReport: Encodable {
    /// 实际链接库所在固定构建的标识，Release 测量额外开启内部符号可见性。
    let artifact: [String: String]
    /// 本组测量完成时间。
    let date: Date
    /// 主机完整系统版本。
    let system: String
    /// 所有顺序采样，不过滤最慢首次访问。
    let samples: [VectorPreparationMeasurement]
    /// 未编码或呈现 GPU，关闭 Picture；桌面 Demo 无法控制，因此不宣称整机空闲。
    let conditions = "500x500；同源两轮 0/0/0.25/0.5/0.75/0.99；管线成本单列；Picture 关闭；无 GPU 提交；无并行编译/测试；无法确认桌面 Demo 是否仍预览"
}
