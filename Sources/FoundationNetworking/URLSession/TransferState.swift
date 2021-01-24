#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import SwiftFoundation
#else
import Foundation
#endif
@_implementationOnly import CoreFoundation



extension _NativeProtocol {
    
    // 这个数据类里面, 装的是网络交互的过程中, 一直改变的数据.
    // 专门有这么一个类, 来处理网络交互的数据变化, 将交互的逻辑, 封装到内部.
    
    internal struct _TransferState {
        // 资源的地址, 这个是在 init 方法里面填入的
        let url: URL
        // 响应头数据累加过程
        let parsedResponseHeader: _ParsedResponseHeader
        // 通过相应头数据, 生成的 response 对象.
        var response: URLResponse?
        // request 的 data 部分
        let requestBodySource: _BodySource?
        // response 的数据部分.
        let bodyDataDrain: _DataDrain
        /// Describes what to do with received body data for this transfer:
    }
}

extension _NativeProtocol._TransferState {
    /// Transfer state that can receive body data, but will not send body data.
    init(url: URL, bodyDataDrain: _NativeProtocol._DataDrain) {
        self.url = url
        self.parsedResponseHeader = _NativeProtocol._ParsedResponseHeader()
        self.response = nil
        self.requestBodySource = nil
        self.bodyDataDrain = bodyDataDrain
    }
    
    init(url: URL, bodyDataDrain: _NativeProtocol._DataDrain, bodySource: _BodySource) {
        self.url = url
        self.parsedResponseHeader = _NativeProtocol._ParsedResponseHeader()
        self.response = nil
        self.requestBodySource = bodySource
        self.bodyDataDrain = bodyDataDrain
    }
}



extension _HTTPURLProtocol._TransferState {
    
    // headerLine 一定是一行数据, 这是 libCurl 中应该负起的责任.
    func byAppendingHTTP(headerLine data: Data) throws -> _NativeProtocol._TransferState {

        func isCompleteHeader(_ headerLine: String) -> Bool {
            return headerLine.isEmpty
        }
        guard let h = parsedResponseHeader.byAppending(headerLine: data, onHeaderCompleted: isCompleteHeader) else {
            throw _Error.parseSingleLineError
        }
        if case .complete(let lines) = h {
            // Header is complete
            let response = lines.createHTTPURLResponse(for: url)
            guard response != nil else {
                throw _Error.parseCompleteHeaderError
            }
            // 通过原来的值, 复制一份新的数据, 
            return _NativeProtocol._TransferState(url: url,
                                                  parsedResponseHeader: _NativeProtocol._ParsedResponseHeader(),
                                                  response: response,
                                                  requestBodySource: requestBodySource,
                                                  bodyDataDrain: bodyDataDrain)
        } else {
            return _NativeProtocol._TransferState(url: url,
                                                  parsedResponseHeader: h, response: nil, requestBodySource: requestBodySource, bodyDataDrain: bodyDataDrain)
        }
    }
}

// specific to FTP
extension _FTPURLProtocol._TransferState {
    enum FTPHeaderCode: Int {
        case transferCompleted = 226
        case openDataConnection = 150
        case fileStatus = 213
        case syntaxError = 500// 500 series FTP Syntax errors
        case errorOccurred = 400 // 400 Series FTP transfer errors
    }

    /// Appends a header line
    ///
    /// Will set the complete response once the header is complete, i.e. the
    /// return value's `isHeaderComplete` will then by `true`.
    ///
    /// - Throws: When a parsing error occurs
    func byAppendingFTP(headerLine data: Data, expectedContentLength: Int64) throws -> _NativeProtocol._TransferState {
        guard let line = String(data: data, encoding: String.Encoding.utf8) else {
            fatalError("Data on command port is nil")
	}

        //FTP Status code 226 marks the end of the transfer
        if (line.starts(with: String(FTPHeaderCode.transferCompleted.rawValue))) {
            return self
        }
        //FTP Status code 213 marks the end of the header and start of the
        //transfer on data port
        func isCompleteHeader(_ headerLine: String) -> Bool {
            return headerLine.starts(with: String(FTPHeaderCode.openDataConnection.rawValue))
        }
        guard let h = parsedResponseHeader.byAppending(headerLine: data, onHeaderCompleted: isCompleteHeader) else {
            throw _NativeProtocol._Error.parseSingleLineError
        }

        if case .complete(let lines) = h {
            let response = lines.createURLResponse(for: url, contentLength: expectedContentLength)
            guard response != nil else {
                throw _NativeProtocol._Error.parseCompleteHeaderError
            }
            return _NativeProtocol._TransferState(url: url, parsedResponseHeader: _NativeProtocol._ParsedResponseHeader(), response: response, requestBodySource: requestBodySource, bodyDataDrain: bodyDataDrain)
        } else {
            return _NativeProtocol._TransferState(url: url, parsedResponseHeader: _NativeProtocol._ParsedResponseHeader(), response: nil, requestBodySource: requestBodySource, bodyDataDrain: bodyDataDrain)
        }
    }
}

extension _NativeProtocol._TransferState {

    enum _Error: Error {
        case parseSingleLineError
        case parseCompleteHeaderError
    }

    // 一个简单的 get 计算属性, 当 response 有值了之后自动变化.
    // 计算属性的优势就在于, 这是一个函数. 每次都会重新计算. 不用花心思去做同步这件事情.
    var isHeaderComplete: Bool {
        return response != nil
    }
    
    func byAppending(bodyData buffer: Data) -> _NativeProtocol._TransferState {
        switch bodyDataDrain {
        case .inMemory(let bodyData):
            // 这里, 不返回 self, 是因为 data 可能发生变化, 当第一次数据到达的时候, 会有一个 NSMutableData 的创建工作.
            let data: NSMutableData = bodyData ?? NSMutableData()
            data.append(buffer)
            let drain = _NativeProtocol._DataDrain.inMemory(data)
            return _NativeProtocol._TransferState(url: url,
                                                  parsedResponseHeader: parsedResponseHeader,
                                                  response: response,
                                                  requestBodySource: requestBodySource,
                                                  bodyDataDrain: drain)
        // 这里不会造成两次写入吗???
        case .toFile(_, let fileHandle):
             //TODO: Create / open the file for writing
             // Append to the file
             _ = fileHandle!.seekToEndOfFile()
             fileHandle!.write(buffer)
             return self
        case .ignore:
            return self
        }
    }
    /// Sets the given body source on the transfer state.
    ///
    /// This can be used to either set the initial body source, or to reset it
    /// e.g. when restarting a transfer.
    func bySetting(bodySource newSource: _BodySource) -> _NativeProtocol._TransferState {
        return _NativeProtocol._TransferState(url: url,
                                              parsedResponseHeader: parsedResponseHeader, response: response, requestBodySource: newSource, bodyDataDrain: bodyDataDrain)
    }
}

extension _NativeProtocol {
    enum _DataDrain {
        // 响应的 body 部分都在 NSMutableData 中
        case inMemory(NSMutableData?)
        // 响应的 body 部分, 都在 URL 对应的 File 里面
        case toFile(URL, FileHandle?)
        // 响应的值, 没有存
        case ignore
    }
}
