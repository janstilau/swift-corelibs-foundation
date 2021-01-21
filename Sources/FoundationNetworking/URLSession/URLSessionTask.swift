#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import SwiftFoundation
#else
import Foundation
#endif
@_implementationOnly import CoreFoundation

private class Bag<Element> {
    var values: [Element] = []
}

/// A cancelable object that refers to the lifetime
/// of processing a given request.
open class URLSessionTask : NSObject, NSCopying {
    
    // These properties aren't heeded in swift-corelibs-foundation, but we may heed them in the future. They exist for source compatibility.
    open var countOfBytesClientExpectsToReceive: Int64 = NSURLSessionTransferSizeUnknown {
        didSet { updateProgress() }
    }
    open var countOfBytesClientExpectsToSend: Int64 = NSURLSessionTransferSizeUnknown {
        didSet { updateProgress() }
    }
    
    #if NS_CURL_MISSING_XFERINFOFUNCTION
    @available(*, deprecated, message: "This platform doesn't fully support reporting the progress of a URLSessionTask. The progress instance returned will be functional, but may not have continuous updates as bytes are sent or received.")
    open private(set) var progress = Progress(totalUnitCount: -1)
    #else
    open private(set) var progress = Progress(totalUnitCount: -1)
    #endif
    
    func updateProgress() {
        self.workQueue.async {
            let progress = self.progress
            
            switch self.state {
            case .canceling: fallthrough
            case .completed:
                let total = progress.totalUnitCount
                let finalTotal = total < 0 ? 1 : total
                progress.totalUnitCount = finalTotal
                progress.completedUnitCount = finalTotal
                
            default:
                let toBeSent: Int64?
                if let bodyLength = try? self.knownBody?.getBodyLength() {
                    toBeSent = Int64(clamping: bodyLength)
                } else if self.countOfBytesExpectedToSend > 0 {
                    toBeSent = Int64(clamping: self.countOfBytesExpectedToSend)
                } else if self.countOfBytesClientExpectsToSend != NSURLSessionTransferSizeUnknown && self.countOfBytesClientExpectsToSend > 0 {
                    toBeSent = Int64(clamping: self.countOfBytesClientExpectsToSend)
                } else {
                    toBeSent = nil
                }
                
                let sent = self.countOfBytesSent
                
                let toBeReceived: Int64?
                if self.countOfBytesExpectedToReceive > 0 {
                    toBeReceived = Int64(clamping: self.countOfBytesClientExpectsToReceive)
                } else if self.countOfBytesClientExpectsToReceive != NSURLSessionTransferSizeUnknown && self.countOfBytesClientExpectsToReceive > 0 {
                    toBeReceived = Int64(clamping: self.countOfBytesClientExpectsToReceive)
                } else {
                    toBeReceived = nil
                }
                
                let received = self.countOfBytesReceived
                
                progress.completedUnitCount = sent.addingReportingOverflow(received).partialValue
                
                if let toBeSent = toBeSent, let toBeReceived = toBeReceived {
                    progress.totalUnitCount = toBeSent.addingReportingOverflow(toBeReceived).partialValue
                } else {
                    progress.totalUnitCount = -1
                }
                
            }
        }
    }
    
    // We're not going to heed this one. If someone is setting it in Linux code, they may be relying on behavior that isn't there; warn.
    @available(*, deprecated, message: "")
    open var earliestBeginDate: Date? = nil
    
    // 居然还有这么一个计数器, 只有到 0 的时候, resume 才能启动 loading
    internal var suspendCount = 1
    
    internal var actualSession: URLSession? { return session as? URLSession }
    internal var session: URLSessionProtocol! //change to nil when task completes
    
    fileprivate enum ProtocolState {
        case toBeCreated // 还没有 protocol 呢
        case awaitingCacheReply(Bag<(URLProtocol?) -> Void>) // 等着查找缓存, 然后出发存储的回调.
        case existing(URLProtocol) // 建立了一个, 存在这. 通过枚举, 状态和值, 绑定在了一起.
        case invalidated
    }
    
    fileprivate let _protocolLock = NSLock() // protects:
    fileprivate var _protocolStorage: ProtocolState = .toBeCreated
    internal    var _lastCredentialUsedFromStorageDuringAuthentication:
        (protectionSpace: URLProtectionSpace, credential: URLCredential)?
    
    // 这里, 是属性, 是 get 方法. 不是初始化.
    private var _protocolClass: URLProtocol.Type {
        guard let request = currentRequest else { fatalError("A protocol class was requested, but we do not have a current request") }
        let protocolClasses = session.configuration.protocolClasses ?? [] // 默认只有, http, ftp.
        // 首先, 通过 config 把能够使用的 protocol 拿出来, 然后通过 URLProtocol 进行判断.
        if let urlProtocolClass = URLProtocol.getProtocolClass(protocols: protocolClasses, request: request) {
            // 然后这里还有一次类型的 iskindof 的判断.
            // 在 Swift 里面, iskindof, 就是 as? 的方式.
            guard let urlProtocol = urlProtocolClass as? URLProtocol.Type else { fatalError("A protocol class specified in the URLSessionConfiguration's .protocolClasses array was not a URLProtocol subclass: \(urlProtocolClass)") }
            return urlProtocol
        } else {
            // 如果 config 里面的都不行, 那么就用 URLProtocol 里面注册的捋一遍.
            let protocolClasses = URLProtocol.getProtocols() ?? []
            if let urlProtocolClass = URLProtocol.getProtocolClass(protocols: protocolClasses, request: request) {
                guard let urlProtocol = urlProtocolClass as? URLProtocol.Type else { fatalError("A protocol class registered with URLProtocol.register… was not a URLProtocol subclass: \(urlProtocolClass)") }
                return urlProtocol
            }
        }
        
        fatalError("Couldn't find a protocol appropriate for request: \(request)")
    }
    
    // 先获取到 protocol 对象, 然后执行闭包不可以吗????
    func _getProtocol(_ callback: @escaping (URLProtocol?) -> Void) {
        _protocolLock.lock() // Must be balanced below, before we call out ⬇
        
        switch _protocolStorage {
        case .toBeCreated:
            // 如果, 有缓存, task 又是最简单的 dataTask.
            if let cache = session.configuration.urlCache, let me = self as? URLSessionDataTask {
                
                let bag: Bag<(URLProtocol?) -> Void> = Bag()
                bag.values.append(callback)
                _protocolStorage = .awaitingCacheReply(bag)
                _protocolLock.unlock()
                // 之所以这么麻烦, 是因为 getCachedResponse 是一个异步操作.
                cache.getCachedResponse(for: me) { (response) in
                    // 因为在 protocol 里面, 这是一个 require 的 init 方法. 这里才能这么用.
                    let urlProtocol = self._protocolClass.init(task: self,
                                                               cachedResponse: response,
                                                               client: nil)
                    self._satisfyProtocolRequest(with: urlProtocol)
                }
            } else {
                // 如果, 没有缓存, 就真正的进行 protocol 的创建.
                let urlProtocol = _protocolClass.init(task: self, cachedResponse: nil, client: nil)
                _protocolStorage = .existing(urlProtocol)
                _protocolLock.unlock()
                callback(urlProtocol)
            }
            
        case .awaitingCacheReply(let bag):
            bag.values.append(callback)
            _protocolLock.unlock()
            
        case .existing(let urlProtocol):
            _protocolLock.unlock() // Balances above ⬆
            callback(urlProtocol)
            
        case .invalidated:
            _protocolLock.unlock() // Balances above ⬆
            callback(nil)
        }
    }
    
    func _satisfyProtocolRequest(with urlProtocol: URLProtocol) {
        _protocolLock.lock() // Must be balanced below, before we call out ⬇
        switch _protocolStorage {
        case .toBeCreated:
            _protocolStorage = .existing(urlProtocol)
            _protocolLock.unlock()
            
        case .awaitingCacheReply(let bag): // 这里, 因为 _protocolStorage 被重新复制, bag 的生命周期, 就只有这里了.
            _protocolStorage = .existing(urlProtocol)
            _protocolLock.unlock()
            for callback in bag.values {
                callback(urlProtocol)
            }
        case .existing(_): fallthrough
        case .invalidated:
            _protocolLock.unlock()
        }
    }
    
    func _invalidateProtocol() {
        _protocolLock.performLocked {
            _protocolStorage = .invalidated // 这里, 其实就是丢失了 protocol 的引用了.
        }
    }
    
    
    internal var knownBody: _Body?
    func getBody(completion: @escaping (_Body) -> Void) {
        if let body = knownBody {
            completion(body)
            return
        }
        
        if let session = actualSession, let delegate = session.delegate as? URLSessionTaskDelegate {
            delegate.urlSession(session, task: self) { (stream) in
                if let stream = stream {
                    completion(.stream(stream))
                } else {
                    completion(.none)
                }
            }
        } else {
            completion(.none)
        }
    }
    
    // 类中, 所有的 get, set 都是通过该队列进行的.
    // 其实这就是一把锁.
    private let syncQ = DispatchQueue(label: "org.swift.URLSessionTask.SyncQ")
    private var hasTriggeredResume: Bool = false
    internal var isSuspendedAfterResume: Bool {
        return self.syncQ.sync { return self.hasTriggeredResume } && self.state == .suspended
    }
    
    /// All operations must run on this queue.
    internal let workQueue: DispatchQueue 
    
    // init 方法很少调用. 还是用的下面的, 带有各个实际参数的.
    // dataTask 这个类, 只会在 Session 里面初始化. 自己不会调用的
    public override init() {
        session = _MissingURLSession()
        taskIdentifier = 0
        originalRequest = nil
        knownBody = URLSessionTask._Body.none
        // 一个串行的队列.
        workQueue = DispatchQueue(label: "URLSessionTask.notused.0")
        super.init()
    }
    
    internal convenience init(session: URLSession,
                              request: URLRequest,
                              taskIdentifier: Int) {
        // 这里, 做了第一层的 body 的抽取工作.
        if let bodyData = request.httpBody, !bodyData.isEmpty {
            self.init(session: session, request: request, taskIdentifier: taskIdentifier, body: _Body.data(createDispatchData(bodyData)))
        } else if let bodyStream = request.httpBodyStream {
            self.init(session: session, request: request, taskIdentifier: taskIdentifier, body: _Body.stream(bodyStream))
        } else {
            self.init(session: session, request: request, taskIdentifier: taskIdentifier, body: _Body.none)
        }
    }
    
    internal init(session: URLSession, request: URLRequest, taskIdentifier: Int, body: _Body?) {
        self.session = session
        /* make sure we're actually having a serial queue as it's used for synchronization */
        self.workQueue = DispatchQueue.init(label: "org.swift.URLSessionTask.WorkQueue", target: session.workQueue)
        self.taskIdentifier = taskIdentifier
        self.originalRequest = request // 这个值, 以后只会读不会改. 因为会有重定向的原因, 所以专门记一下.
        self.knownBody = body
        super.init()
        self.currentRequest = request // 实际的请求, 会因为重定向改变.
        // process cancel 的后续触发逻辑.  process 这个类不是很了解.
        self.progress.cancellationHandler = { [weak self] in
            self?.cancel()
        }
    }
    deinit {
        //TODO: Do we remove the EasyHandle from the session here? This might run on the wrong thread / queue.
    }
    
    open override func copy() -> Any {
        return copy(with: nil)
    }
    
    open func copy(with zone: NSZone?) -> Any {
        return self
    }
    
    /// An identifier for this task, assigned by and unique to the owning session
    open internal(set) var taskIdentifier: Int
    
    /// May be nil if this is a stream task
    open private(set) var originalRequest: URLRequest?
    
    /// If there's an authentication failure, we'd need to create a new request with the credentials supplied by the user
    var authRequest: URLRequest? = nil
    
    /// Authentication failure count
    fileprivate var previousFailureCount = 0
    
    /// May differ from originalRequest due to http server redirection
    open internal(set) var currentRequest: URLRequest? {
        get {
            return self.syncQ.sync { return self._currentRequest }
        }
        set {
            self.syncQ.sync { self._currentRequest = newValue }
        }
    }
    fileprivate var _currentRequest: URLRequest? = nil
    /*@NSCopying*/ open internal(set) var response: URLResponse? {
        get {
            return self.syncQ.sync { return self._response }
        }
        set {
            self.syncQ.sync { self._response = newValue }
        }
    }
    fileprivate var _response: URLResponse? = nil
    
    /* Byte count properties may be zero if no body is expected,
     * or URLSessionTransferSizeUnknown if it is not possible
     * to know how many bytes will be transferred.
     */
    
    /// Number of body bytes already received
    open internal(set) var countOfBytesReceived: Int64 {
        get {
            return self.syncQ.sync { return self._countOfBytesReceived }
        }
        set {
            self.syncQ.sync { self._countOfBytesReceived = newValue }
            updateProgress()
        }
    }
    fileprivate var _countOfBytesReceived: Int64 = 0
    
    /// Number of body bytes already sent */
    open internal(set) var countOfBytesSent: Int64 {
        get {
            return self.syncQ.sync { return self._countOfBytesSent }
        }
        set {
            self.syncQ.sync { self._countOfBytesSent = newValue }
            updateProgress()
        }
    }
    
    fileprivate var _countOfBytesSent: Int64 = 0
    
    /// Number of body bytes we expect to send, derived from the Content-Length of the HTTP request */
    open internal(set) var countOfBytesExpectedToSend: Int64 = 0 {
        didSet { updateProgress() }
    }
    
    /// Number of bytes we expect to receive, usually derived from the Content-Length header of an HTTP response. */
    open internal(set) var countOfBytesExpectedToReceive: Int64 = 0 {
        didSet { updateProgress() }
    }
    
    /// The taskDescription property is available for the developer to
    /// provide a descriptive label for the task.
    open var taskDescription: String?
    
    /* -cancel returns immediately, but marks a task as being canceled.
     * The task will signal -URLSession:task:didCompleteWithError: with an
     * error value of { NSURLErrorDomain, NSURLErrorCancelled }.  In some
     * cases, the task may signal other work before it acknowledges the
     * cancellation.  -cancel may be sent to a task that has been suspended.
     */
    open func cancel() {
        workQueue.sync {
            let canceled = self.syncQ.sync { () -> Bool in
                guard self._state == .running || self._state == .suspended else { return true }
                self._state = .canceling
                return false
            }
            guard !canceled else { return }
            self._getProtocol { (urlProtocol) in
                self.workQueue.async {
                    var info = [NSLocalizedDescriptionKey: "\(URLError.Code.cancelled)" as Any]
                    if let url = self.originalRequest?.url {
                        info[NSURLErrorFailingURLErrorKey] = url
                        info[NSURLErrorFailingURLStringErrorKey] = url.absoluteString
                    }
                    let urlError = URLError(_nsError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: info))
                    self.error = urlError
                    if let urlProtocol = urlProtocol {
                        urlProtocol.stopLoading()
                        urlProtocol.client?.urlProtocol(urlProtocol, didFailWithError: urlError)
                    }
                }
            }
        }
    }
    
    /*
     * The current state of the task within the session.
     */
    open fileprivate(set) var state: URLSessionTask.State {
        get {
            return self.syncQ.sync { self._state }
        }
        set {
            self.syncQ.sync { self._state = newValue }
        }
    }
    fileprivate var _state: URLSessionTask.State = .suspended
    
    /*
     * The error, if any, delivered via -URLSession:task:didCompleteWithError:
     * This property will be nil in the event that no error occurred.
     */
    /*@NSCopying*/ open internal(set) var error: Error?
    
    /// Suspend the task.
    ///
    /// Suspending a task will prevent the URLSession from continuing to
    /// load data.  There may still be delegate calls made on behalf of
    /// this task (for instance, to report data received while suspending)
    /// but no further transmissions will be made on behalf of the task
    /// until -resume is sent.  The timeout timer associated with the task
    /// will be disabled while a task is suspended. -suspend and -resume are
    /// nestable.
    open func suspend() {
        // suspend / resume is implemented simply by adding / removing the task's
        // easy handle fromt he session's multi-handle.
        //
        // This might result in slightly different behaviour than the Darwin Foundation
        // implementation, but it'll be difficult to get complete parity anyhow.
        // Too many things depend on timeout on the wire etc.
        //
        // TODO: It may be worth looking into starting over a task that gets
        // resumed. The Darwin Foundation documentation states that that's what
        // it does for anything but download tasks.
        
        // We perform the increment and call to `updateTaskState()`
        // synchronous, to make sure the `state` is updated when this method
        // returns, but the actual suspend will be done asynchronous to avoid
        // dead-locks.
        workQueue.sync {
            guard self.state != .canceling && self.state != .completed else { return }
            self.suspendCount += 1
            guard self.suspendCount < Int.max else { fatalError("Task suspended too many times \(Int.max).") }
            self.updateTaskState()
            
            if self.suspendCount == 1 {
                self._getProtocol { (urlProtocol) in
                    self.workQueue.async {
                        urlProtocol?.stopLoading()
                    }
                }
            }
        }
    }
    
    // 最重要的一个方法.
    // 注意, 作用域的限制.
    open func resume() {
        workQueue.sync {
            // 防卫式限制.
            guard self.state != .canceling && self.state != .completed else { return }
            if self.suspendCount > 0 { self.suspendCount -= 1 }
            self.updateTaskState()
            
            // 真正的 loading 的启动过程.
            if self.suspendCount == 0 {
                self.hasTriggeredResume = true
                // 获取到了 dataTask 的 protocol, 然后配置.
                self._getProtocol { (urlProtocol) in
                    self.workQueue.async {
                        if let _protocol = urlProtocol {
                            _protocol.startLoading() // 启动 protocol. 具体, 怎么 start, 各个 protocol 子类的责任.
                        } else if self.error == nil { // 没拿到, 也就是 request 不能被识别. 组织 error 信息.
                            var userInfo: [String: Any] = [NSLocalizedDescriptionKey: "unsupported URL"]
                            if let url = self.originalRequest?.url {
                                userInfo[NSURLErrorFailingURLErrorKey] = url
                                userInfo[NSURLErrorFailingURLStringErrorKey] = url.absoluteString
                            }
                            let urlError = URLError(_nsError: NSError(domain: NSURLErrorDomain,
                                                                      code: NSURLErrorUnsupportedURL,
                                                                      userInfo: userInfo))
                            self.error = urlError
                            _ProtocolClient().urlProtocol(task: self, didFailWithError: urlError)
                        }
                    }
                }
            }
        }
    }
    
    /// The priority of the task.
    ///
    /// Sets a scaling factor for the priority of the task. The scaling factor is a
    /// value between 0.0 and 1.0 (inclusive), where 0.0 is considered the lowest
    /// priority and 1.0 is considered the highest.
    ///
    /// The priority is a hint and not a hard requirement of task performance. The
    /// priority of a task may be changed using this API at any time, but not all
    /// protocols support this; in these cases, the last priority that took effect
    /// will be used.
    ///
    /// If no priority is specified, the task will operate with the default priority
    /// as defined by the constant URLSessionTask.defaultPriority. Two additional
    /// priority levels are provided: URLSessionTask.lowPriority and
    /// URLSessionTask.highPriority, but use is not restricted to these.
    open var priority: Float {
        get {
            return self.workQueue.sync { return self._priority }
        }
        set {
            self.workQueue.sync { self._priority = newValue }
        }
    }
    fileprivate var _priority: Float = URLSessionTask.defaultPriority
}




extension URLSessionTask {
    public enum State : Int {
        /// The task is currently being serviced by the session
        case running
        case suspended
        /// The task has been told to cancel.  The session will receive a URLSession:task:didCompleteWithError: message.
        case canceling
        /// The task has completed and the session will receive no more delegate notifications
        case completed
    }
}

extension URLSessionTask : ProgressReporting {}

extension URLSessionTask {
    /// Updates the (public) state based on private / internal state.
    ///
    /// - Note: This must be called on the `workQueue`.
    internal func updateTaskState() {
        // 不太明白啊, 这种, 先定义后调用, 有个屁用.
        func calculateState() -> URLSessionTask.State {
            if suspendCount == 0 {
                return .running
            } else {
                return .suspended
            }
        }
        state = calculateState()
    }
}

internal extension URLSessionTask {
    enum _Body {
        case none
        case data(DispatchData)
        case file(URL)
        case stream(InputStream)
    }
}

internal extension URLSessionTask._Body {
    enum _Error : Error {
        case fileForBodyDataNotFound
    }
    /// - Returns: The body length, or `nil` for no body (e.g. `GET` request).
    func getBodyLength() throws -> UInt64? {
        switch self {
        case .none:
            return 0
        case .data(let d):
            return UInt64(d.count)
        /// Body data is read from the given file URL
        case .file(let fileURL):
            guard let s = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber else {
                throw _Error.fileForBodyDataNotFound
            }
            return s.uint64Value
        case .stream:
            return nil
        }
    }
}


fileprivate func errorCode(fileSystemError error: Error) -> Int {
    func fromCocoaErrorCode(_ code: Int) -> Int {
        switch code {
        case CocoaError.fileReadNoSuchFile.rawValue:
            return NSURLErrorFileDoesNotExist
        case CocoaError.fileReadNoPermission.rawValue:
            return NSURLErrorNoPermissionsToReadFile
        default:
            return NSURLErrorUnknown
        }
    }
    switch error {
    case let e as NSError where e.domain == NSCocoaErrorDomain:
        return fromCocoaErrorCode(e.code)
    default:
        return NSURLErrorUnknown
    }
}

extension URLSessionTask {
    /// The default URL session task priority, used implicitly for any task you
    /// have not prioritized. The floating point value of this constant is 0.5.
    public static let defaultPriority: Float = 0.5
    
    /// A low URL session task priority, with a floating point value above the
    /// minimum of 0 and below the default value.
    public static let lowPriority: Float = 0.25
    
    /// A high URL session task priority, with a floating point value above the
    /// default value and below the maximum of 1.0.
    public static let highPriority: Float = 0.75
}

/*
 * An URLSessionDataTask does not provide any additional
 * functionality over an URLSessionTask and its presence is merely
 * to provide lexical differentiation from download and upload tasks.
 */
// 所有的功能, 在 URLSessionTask 已经实现了.
open class URLSessionDataTask : URLSessionTask {
}

/*
 * An URLSessionUploadTask does not currently provide any additional
 * functionality over an URLSessionDataTask.  All delegate messages
 * that may be sent referencing an URLSessionDataTask equally apply
 * to URLSessionUploadTasks.
 */
open class URLSessionUploadTask : URLSessionDataTask {
}

/*
 * URLSessionDownloadTask is a task that represents a download to
 * local storage.
 */
open class URLSessionDownloadTask : URLSessionTask {
    
    var createdFromInvalidResumeData = false
    
    // If a task is created from invalid resume data, prevent attempting creation of the protocol object.
    override func _getProtocol(_ callback: @escaping (URLProtocol?) -> Void) {
        if createdFromInvalidResumeData {
            callback(nil)
        } else {
            super._getProtocol(callback)
        }
    }
    
    internal var fileLength = -1.0
    
    /* Cancel the download (and calls the superclass -cancel).  If
     * conditions will allow for resuming the download in the future, the
     * callback will be called with an opaque data blob, which may be used
     * with -downloadTaskWithResumeData: to attempt to resume the download.
     * If resume data cannot be created, the completion handler will be
     * called with nil resumeData.
     */
    open func cancel(byProducingResumeData completionHandler: @escaping (Data?) -> Void) {
        super.cancel()
        
        /*
         * In Objective-C, this method relies on an Apple-maintained XPC process
         * to manage the bookmarking of partially downloaded data. Therefore, the
         * original behavior cannot be directly ported, here.
         *
         * Instead, we just call the completionHandler directly.
         */
        completionHandler(nil)
    }
}

/*
 * An URLSessionStreamTask provides an interface to perform reads
 * and writes to a TCP/IP stream created via URLSession.  This task
 * may be explicitly created from an URLSession, or created as a
 * result of the appropriate disposition response to a
 * -URLSession:dataTask:didReceiveResponse: delegate message.
 *
 * URLSessionStreamTask can be used to perform asynchronous reads
 * and writes.  Reads and writes are enquened and executed serially,
 * with the completion handler being invoked on the sessions delegate
 * queuee.  If an error occurs, or the task is canceled, all
 * outstanding read and write calls will have their completion
 * handlers invoked with an appropriate error.
 *
 * It is also possible to create InputStream and OutputStream
 * instances from an URLSessionTask by sending
 * -captureStreams to the task.  All outstanding read and writess are
 * completed before the streams are created.  Once the streams are
 * delivered to the session delegate, the task is considered complete
 * and will receive no more messages.  These streams are
 * disassociated from the underlying session.
 */

@available(*, deprecated, message: "URLSessionStreamTask is not available in swift-corelibs-foundation")
open class URLSessionStreamTask : URLSessionTask {
    
    /* Read minBytes, or at most maxBytes bytes and invoke the completion
     * handler on the sessions delegate queue with the data or an error.
     * If an error occurs, any outstanding reads will also fail, and new
     * read requests will error out immediately.
     */
    @available(*, unavailable, message: "URLSessionStreamTask is not available in swift-corelibs-foundation")
    open func readData(ofMinLength minBytes: Int, maxLength maxBytes: Int, timeout: TimeInterval, completionHandler: @escaping (Data?, Bool, Error?) -> Void) { NSUnsupported() }
    
    /* Write the data completely to the underlying socket.  If all the
     * bytes have not been written by the timeout, a timeout error will
     * occur.  Note that invocation of the completion handler does not
     * guarantee that the remote side has received all the bytes, only
     * that they have been written to the kernel. */
    @available(*, unavailable, message: "URLSessionStreamTask is not available in swift-corelibs-foundation")
    open func write(_ data: Data, timeout: TimeInterval, completionHandler: @escaping (Error?) -> Void) { NSUnsupported() }
    
    /* -captureStreams completes any already enqueued reads
     * and writes, and then invokes the
     * URLSession:streamTask:didBecomeInputStream:outputStream: delegate
     * message. When that message is received, the task object is
     * considered completed and will not receive any more delegate
     * messages. */
    @available(*, unavailable, message: "URLSessionStreamTask is not available in swift-corelibs-foundation")
    open func captureStreams() { NSUnsupported() }
    
    /* Enqueue a request to close the write end of the underlying socket.
     * All outstanding IO will complete before the write side of the
     * socket is closed.  The server, however, may continue to write bytes
     * back to the client, so best practice is to continue reading from
     * the server until you receive EOF.
     */
    @available(*, unavailable, message: "URLSessionStreamTask is not available in swift-corelibs-foundation")
    open func closeWrite() { NSUnsupported() }
    
    /* Enqueue a request to close the read side of the underlying socket.
     * All outstanding IO will complete before the read side is closed.
     * You may continue writing to the server.
     */
    @available(*, unavailable, message: "URLSessionStreamTask is not available in swift-corelibs-foundation")
    open func closeRead() { NSUnsupported() }
    
    /*
     * Begin encrypted handshake.  The handshake begins after all pending
     * IO has completed.  TLS authentication callbacks are sent to the
     * session's -URLSession:task:didReceiveChallenge:completionHandler:
     */
    @available(*, unavailable, message: "URLSessionStreamTask is not available in swift-corelibs-foundation")
    open func startSecureConnection() { NSUnsupported() }
    
    /*
     * Cleanly close a secure connection after all pending secure IO has
     * completed.
     */
    @available(*, unavailable, message: "URLSessionStreamTask is not available in swift-corelibs-foundation")
    open func stopSecureConnection() { NSUnsupported() }
}

/* Key in the userInfo dictionary of an NSError received during a failed download. */
public let URLSessionDownloadTaskResumeData: String = "NSURLSessionDownloadTaskResumeData"

// 这个扩展, 还是定义在了 task 里面. 可以看做是, task 里面实现了 protocolClient 的协议.
extension _ProtocolClient : URLProtocolClient {
    
    // 这, 真的是一个非常不好的设计, protocol 里面, 藏了一个 task.
    // policy 应该主要来源于 request 的设置.
    func urlProtocol(_ protocol: URLProtocol,
                     didReceive response: URLResponse,policy
                        cacheStoragePolicy : URLCache.StoragePolicy) {
        guard let task = `protocol`.task else { fatalError("Received response, but there's no task.") }
        // Response, 是相应元数据的解析结果. 指导着, 如何对 data 进行解析.
        task.response = response
        // 这里这么转换, 是因为 task 里面存的是一个协议对象. 完全是, 没有必要. 徒增复杂度.
        let session = task.session as! URLSession
        guard let dataTask = task as? URLSessionDataTask else { return } // ???
        
        // Only cache data tasks:
        self.cachePolicy = policy
        
        if session.configuration.urlCache != nil {
            switch policy {
            case .allowed: fallthrough
            case .allowedInMemoryOnly:
                cacheableData = [] // 这里, 不写 self 导致不清楚这两变量的来源. 该写还是要写.
                cacheableResponse = response
            case .notAllowed:
                break
            }
        }
        
        // 如果, 是调用代理, 那么就像 session 的 delegateQueue 里面, 增加一个调用代理的任务.
        switch session.behaviour(for: task) {
        case .taskDelegate(let delegate as URLSessionDataDelegate):
            session.delegateQueue.addOperation {
                // 在这里, 是实际的代理方法的调用.
                delegate.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: nil)
            }
        // 其他情况, 不管, 最后在使用.
        case .noDelegate, .taskDelegate, .dataCompletionHandler, .downloadCompletionHandler:
            break
        }
    }
    
    // Protocol 顺利完成 loading 的回调.
    func urlProtocolDidFinishLoading(_ urlProtocol: URLProtocol) {
        guard let task = urlProtocol.task else { fatalError() }
        guard let session = task.session as? URLSession else { fatalError() }
        let urlResponse = task.response
        
        // 需要认证.
        if let response = urlResponse as? HTTPURLResponse,
           response.statusCode == 401 {
            
            // 根据相应里面的内容, 建立 protectSpace
            if let protectionSpace = URLProtectionSpace.create(with: response) {
                func proceed(proposing credential: URLCredential?) {
                    let proposedCredential: URLCredential?
                    let last = task._protocolLock.performLocked { task._lastCredentialUsedFromStorageDuringAuthentication }
                    
                    if last?.credential != credential {
                        proposedCredential = credential
                    } else {
                        proposedCredential = nil
                    }
                    
                    let authenticationChallenge = URLAuthenticationChallenge(protectionSpace: protectionSpace, proposedCredential: proposedCredential,
                                                                             previousFailureCount: task.previousFailureCount, failureResponse: response, error: nil,
                                                                             sender: URLSessionAuthenticationChallengeSender())
                    task.previousFailureCount += 1
                    self.urlProtocol(urlProtocol, didReceive: authenticationChallenge)
                }
                
                if let storage = session.configuration.urlCredentialStorage {
                    storage.getCredentials(for: protectionSpace, task: task) { (credentials) in
                        if let credentials = credentials,
                           let firstKeyLexicographically = credentials.keys.sorted().first {
                            proceed(proposing: credentials[firstKeyLexicographically])
                        } else {
                            storage.getDefaultCredential(for: protectionSpace, task: task) { (credential) in
                                proceed(proposing: credential)
                            }
                        }
                    }
                } else {
                    proceed(proposing: nil)
                }
                
                return
            }
        }
        
        // 这里, 存储了一下证书.
        if let storage = session.configuration.urlCredentialStorage,
           let last = task._protocolLock.performLocked({ task._lastCredentialUsedFromStorageDuringAuthentication }) {
            storage.set(last.credential, for: last.protectionSpace, task: task)
        }
        
        // 这里, 存储了一下响应.
        // 在 Gnu 里面, 是在 protocol 层面, 就做了这件事.
        if let cache = session.configuration.urlCache,
           let data = cacheableData,
           let response = cacheableResponse,
           let task = task as? URLSessionDataTask {
            
            let cacheable = CachedURLResponse(response: response, data: Data(data.joined()), storagePolicy: cachePolicy)
            let protocolAllows = (urlProtocol as? _NativeProtocol)?.canCache(cacheable) ?? false
            if protocolAllows {
                if let delegate = task.session.delegate as? URLSessionDataDelegate {
                    delegate.urlSession(task.session as! URLSession, dataTask: task, willCacheResponse: cacheable) { (actualCacheable) in
                        if let actualCacheable = actualCacheable {
                            cache.storeCachedResponse(actualCacheable, for: task)
                        }
                    }
                } else {
                    cache.storeCachedResponse(cacheable, for: task)
                }
            }
        }
        
        // 根据 task 的不同的回调行为, 调用不同的回调.
        switch session.behaviour(for: task) {
        case .taskDelegate(let delegate):
            if let downloadDelegate = delegate as? URLSessionDownloadDelegate,
               let downloadTask = task as? URLSessionDownloadTask {
                session.delegateQueue.addOperation {
                    downloadDelegate.urlSession(session, downloadTask: downloadTask, didFinishDownloadingTo: urlProtocol.properties[URLProtocol._PropertyKey.temporaryFileURL] as! URL)
                }
            }
            session.delegateQueue.addOperation {
                guard task.state != .completed else { return }
                delegate.urlSession(session, task: task, didCompleteWithError: nil)
                task.state = .completed
                session.workQueue.async {
                    session.taskRegistry.remove(task)
                }
            }
        case .noDelegate:
            guard task.state != .completed else { break }
            task.state = .completed
            session.workQueue.async {
                session.taskRegistry.remove(task)
            }
        case .dataCompletionHandler(let completion):
            session.delegateQueue.addOperation {
                guard task.state != .completed else { return }
                completion(urlProtocol.properties[URLProtocol._PropertyKey.responseData] as? Data ?? Data(), task.response, nil)
                task.state = .completed
                session.workQueue.async {
                    session.taskRegistry.remove(task)
                }
            }
        case .downloadCompletionHandler(let completion):
            session.delegateQueue.addOperation {
                guard task.state != .completed else { return }
                completion(urlProtocol.properties[URLProtocol._PropertyKey.temporaryFileURL] as? URL, task.response, nil)
                task.state = .completed
                session.workQueue.async {
                    session.taskRegistry.remove(task)
                }
            }
        }
        task._invalidateProtocol()
    }
    
    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge) {
        guard let task = `protocol`.task else { fatalError() }
        urlProtocol(task: task, didFailWithError: NSError(domain: NSCocoaErrorDomain, code: CocoaError.userCancelled.rawValue))
    }
    
    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge) {
        guard let task = `protocol`.task else { fatalError("Received response, but there's no task.") }
        guard let session = task.session as? URLSession else { fatalError("Task not associated with URLSession.") }
        
        // 使用证书
        func proceed(using credential: URLCredential?) {
            let protectionSpace = challenge.protectionSpace
            let authScheme = protectionSpace.authenticationMethod
            
            task.suspend()
            
            guard let handler = URLSessionTask.authHandler(for: authScheme) else {
                fatalError("\(authScheme) is not supported")
            }
            handler(task, .useCredential, credential)
            
            task._protocolLock.performLocked {
                if let credential = credential {
                    task._lastCredentialUsedFromStorageDuringAuthentication = (protectionSpace: protectionSpace, credential: credential)
                } else {
                    task._lastCredentialUsedFromStorageDuringAuthentication = nil
                }
                task._protocolStorage = .existing(_HTTPURLProtocol(task: task, cachedResponse: nil, client: nil))
            }
            
            task.resume()
            
            // suspend, resume 都有着 protocol 的 stop 和 start.
            // 网络 loading, 是不能停止的, 停止的, 但是过程可以停止.
            // 网络请求的时候, 可能重定向, 可以要求证书, 各种操作, 所以, 一次请求, 可能要建立很多次链接.
            // Task 的暂停和回复, 是在这很多次的连接基础上, 而不是一次链接能够等待, 恢复
        }
        
        func attemptProceedingWithDefaultCredential() {
            if let credential = challenge.proposedCredential {
                // 用上一次存的证书试一次.
                let last = task._protocolLock.performLocked { task._lastCredentialUsedFromStorageDuringAuthentication }
                if last?.credential != credential {
                    proceed(using: credential)
                } else {
                    task.cancel() //找不到证书, 取消任务.
                }
            }
        }
        
        if let delegate = session.delegate as? URLSessionTaskDelegate {
            session.delegateQueue.addOperation {
                // 在这里代理里面, 用户会确定, 如何处置证书 disposition, 以及证书, 这个证书可能是用户自己提供的.
                delegate.urlSession(session, task: task, didReceive: challenge) { disposition, credential in
                    
                    switch disposition {
                    case .useCredential: // 使用证书,
                        proceed(using: credential!)
                        
                    case .performDefaultHandling:
                        attemptProceedingWithDefaultCredential()
                        
                    case .rejectProtectionSpace:
                        fallthrough
                    case .cancelAuthenticationChallenge:
                        task.cancel() // 取消任务.
                    }
                    
                }
            }
        } else {
            attemptProceedingWithDefaultCredential()
        }
    }
    
    // 在 protocol 里面, 获取到了数据, 抛给了上层.
    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data) {
        `protocol`.properties[.responseData] = data
        guard let task = `protocol`.task else { fatalError() }
        guard let session = task.session as? URLSession else { fatalError() }
        
        switch cachePolicy {
        case .allowed: fallthrough
        case .allowedInMemoryOnly:
            cacheableData?.append(data)
            
        case .notAllowed:
            break
        }
        
        switch session.behaviour(for: task) {
        case .taskDelegate(let delegate):
            let dataDelegate = delegate as? URLSessionDataDelegate
            let dataTask = task as? URLSessionDataTask
            session.delegateQueue.addOperation {
                // 在这里, 想 dataTask 的 delegate 传输数据了.
                // didReceivedata
                dataDelegate?.urlSession(session, dataTask: dataTask!, didReceive: data)
            }
        default: return
        }
    }
    
    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: Error) {
        guard let task = `protocol`.task else { fatalError() }
        urlProtocol(task: task, didFailWithError: error)
    }
    
    // 任务失败的回调.
    func urlProtocol(task: URLSessionTask, didFailWithError error: Error) {
        guard let session = task.session as? URLSession else { fatalError() }
        switch session.behaviour(for: task) {
        case .taskDelegate(let delegate):
            session.delegateQueue.addOperation {
                guard task.state != .completed else { return }
                delegate.urlSession(session, task: task, didCompleteWithError: error as Error)
                task.state = .completed
                session.workQueue.async {
                    session.taskRegistry.remove(task)
                }
            }
        case .noDelegate:
            guard task.state != .completed else { break }
            task.state = .completed
            session.workQueue.async {
                session.taskRegistry.remove(task)
            }
        case .dataCompletionHandler(let completion):
            session.delegateQueue.addOperation {
                guard task.state != .completed else { return }
                completion(nil, nil, error)
                task.state = .completed
                session.workQueue.async {
                    session.taskRegistry.remove(task)
                }
            }
        case .downloadCompletionHandler(let completion):
            session.delegateQueue.addOperation {
                guard task.state != .completed else { return }
                completion(nil, nil, error)
                task.state = .completed
                session.workQueue.async {
                    session.taskRegistry.remove(task)
                }
            }
        }
        task._invalidateProtocol()
    }
    
    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse) {}
    
    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse) {
        fatalError("The URLSession swift-corelibs-foundation implementation doesn't currently handle redirects directly.")
    }
}

extension URLSessionTask {
    typealias _AuthHandler = ((URLSessionTask, URLSession.AuthChallengeDisposition, URLCredential?) -> ())
    
    static func authHandler(for authScheme: String) -> _AuthHandler? {
        let handlers: [String : _AuthHandler] = [
            NSURLAuthenticationMethodHTTPBasic : basicAuth,
            NSURLAuthenticationMethodHTTPDigest: digestAuth
        ]
        return handlers[authScheme]
    }
    
    // 这是两个静态方法.
    
    static func basicAuth(_ task: URLSessionTask,
                          _ disposition: URLSession.AuthChallengeDisposition,
                          _ credential: URLCredential?) {
        //TODO: Handle disposition. For now, we default to .useCredential
        let user = credential?.user ?? ""
        let password = credential?.password ?? ""
        let encodedString = "\(user):\(password)".data(using: .utf8)?.base64EncodedString()
        task.authRequest = task.originalRequest
        task.authRequest?.setValue("Basic \(encodedString!)", forHTTPHeaderField: "Authorization")
    }
    
    static func digestAuth(_ task: URLSessionTask,
                           _ disposition: URLSession.AuthChallengeDisposition,
                           _ credential: URLCredential?) {
        fatalError("The URLSession swift-corelibs-foundation implementation doesn't currently handle digest authentication.")
    }
}

extension URLProtocol {
    enum _PropertyKey: String {
        case responseData
        case temporaryFileURL
    }
}
