import Darwin
import Foundation

/// 从本地普通文件取得有界稳定快照；文件描述符仅在一次后台调用中存活。
enum StableFileReader {
    /// 逐块读取并比较来源身份；变化抛 sourceChanged，其他失败保留 POSIX 错误码。
    /// beforeVerification 仅供内部确定性验证，在读取完毕、最终来源核对前执行。
    @concurrent static func read(from url: URL, limits: PAGLoadLimits,
                                 beforeVerification: (@Sendable () throws -> Void)? = nil) async throws -> LoadSnapshot {
        try Task.checkCancellation()
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw PAGError.unsupportedURL
        }
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let initialPath = try metadata(at: canonical)
        try validateFile(initialPath, limits: limits)
        let descriptor = canonical.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            // NONBLOCK 避免检查后被替换成 FIFO 时卡住；NOFOLLOW 拒绝最后一级符号链接竞态。
            return Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { throw ioError() }
        defer { Darwin.close(descriptor) }
        let initialHandle = try metadata(of: descriptor)
        guard initialHandle == initialPath else { throw PAGError.sourceChanged }
        var data = Data(capacity: Int(initialHandle.byteCount))
        var buffer = [UInt8](repeating: 0, count: min(65_536, max(1, Int(initialHandle.byteCount))))
        while true {
            try Task.checkCancellation()
            let count = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ioError()
            }
            if count == 0 { break }
            // 文件增长时不能为了“读到末尾”突破已核对的长度和内存预算。
            guard count <= Int(initialHandle.byteCount) - data.count else { throw PAGError.sourceChanged }
            data.append(contentsOf: buffer.prefix(count))
        }
        try beforeVerification?()
        try Task.checkCancellation()
        let finalHandle = try metadata(of: descriptor)
        let finalCanonical = url.standardizedFileURL.resolvingSymlinksInPath()
        let finalPath: FileFingerprint
        do { finalPath = try metadata(at: canonical) }
        catch { throw PAGError.sourceChanged }
        guard finalCanonical == canonical, finalHandle == initialHandle, finalPath == initialHandle,
              data.count == initialHandle.byteCount else { throw PAGError.sourceChanged }
        return try await LoadSnapshot.prepare(data: data, limits: limits)
    }

    /// 验证普通文件和声明长度，所有大块分配都发生在这些检查之后。
    private static func validateFile(_ metadata: FileFingerprint, limits: PAGLoadLimits) throws {
        guard metadata.isRegular, metadata.byteCount >= 0 else {
            throw PAGError.ioFailure(domain: NSPOSIXErrorDomain, code: Int(EINVAL))
        }
        guard metadata.byteCount <= limits.maximumFileBytes else { throw PAGError.resourceLimitExceeded("maximumFileBytes") }
        guard metadata.byteCount <= limits.maximumDecodedBytes else { throw PAGError.resourceLimitExceeded("maximumDecodedBytes") }
    }

    /// 使用路径 stat 取得设备、inode 和高精度时间；不把文件名视为身份。
    private static func metadata(at url: URL) throws -> FileFingerprint {
        var value = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return fstatat(AT_FDCWD, path, &value, 0)
        }
        guard status == 0 else { throw ioError() }
        return FileFingerprint(value)
    }

    /// 使用已打开描述符 fstat，核对实际读取对象而非仅核对路径字符串。
    private static func metadata(of descriptor: Int32) throws -> FileFingerprint {
        var value = stat()
        guard fstat(descriptor, &value) == 0 else { throw ioError() }
        return FileFingerprint(value)
    }

    /// 立即捕获当前 errno，避免其他系统调用覆盖原始失败原因。
    private static func ioError() -> PAGError {
        .ioFailure(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}

/// 只保留稳定性比较需要的 POSIX 标量，不跨隔离传递文件句柄或资源标识对象。
private struct FileFingerprint: Equatable {
    /// 设备编号与 inode 共同区分文件实体。
    let device: Int64
    /// 当前设备上的文件编号。
    let inode: UInt64
    /// 文件的原始字节长度，非负才可读取。
    let byteCount: Int64
    /// 修改时间的秒部分。
    let modifiedSeconds: Int64
    /// 修改时间的纳秒部分，避免秒级时间戳漏检。
    let modifiedNanoseconds: Int64
    /// 元数据变化时间的秒部分，可检测恢复 mtime 的改写。
    let changedSeconds: Int64
    /// 元数据变化时间的纳秒部分。
    let changedNanoseconds: Int64
    /// 是否为普通文件；目录、FIFO、设备均不作为 PAG 文件读取。
    let isRegular: Bool

    /// 从本次 stat 的值提取所有核对标量，不保留平台结构体指针。
    init(_ value: stat) {
        device = Int64(value.st_dev)
        inode = UInt64(value.st_ino)
        byteCount = value.st_size
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec)
        changedNanoseconds = Int64(value.st_ctimespec.tv_nsec)
        isRegular = value.st_mode & S_IFMT == S_IFREG
    }
}
