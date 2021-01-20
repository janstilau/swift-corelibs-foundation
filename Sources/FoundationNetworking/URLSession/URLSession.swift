/*
 
 代理, 是一个类对外交互的接口.
 session 对外暴露的接口, 就是被包装成了好几个 delegate 协议.
 
 An URLSession may be bound to a delegate object.  The delegate is
 invoked for certain events during the lifetime of a session, such as
 server authentication or determining whether a resource to be loaded
 should be converted into a download.
 
 URLSession instances are threadsafe.
 
 // URLSessionTask 作为了一次请求加载过程的抽象.
 // 之前是 NSURLConnection, 所以, NSURLConnection 对标的是 URLSessionTask
 // Session 更多的是整个网络请求的管理者, 而不是一个.
 An URLSession creates URLSessionTask objects which represent the
 action of a resource being loaded.  These are analogous to
 NSURLConnection objects but provide for more control and a unified
 delegate model.
 
 // URLSessionTask 仅仅是一个数据创建的过程, 真正的启动网络, 要 resume, 先准备数据, 然后在启动.
 URLSessionTask objects are always created in a suspended state and
 must be sent the -resume message before they will execute.
 
 URLSessionTask 有几个子类, 分别将, 上传, 下载, 内存 data 拼接的逻辑, 移交到了不同的对象里面.
 
 // 内存里面存 data
 An URLSessionDataTask receives the resource as a series of calls to
 the URLSession:dataTask:didReceiveData: delegate method.  This is type of
 task most commonly associated with retrieving objects for immediate parsing
 by the consumer.

 // 上传大量数据的时候, 应该使用 upload 模型.
 An URLSessionUploadTask differs from an URLSessionDataTask
 in how its instance is constructed.  Upload tasks are explicitly created
 by referencing a file or data object to upload, or by utilizing the
 -URLSession:task:needNewBodyStream: delegate message to supply an upload
 body.
 
 // 下载大量数据的时候, 存到文件里面.
 An URLSessionDownloadTask will directly write the response data to
 a temporary file.  When completed, the delegate is sent
 URLSession:downloadTask:didFinishDownloadingToURL: and given an opportunity
 to move this file to a permanent location in its sandboxed container, or to
 otherwise read the file. If canceled, an URLSessionDownloadTask can
 produce a data blob that can be used to resume a download at a later
 time.
 */

/* DataTask objects receive the payload through zero or more delegate messages */
/* UploadTask objects receive periodic progress updates but do not return a body */
/* DownloadTask objects represent an active download to disk.  They can provide resume data when canceled. */
/* StreamTask objects may be used to create NSInput and OutputStreams, or used directly in reading and writing. */


// -----------------------------------------------------------------------------
/// # URLSession API implementation overview
///
/// ## Design Overview
///
/// This implementation uses libcurl for the HTTP layer implementation. At a
/// high level, the `URLSession` keeps a *multi handle*, and each
/// `URLSessionTask` has an *easy handle*. This way these two APIs somewhat
/// have a 1-to-1 mapping.
///
/// The `URLSessionTask` class is in charge of configuring its *easy handle*
/// and adding it to the owning session’s *multi handle*. Adding / removing
/// the handle effectively resumes / suspends the transfer.
///
/// URLSessionTask 的可以隐藏 download, upload, data slice 的逻辑.
/// The `URLSessionTask` class has subclasses, but this design puts all the
/// logic into the parent `URLSessionTask`.
///
/// 有着很好的类的设计, 使用了很多的内部类, 进行责任的划分.
/// Both the `URLSession` and `URLSessionTask` extensively use helper
/// types to ease testability, separate responsibilities, and improve
/// readability. These types are nested inside the `URLSession` and
/// `URLSessionTask` to limit their scope. Some of these even have sub-types.
///
/// TaskRegistry 作为各个事件回调的追踪.
/// The session class uses the `URLSession.TaskRegistry` to keep track of its
/// tasks.
///
/// The task class uses an `InternalState` type together with `TransferState` to
/// keep track of its state and each transfer’s state -- note that a single task
/// may do multiple transfers, e.g. as the result of a redirect.
///
/// ## Error Handling
///
/// Most libcurl functions either return a `CURLcode` or `CURLMcode` which
/// are represented in Swift as `CFURLSessionEasyCode` and
/// `CFURLSessionMultiCode` respectively. We turn these functions into throwing
/// functions by appending `.asError()` onto their calls. This turns the error
/// code into `Void` but throws the error if it's not `.OK` / zero.
///
/// This is combined with `try!` is almost all places, because such an error
/// indicates a programming error. Hence the pattern used in this code is
///
/// ```
/// try! someFunction().asError()
/// ```
///
/// where `someFunction()` is a function that returns a `CFURLSessionEasyCode`.
///
/// ## Threading
///
/// The URLSession has a libdispatch ‘work queue’, and all internal work is
/// done on that queue, such that the code doesn't have to deal with thread
/// safety beyond that. All work inside a `URLSessionTask` will run on this
/// work queue, and so will code manipulating the session's *multi handle*.
///
/// Delegate callbacks are, however, done on the passed in
/// `delegateQueue`. And any calls into this API need to switch onto the ‘work
/// queue’ as needed.
///
/// - SeeAlso: https://curl.haxx.se/libcurl/c/threadsafe.html
/// - SeeAlso: URLSession+libcurl.swift
///
/// ## HTTP and RFC 2616
///
/// Most of HTTP is defined in [RFC 2616](https://tools.ietf.org/html/rfc2616).
/// While libcurl handles many of these details, some are handled by this
/// URLSession implementation.
///
/// ## To Do
///
/// - TODO: Is is not clear if using API that takes a URLRequest will override
/// all settings of the URLSessionConfiguration or just those that have not
/// explicitly been set.
/// E.g. creating an URLRequest will cause it to have the default timeoutInterval
/// of 60 seconds, but should this be used in stead of the configuration's
/// timeoutIntervalForRequest even if the request's timeoutInterval has not
/// been set explicitly?
///
/// - TODO: We could re-use EasyHandles once they're complete. That'd be a
/// performance optimization. Not sure how much that'd help. The URLSession
/// would have to keep a pool of unused handles.
///
/// - TODO: Could make `workQueue` concurrent and use a multiple reader / single
/// writer approach if it turns out that there's contention.
// -----------------------------------------------------------------------------


#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import SwiftFoundation
#else
import Foundation
#endif
@_implementationOnly import CoreFoundation

extension URLSession {
    public enum DelayedRequestDisposition {
        case cancel
        case continueLoading
        case useNewRequest
    }
}



// Swift 大量使用了, 闭包确定返回值的技术. Void 能够被返回的好处.
// 其实, 返回值, 在汇编层面上, 无非就是个存值取值的过程. 这是语言层面的设置.
// 这种, 使用一个全局静态 Int 获取 Id 的方式, 是通用的.
fileprivate let globalVarSyncQ = DispatchQueue(label: "org.swift.Foundation.URLSession.GlobalVarSyncQ")
fileprivate var sessionCounter = Int32(0)
fileprivate func nextSessionIdentifier() -> Int32 {
    return globalVarSyncQ.sync {
        sessionCounter += 1
        return sessionCounter
    }
}

public let NSURLSessionTransferSizeUnknown: Int64 = -1

open class URLSession : NSObject {
    internal let _configuration: _Configuration
    fileprivate let multiHandle: _MultiHandle
    fileprivate var nextTaskIdentifier = 1 // 就是一个 id 生成号.
    internal let workQueue: DispatchQueue 
    internal let taskRegistry = URLSession._TaskRegistry() // 任务管理器. 里面存储了所有的 dataTask.
    fileprivate let identifier: Int32
    fileprivate var invalidated = false // 仅仅是一个 bool 值而已.
    fileprivate static let registerProtocols: () = {
        // TODO: We register all the native protocols here.
        _ = URLProtocol.registerClass(_HTTPURLProtocol.self)
        _ = URLProtocol.registerClass(_FTPURLProtocol.self)
        _ = URLProtocol.registerClass(_DataURLProtocol.self)
    }()
    
    /*
     * The shared session uses the currently set global URLCache,
     * HTTPCookieStorage and URLCredential.Storage objects.
     */
    open class var shared: URLSession {
        return _shared
    }

    fileprivate static let _shared: URLSession = {
        var configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.protocolClasses = URLProtocol.getProtocols()
        // 使用, default 的 配置, share 的 cookie 存储, URLProtocol 配置的 protocols, 创建一个 Session.
        return URLSession(configuration: configuration, delegate: nil, delegateQueue: nil)
    }()

    // 这里, delegate 会被 retain.
    // 然后在 sesion invaliad 的时候, 会释放.
    public init(configuration: URLSessionConfiguration) {
        initializeLibcurl()
        identifier = nextSessionIdentifier()
        self.workQueue = DispatchQueue(label: "URLSession<\(identifier)>")
        // delegate, 是在一个串行 queue 里面的, 因为网络的数据, 需要有序.
        // 不然, data 过来了之后, 3 号 data 就可能跑到 1, 2 号的前面了.
        self.delegateQueue = OperationQueue()
        self.delegateQueue.maxConcurrentOperationCount = 1
        self.delegate = nil
        // copy, 去切割原有的联系, 不过这里, 还是使用 configuration, 生成了一个不可变的 _configuration.
        self.configuration = configuration.copy() as! URLSessionConfiguration
        let c = URLSession._Configuration(URLSessionConfiguration: configuration)
        self._configuration = c
        self.multiHandle = _MultiHandle(configuration: c, workQueue: workQueue)
        // registering all the protocol classes with URLProtocol
        let _ = URLSession.registerProtocols
    }

    /*
     * A delegate queue should be serial to ensure correct ordering of callbacks.
     * However, if user supplies a concurrent delegateQueue it is not converted to serial.
     */
    public /*not inherited*/ init(configuration: URLSessionConfiguration, delegate: URLSessionDelegate?, delegateQueue queue: OperationQueue?) {
        initializeLibcurl()
        identifier = nextSessionIdentifier()
        // DispatchQueue, 创建出来, 是一个串行队列.
        self.workQueue = DispatchQueue(label: "URLSession<\(identifier)>")
        if let _queue = queue {
            // 没有对用户的进行检查, 如果是并行队列, 可能会有问题.
           self.delegateQueue = _queue
        } else {
           self.delegateQueue = OperationQueue()
           self.delegateQueue.maxConcurrentOperationCount = 1
        }
        self.delegate = delegate
        self.configuration = configuration.copy() as! URLSessionConfiguration
        let c = URLSession._Configuration(URLSessionConfiguration: configuration)
        self._configuration = c
        self.multiHandle = _MultiHandle(configuration: c, workQueue: workQueue)
        let _ = URLSession.registerProtocols
    }
    
    // 没有把所有的数据部分, 写到一起. 现在不太清楚, swift 里面, 位置的规定有没有什么原则.
    open private(set) var delegateQueue: OperationQueue // 代理方法所在的位置.
    open private(set) var delegate: URLSessionDelegate? // 代理.
    open private(set) var configuration: URLSessionConfiguration
    
    // 就是调试用的, 需要开发者主动去设置.
    open var sessionDescription: String?
    
    /* -finishTasksAndInvalidate returns immediately and existing tasks will be allowed
     * to run to completion.  New tasks may not be created.  The session
     * will continue to make delegate callbacks until URLSession:didBecomeInvalidWithError:
     * has been issued.
     *
     * When invalidating a background session, it is not safe to create another background
     * session with the same identifier until URLSession:didBecomeInvalidWithError: has
     * been issued.
     */
    open func finishTasksAndInvalidate() {
       // 把任务交给队列, 不等待任务执行完毕.
       workQueue.async {
        // 当 invalidated 为 true 的时候, 任何 dataTask 的创建, 都会报错.
           self.invalidated = true
           let invalidateSessionCallback = { [weak self] in
               //invoke the delegate method and break the delegate link
            // 官方的代码, 也经常使用 strongSelf.
            // 如果没有代理, 那么后面的操作就不用做了.
            // 就是通知代理对象, session 结束了. 然后主动释放掉代理对象.
               guard let strongSelf = self, let sessionDelegate = strongSelf.delegate else { return }
            // 在 代理的队列里面添加任务.
            // 由于 iOS 大量使用了队列, 线程控制, 更加像是队列控制.
            // 如果自己模拟的话, 应该就是线程, 不断的取队列的任务执行. 这个应该在 libDispatch 里面
               strongSelf.delegateQueue.addOperation {
                   sessionDelegate.urlSession(strongSelf, didBecomeInvalidWithError: nil)
                   strongSelf.delegate = nil
               }
           }

        // taskRegistry 是dataTask 的存储器, 如果里面有值, 就等.
        // 这里是吧闭包, 注册给 taskRegistry 的 finish 闭包.
        // taskRegistry 有责任去调用.
           if !self.taskRegistry.isEmpty {
               self.taskRegistry.notify(on: invalidateSessionCallback)
            // tasksFinishedCallback = tasksCompletion
           } else {
               invalidateSessionCallback()
           }
       }
    }
    // 在 Swift 的源码里面, self 也还是大量使用的.
    /* -invalidateAndCancel acts as -finishTasksAndInvalidate, but issues
     * -cancel to all outstanding tasks for this session.  Note task
     * cancellation is subject to the state of the task, and some tasks may
     * have already have completed at the time they are sent -cancel.
     */
    open func invalidateAndCancel() {
        // 首先, 公用的不让瞎改.
        guard self !== URLSession.shared else { return }
        
        // 本类的状态, 统一都在串行队列里面改.
        // 不过, dataTask 的创建没有在里面啊. 仅仅是注册给 taskRegistry 的时候在了.
        workQueue.sync {
            self.invalidated = true
        }
        // 所有 task, 调用 cancel 方法.
        for task in taskRegistry.allTasks {
            task.cancel()
        }
        
        // Don't allow creation of new tasks from this point onwards
        // 直接告诉代理, session 结束了, 切断 delegate 的联系.
        workQueue.async {
            guard let sessionDelegate = self.delegate else { return }
            self.delegateQueue.addOperation {
                sessionDelegate.urlSession(self, didBecomeInvalidWithError: nil)
                self.delegate = nil
            }
        }
    }
    
    /* empty all cookies, cache and credential stores, removes disk files, issues -flushWithCompletionHandler:. Invokes completionHandler() on the delegate queue. */
    open func reset(completionHandler: @escaping () -> Void) {
        let configuration = self.configuration
        
        // 在低优先级的线程, 做这个事情. 异步调用
        DispatchQueue.global(qos: .background).async {
            // 显示 url cache 的清空.
            configuration.urlCache?.removeAllCachedResponses()
            // 然后是 证书的清空.
            // 没有 cookie ????
            if let storage = configuration.urlCredentialStorage {
                for credentialEntry in storage.allCredentials {
                    for credential in credentialEntry.value {
                        storage.remove(credential.value, for: credentialEntry.key)
                    }
                }
            }
            
            self.flush(completionHandler: completionHandler)
        }
    }
    
     /* flush storage to disk and clear transient network caches.  Invokes completionHandler() on the delegate queue. */
    // 这个函数, 还没有实现文档的要求.
    open func flush(completionHandler: @escaping () -> Void) {
        // We create new CURL handles every request.
        delegateQueue.addOperation {
            completionHandler()
        }
    }

    @available(*, unavailable, renamed: "getTasksWithCompletionHandler(_:)")
    open func getTasksWithCompletionHandler(completionHandler: @escaping ([URLSessionDataTask], [URLSessionUploadTask], [URLSessionDownloadTask]) -> Void) {
        getTasksWithCompletionHandler(completionHandler)
    }

    /* invokes completionHandler with outstanding data, upload and download tasks. */
    // 一个闭包, 在 delegateQueue 中完成
    // 逻辑是固定的, 然后通过闭包的形式, 进行业务的配置.
    open func getTasksWithCompletionHandler(_ completionHandler: @escaping ([URLSessionDataTask], [URLSessionUploadTask], [URLSessionDownloadTask]) -> Void)  {
        workQueue.async {
            self.delegateQueue.addOperation {
                
                var dataTasks = [URLSessionDataTask]()
                var uploadTasks = [URLSessionUploadTask]()
                var downloadTasks = [URLSessionDownloadTask]()

                // 这里, 如果不使用 self, 会很难理解. 所以, 该用的时候, 还是要用.
                for task in self.taskRegistry.allTasks {
                    // 只返回, 还在运行, 或者瞪大运行的.
                    guard task.state == .running || task.isSuspendedAfterResume else { continue }
                    // 分类填充.
                    if let uploadTask = task as? URLSessionUploadTask {
                        uploadTasks.append(uploadTask)
                    } else if let dataTask = task as? URLSessionDataTask {
                        dataTasks.append(dataTask)
                    } else if let downloadTask = task as? URLSessionDownloadTask {
                        downloadTasks.append(downloadTask)
                    } else {
                        // Above three are the only required tasks to be returned from this API, so we can ignore any other types of tasks.
                    }
                }
                completionHandler(dataTasks, uploadTasks, downloadTasks)
            }
        }
    }
    
    /* invokes completionHandler with all outstanding tasks. */
    open func getAllTasks(completionHandler: @escaping ([URLSessionTask]) -> Void)  {
        workQueue.async {
            self.delegateQueue.addOperation {
                completionHandler(self.taskRegistry.allTasks.filter { $0.state == .running || $0.isSuspendedAfterResume })
            }
        }
    }
    
    /*
     * URLSessionTask objects are always created in a suspended state and
     * must be sent the -resume message before they will execute.
     */
    
    /* Creates a data task with the given request.  The request may have a body stream. */
    open func dataTask(with request: URLRequest) -> URLSessionDataTask {
        return dataTask(with: _Request(request), behaviour: .callDelegate)
    }
    
    /* Creates a data task to retrieve the contents of the given URL. */
    open func dataTask(with url: URL) -> URLSessionDataTask {
        return dataTask(with: _Request(url), behaviour: .callDelegate)
    }

    /*
     * data task convenience methods.  These methods create tasks that
     * bypass the normal delegate calls for response and data delivery,
     * and provide a simple cancelable asynchronous interface to receiving
     * data.  Errors will be returned in the NSURLErrorDomain,
     * see <Foundation/NSURLError.h>.  The delegate, if any, will still be
     * called for authentication challenges.
     */
    // 不关心具体的过程, 仅仅关心结果.
    open func dataTask(with request: URLRequest,
                       completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
        return dataTask(with: _Request(request), behaviour: .dataCompletionHandler(completionHandler))
    }

    // 根据一个 type 值, 区分是回调, 还是代理, swift 里面, 就是用的 enum. 因为 enum 更加强大.
    open func dataTask(with url: URL, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionDataTask {
        return dataTask(with: _Request(url), behaviour: .dataCompletionHandler(completionHandler))
    }
    
    /* Creates an upload task with the given request.  The body of the request will be created from the file referenced by fileURL */
    open func uploadTask(with request: URLRequest, fromFile fileURL: URL) -> URLSessionUploadTask {
        let r = URLSession._Request(request)
        return uploadTask(with: r, body: .file(fileURL), behaviour: .callDelegate)
    }
    
    /* Creates an upload task with the given request.  The body of the request is provided from the bodyData. */
    open func uploadTask(with request: URLRequest, from bodyData: Data) -> URLSessionUploadTask {
        let r = URLSession._Request(request)
        return uploadTask(with: r, body: .data(createDispatchData(bodyData)), behaviour: .callDelegate)
    }
    
    /* Creates an upload task with the given request.  The previously set body stream of the request (if any) is ignored and the URLSession:task:needNewBodyStream: delegate will be called when the body payload is required. */
    open func uploadTask(withStreamedRequest request: URLRequest) -> URLSessionUploadTask {
        let r = URLSession._Request(request)
        return uploadTask(with: r, body: nil, behaviour: .callDelegate)
    }

    /*
     * upload convenience method.
     */
    open func uploadTask(with request: URLRequest, fromFile fileURL: URL, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionUploadTask {
        let r = URLSession._Request(request)
        return uploadTask(with: r, body: .file(fileURL), behaviour: .dataCompletionHandler(completionHandler))
    }

    open func uploadTask(with request: URLRequest, from bodyData: Data?, completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void) -> URLSessionUploadTask {
        return uploadTask(with: _Request(request), body: .data(createDispatchData(bodyData!)), behaviour: .dataCompletionHandler(completionHandler))
    }
    
    /* Creates a download task with the given request. */
    open func downloadTask(with request: URLRequest) -> URLSessionDownloadTask {
        let r = URLSession._Request(request)
        return downloadTask(with: r, behavior: .callDelegate)
    }
    
    /* Creates a download task to download the contents of the given URL. */
    open func downloadTask(with url: URL) -> URLSessionDownloadTask {
        return downloadTask(with: _Request(url), behavior: .callDelegate)
    }
    
    /* Creates a download task with the resume data.  If the download cannot be successfully resumed, URLSession:task:didCompleteWithError: will be called. */
    open func downloadTask(withResumeData resumeData: Data) -> URLSessionDownloadTask {
        return invalidDownloadTask(behavior: .callDelegate)
    }

    /*
     * download task convenience methods.  When a download successfully
     * completes, the URL will point to a file that must be read or
     * copied during the invocation of the completion routine.  The file
     * will be removed automatically.
     */
    open func downloadTask(with request: URLRequest, completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void) -> URLSessionDownloadTask {
        return downloadTask(with: _Request(request), behavior: .downloadCompletionHandler(completionHandler))
    }

    open func downloadTask(with url: URL, completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void) -> URLSessionDownloadTask {
       return downloadTask(with: _Request(url), behavior: .downloadCompletionHandler(completionHandler))
    }

    open func downloadTask(withResumeData resumeData: Data, completionHandler: @escaping (URL?, URLResponse?, Error?) -> Void) -> URLSessionDownloadTask {
        return invalidDownloadTask(behavior: .downloadCompletionHandler(completionHandler))
    }
    
    /* Creates a bidirectional stream task to a given host and port.
     */
    @available(*, unavailable, message: "URLSessionStreamTask is not available in swift-corelibs-foundation")
    open func streamTask(withHostName hostname: String, port: Int) -> URLSessionStreamTask { NSUnsupported() }
}


// Helpers
fileprivate extension URLSession {
    // 大量的使用枚举, 让代码变得清晰.
    enum _Request {
        case request(URLRequest)
        case url(URL)
    }
    // 一个统一的方法, 将 configuration 里面的内容, 填充到 request 里面去.
    func createConfiguredRequest(from request: URLSession._Request) -> URLRequest {
        let r = request.createMutableURLRequest()
        return _configuration.configure(request: r)
    }
}
extension URLSession._Request {
    init(_ url: URL) {
        self = .url(url)
    }
    init(_ request: URLRequest) {
        self = .request(request)
    }
}
extension URLSession._Request {
    // 这里, 在之前 OC 里面, 就是一个 if 判断, 但在这, 就是 enum 的分化.
    func createMutableURLRequest() -> URLRequest {
        switch self {
        case .url(let url): return URLRequest(url: url)
        case .request(let r): return r
        }
    }
}

fileprivate extension URLSession {
    func createNextTaskIdentifier() -> Int {
        return workQueue.sync {
            let i = nextTaskIdentifier
            nextTaskIdentifier += 1
            return i
        }
    }
}

// fileprivate, 很好, 限制了范围.
// 这样更好, 一个专门的 private, public 方法调用这个大而全的方法, 这个方法, 又不会暴露出去.
fileprivate extension URLSession {
    /// All public methods funnel into this one. very good.
    // _TaskRegistry._Behaviour 里面, 存储了值, 而不仅仅是 type, 应该多用这种特性.
    func dataTask(with request: _Request,
                  behaviour: _TaskRegistry._Behaviour) -> URLSessionDataTask {
        // 如果, session 已经 invalidated, 禁止重新开启任务.
        guard !self.invalidated else { fatalError("Session invalidated") }
        let request = createConfiguredRequest(from: request) // 通过 configuration 生成 request.
        let id = createNextTaskIdentifier() // 生成 id.
        let task = URLSessionDataTask(session: self,
                                      request: request,
                                      taskIdentifier: id)
        // 所以, Session 其实也是个任务管理的机制, 如何进行网络连接, 数据如何管理, 是各个 task 的事情.
        // 将 task 异步添加到任务管理对象里面去.
        workQueue.async {
            self.taskRegistry.add(task, behaviour: behaviour)
        }
        return task
    }
    
    /// Create an upload task.
    ///
    /// All public methods funnel into this one.
    func uploadTask(with request: _Request, body: URLSessionTask._Body?, behaviour: _TaskRegistry._Behaviour) -> URLSessionUploadTask {
        guard !self.invalidated else { fatalError("Session invalidated") }
        let r = createConfiguredRequest(from: request)
        let i = createNextTaskIdentifier()
        let task = URLSessionUploadTask(session: self, request: r, taskIdentifier: i, body: body)
        workQueue.async {
            self.taskRegistry.add(task, behaviour: behaviour)
        }
        return task
    }
    
    /// Create a download task
    func downloadTask(with request: _Request, behavior: _TaskRegistry._Behaviour) -> URLSessionDownloadTask {
        guard !self.invalidated else { fatalError("Session invalidated") }
        let r = createConfiguredRequest(from: request)
        let i = createNextTaskIdentifier()
        let task = URLSessionDownloadTask(session: self, request: r, taskIdentifier: i)
        workQueue.async {
            self.taskRegistry.add(task, behaviour: behavior)
        }
        return task
    }
    
    /// Create a download task that is marked invalid.
    func invalidDownloadTask(behavior: _TaskRegistry._Behaviour) -> URLSessionDownloadTask {
        /* We do not support resume data in swift-corelibs-foundation, so whatever we are passed, we should just behave as Darwin does in the presence of invalid data. */
        
        guard !self.invalidated else { fatalError("Session invalidated") }
        let task = URLSessionDownloadTask()
        task.createdFromInvalidResumeData = true
        task.taskIdentifier = createNextTaskIdentifier()
        task.session = self
        workQueue.async {
            self.taskRegistry.add(task, behaviour: behavior)
        }
        return task
    }
}

internal extension URLSession {
    /// The kind of callback / delegate behaviour of a task.
    ///
    /// This is similar to the `URLSession.TaskRegistry.Behaviour`, but it
    /// also encodes the kind of delegate that the session has.
    enum _TaskBehaviour {
        /// The session has no delegate, or just a plain `URLSessionDelegate`.
        case noDelegate
        /// The session has a delegate of type `URLSessionTaskDelegate`
        case taskDelegate(URLSessionTaskDelegate)
        /// Default action for all events, except for completion.
        /// - SeeAlso: URLSession.TaskRegistry.Behaviour.dataCompletionHandler
        case dataCompletionHandler(URLSession._TaskRegistry.DataTaskCompletion)
        /// Default action for all events, except for completion.
        /// - SeeAlso: URLSession.TaskRegistry.Behaviour.downloadCompletionHandler
        case downloadCompletionHandler(URLSession._TaskRegistry.DownloadTaskCompletion)
    }

    func behaviour(for task: URLSessionTask) -> _TaskBehaviour {
        switch taskRegistry.behaviour(for: task) {
        case .dataCompletionHandler(let c): return .dataCompletionHandler(c)
        case .downloadCompletionHandler(let c): return .downloadCompletionHandler(c)
        case .callDelegate:
            guard let d = delegate as? URLSessionTaskDelegate else {
                return .noDelegate
            }
            return .taskDelegate(d)
        }
    }
}


internal protocol URLSessionProtocol: AnyObject {
    func add(handle: _EasyHandle)
    func remove(handle: _EasyHandle)
    func behaviour(for: URLSessionTask) -> URLSession._TaskBehaviour
    var configuration: URLSessionConfiguration { get }
    var delegate: URLSessionDelegate? { get }
}
extension URLSession: URLSessionProtocol {
    func add(handle: _EasyHandle) {
        multiHandle.add(handle)
    }
    func remove(handle: _EasyHandle) {
        multiHandle.remove(handle)
    }
}
/// This class is only used to allow `URLSessionTask.init()` to work.
///
/// - SeeAlso: URLSessionTask.init()
final internal class _MissingURLSession: URLSessionProtocol {
    var delegate: URLSessionDelegate? {
        fatalError()
    }
    var configuration: URLSessionConfiguration {
        fatalError()
    }
    func add(handle: _EasyHandle) {
        fatalError()
    }
    func remove(handle: _EasyHandle) {
        fatalError()
    }
    func behaviour(for: URLSessionTask) -> URLSession._TaskBehaviour {
        fatalError()
    }
}
