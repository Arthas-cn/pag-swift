import Testing
@testable import pag_swift

/// 完整可载入真实文件中的Vector内容候选，给④c1c正式GPU画面选择源夹具。
struct VectorPictureFileCandidateTests {
    /// TextDirection是现有成功样本中的定义级Vector候选，Star及文字都属于同一真实内容。
    @Test func textDirectionRequestsVectorPicture() async throws {
        let file = try await PAGLoader().load(data: PAGFixtures.data(named: "TextDirection.pag"))
        let scene = try await PreparedScene.prepare(file.composition)
        #expect(scene.pictureCandidates.vector.count == file.storage.compositions.count)
        #expect(scene.pictureCandidates.vector[file.storage.rootIndex])
        #expect(file.storage.compositions[file.storage.rootIndex].layers.count > 1)
        let frame = try await FramePlanner.prepare(scene, at: .zero, targetSize: file.composition.size,
                                                   scale: 1, mode: .aspectFit)
        let commands = frame.plan.commands
        guard case .beginVectorPicture(let marker) = commands.first,
              case .beginGroup(let group) = commands.dropFirst().first,
              case .endGroup = commands.dropLast().last,
              case .endVectorPicture = commands.last else {
            Issue.record("Vector范围必须包住根定义clip及全部子图元")
            return
        }
        #expect(marker.document == file.storage.identity)
        #expect(marker.definitionIndex == file.storage.rootIndex)
        #expect(marker.layerID == nil)
        #expect(group.definitionIndex == marker.definitionIndex)
        #expect(group.layerID == nil && group.opacity == 1)
        #expect(group.clip.matrix == marker.matrix)
        #expect(commands.contains { if case .shape = $0 { true } else { false } })
        #expect(commands.contains { if case .text = $0 { true } else { false } })
    }
}
