#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import SwiftFoundation
#else
import Foundation
#endif

@_implementationOnly import CoreFoundation
@_implementationOnly import CFURLSessionInterface
import Dispatch


/// Turn `Data` into `DispatchData`
internal func createDispatchData(_ data: Data) -> DispatchData {
    //TODO: Avoid copying data
    return data.withUnsafeBytes { DispatchData(bytes: $0) }
}

/// Copy data from `DispatchData` into memory pointed to by an `UnsafeMutableBufferPointer`.
internal func copyDispatchData<T>(_ data: DispatchData, infoBuffer buffer: UnsafeMutableBufferPointer<T>) {
    precondition(data.count <= (buffer.count * MemoryLayout<T>.size))
    _ = data.copyBytes(to: buffer)
}

/// Split `DispatchData` into `(head, tail)` pair.
internal func splitData(dispatchData data: DispatchData, atPosition position: Int) -> (DispatchData,DispatchData) {
    return (data.subdata(in: 0..<position), data.subdata(in: position..<data.count))
}

// 这是一个协议.
// 目前来说, 会被三个实现, 内存 data, 文件 data, stream data.
// 这个协议, 实现的就是流读取的过程.
internal protocol _BodySource: AnyObject {
    func getNextChunk(withLength length: Int) -> _BodySourceDataChunk
}

// 在之前使用流含义的 C api 的时候, 是返回值加传出参数的方式. 现在, 通过枚举, 一次搞定了.
// 所以, 枚举的方式, 基本上解决了传出参数的问题.
internal enum _BodySourceDataChunk {
    case data(DispatchData)
    case done
    case retryLater
    case error
}

internal final class _BodyStreamSource {
    let inputStream: InputStream
    
    init(inputStream: InputStream) {
        assert(inputStream.streamStatus == .notOpen)
        inputStream.open()
        self.inputStream = inputStream
    }
}

extension _BodyStreamSource : _BodySource {
    func getNextChunk(withLength length: Int) -> _BodySourceDataChunk {
        // 如果, 没有数据了, 就是完成了.
        guard inputStream.hasBytesAvailable else {
            return .done
        }
        
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: length, alignment: MemoryLayout<UInt8>.alignment)
        // assumingMemoryBound 这个方法, 是将一个 rawPointer, 转换成为一个特定类型的 MutablePointer
        guard let pointer = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
            buffer.deallocate()
            return .error
        }
        
        // 这里, 还是使用到了原始的流读取的函数.
        let readBytes = self.inputStream.read(pointer, maxLength: length)
        if readBytes > 0 {
            let dispatchData = DispatchData(bytesNoCopy: UnsafeRawBufferPointer(buffer),
                                            deallocator: .custom(nil, { buffer.deallocate() }))
            return .data(dispatchData.subdata(in: 0 ..< readBytes))
        } else if readBytes == 0 {
            buffer.deallocate()
            return .done
        } else {
            buffer.deallocate()
            return .error
        }
    }
}

/// A body data source backed by `DispatchData`.
internal final class _BodyDataSource {
    var data: DispatchData! 
    init(data: DispatchData) {
        self.data = data
    }
}

// 内存里面的 data.
extension _BodyDataSource : _BodySource {
    enum _Error : Error {
        case unableToRewindData
    }

    func getNextChunk(withLength length: Int) -> _BodySourceDataChunk {
        let remaining = data.count
        if remaining == 0 {
            return .done
        } else if remaining <= length {
            let r: DispatchData! = data
            data = DispatchData.empty 
            return .data(r)
        } else {
            let (chunk, remainder) = splitData(dispatchData: data, atPosition: length)
            data = remainder
            return .data(chunk)
        }
    }
}


internal final class _BodyFileSource {
    fileprivate let fileURL: URL
    fileprivate let channel: DispatchIO
    fileprivate let workQueue: DispatchQueue
    fileprivate let dataAvailableHandler: () -> Void
    fileprivate var hasActiveReadHandler = false
    fileprivate var availableChunk: _Chunk = .empty

    /// Create a new data source backed by a file.
    ///
    /// - Parameter fileURL: the file to read from
    /// - Parameter workQueue: the queue that it's safe to call
    ///     `getNextChunk(withLength:)` on, and that the `dataAvailableHandler`
    ///     will be called on.
    /// - Parameter dataAvailableHandler: Will be called when data becomes
    ///     available. Reading data is done in a non-blocking way, such that
    ///     no data may be available even if there's more data in the file.
    ///     if `getNextChunk(withLength:)` returns `.retryLater`, this handler
    ///     will be called once data becomes available.
    init(fileURL: URL, workQueue: DispatchQueue, dataAvailableHandler: @escaping () -> Void) {
        guard fileURL.isFileURL else { fatalError("The body data URL must be a file URL.") }
        self.fileURL = fileURL
        self.workQueue = workQueue
        self.dataAvailableHandler = dataAvailableHandler

        guard let channel = fileURL.withUnsafeFileSystemRepresentation({
            // DispatchIO (dispatch_io_create_with_path) makes a copy of the path
            DispatchIO(type: .stream, path: $0!,
                       oflag: O_RDONLY, mode: 0, queue: workQueue,
                       cleanupHandler: {_ in })
        }) else {
            fatalError("Can't create DispatchIO channel")
        }
        self.channel = channel
        self.channel.setLimit(highWater: CFURLSessionMaxWriteSize)
    }

    fileprivate enum _Chunk {
        /// Nothing has been read, yet
        case empty
        /// An error has occurred while reading
        case errorDetected(Int)
        /// Data has been read
        case data(DispatchData)
        /// All data has been read from the file (EOF).
        case done(DispatchData?)
    }
}

extension _BodyFileSource {
    fileprivate var desiredBufferLength: Int { return 3 * CFURLSessionMaxWriteSize }
    /// Enqueue a dispatch I/O read to fill the buffer.
    ///
    /// - Note: This is a no-op if the buffer is full, or if a read operation
    /// is already enqueued.
    fileprivate func readNextChunk() {
        // libcurl likes to use a buffer of size CFURLSessionMaxWriteSize, we'll
        // try to keep 3 x of that around in the `chunk` buffer.
        guard availableByteCount < desiredBufferLength else { return }
        guard !hasActiveReadHandler else { return } // We're already reading
        hasActiveReadHandler = true
        
        let lengthToRead = desiredBufferLength - availableByteCount
        channel.read(offset: 0, length: lengthToRead, queue: workQueue) { (done: Bool, data: DispatchData?, errno: Int32) in
            let wasEmpty = self.availableByteCount == 0
            self.hasActiveReadHandler = !done
            
            switch (done, data, errno) {
            case (true, _, errno) where errno != 0:
                self.availableChunk = .errorDetected(Int(errno))
            case (true, let d?, 0) where d.isEmpty:
                self.append(data: d, endOfFile: true)
            case (true, let d?, 0):
                self.append(data: d, endOfFile: false)
            case (false, let d?, 0):
                self.append(data: d, endOfFile: false)
            default:
                fatalError("Invalid arguments to read(3) callback.")
            }
            
            if wasEmpty && (0 < self.availableByteCount) {
                self.dataAvailableHandler()
            }
        }
    }

    fileprivate func append(data: DispatchData, endOfFile: Bool) {
        switch availableChunk {
        case .empty:
            availableChunk = endOfFile ? .done(data) : .data(data)
        case .errorDetected:
            break
        case .data(var oldData):
            oldData.append(data)
            availableChunk = endOfFile ? .done(oldData) : .data(oldData)
        case .done:
            fatalError("Trying to append data, but end-of-file was already detected.")
        }
    }

    fileprivate var availableByteCount: Int {
        switch availableChunk {
        case .empty: return 0
        case .errorDetected: return 0
        case .data(let d): return d.count
        case .done(let d?): return d.count
        case .done(nil): return 0
        }
    }
}

extension _BodyFileSource : _BodySource {
    func getNextChunk(withLength length: Int) -> _BodySourceDataChunk {    
        switch availableChunk {
        case .empty:
            readNextChunk()
            return .retryLater
        case .errorDetected:
            return .error
        case .data(let data):
            let l = min(length, data.count)
            let (head, tail) = splitData(dispatchData: data, atPosition: l)
            
            availableChunk = tail.isEmpty ? .empty : .data(tail)
            readNextChunk()
            
            if head.isEmpty {
                return .retryLater
            } else {
                return .data(head)
            }
        case .done(let data?):
            let l = min(length, data.count)
            let (head, tail) = splitData(dispatchData: data, atPosition: l)
            availableChunk = tail.isEmpty ? .done(nil) : .done(tail)
            if head.isEmpty {
                return .done
            } else {
                return .data(head)
            }
        case .done(nil):
            return .done
        }
    }
}
