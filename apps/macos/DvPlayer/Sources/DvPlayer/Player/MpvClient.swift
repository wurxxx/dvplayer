import Foundation
import MpvC
import OpenGL.GL3

/// 进程内 libmpv 客户端，对外接口和旧的 `MpvIPC`（unix socket + JSON）一致。
///
/// 为什么换掉子进程：
/// - 视频要画进我们自己的 `NSOpenGLView`（render API），才能和控件同一个窗口，
///   拖动 / 缩放 / 层级问题全部消失，和 Windows 的 libmpv 嵌入同构；
/// - 子进程 + `geometry` 同步永远慢一拍（两个窗口没法同帧）。
///
/// 事件名沿用 JSON IPC 的约定：属性事件传属性名（`time-pos`），
/// 其它事件加 `@` 前缀（`@end-file`），`data` 的形状也和 JSON 版一致，
/// 所以 `MpvEngine.handle(event:data:)` 不用改。
final class MpvClient: @unchecked Sendable {
    enum Reply {
        case success(Any?)
        case failure(String)
    }

    /// 事件回调（主线程）。
    var onEvent: ((_ name: String, _ data: Any?) -> Void)?
    /// mpv 已经销毁（主线程）。
    var onDisconnect: (() -> Void)?

    private(set) var handle: OpaquePointer?
    private(set) var renderContext: OpaquePointer?

    /// mpv 的事件循环线程。
    private var eventThread: Thread?
    private var running = false

    private let gate = NSLock()
    private var pending: [Int: (Reply) -> Void] = [:]
    private var nextRequestId = 1
    private var nextObserveId = 1
    private var closed = false

    /// 渲染更新回调的持有者（C 回调没有闭包捕获）。
    private var updateBox: Unmanaged<UpdateBox>?

    // MARK: - 生命周期

    /// 创建并初始化 mpv。`options` 是启动选项（等价于旧的命令行参数）。
    ///
    /// 必须在主线程调用，且在窗口内容视图建好之前——mpv 初始化后立刻就要
    /// 有渲染上下文，否则它会退回「自己开窗」的 VO。
    func start(options: [String: String]) -> Bool {
        guard let ctx = mpv_create() else {
            NSLog("[Mpv] mpv_create 失败")
            return false
        }
        handle = ctx

        for (key, value) in options {
            let rc = mpv_set_option_string(ctx, key, value)
            if rc < 0 {
                NSLog("[Mpv] 选项 %@=%@ 设置失败 rc=%d", key, value, rc)
            }
        }

        let rc = mpv_initialize(ctx)
        guard rc >= 0 else {
            NSLog("[Mpv] mpv_initialize 失败 rc=%d", rc)
            mpv_terminate_destroy(ctx)
            handle = nil
            return false
        }

        running = true
        let thread = Thread { [weak self] in self?.eventLoop() }
        thread.name = "mpv-events"
        thread.start()
        eventThread = thread
        return true
    }

    /// 在**当前线程**已设为 current 的 OpenGL 上下文上建渲染上下文。
    ///
    /// 调用方必须是渲染队列（`MpvVideoView.glQueue`）：`mpv_render_*` 要求
    /// GL 上下文在调用线程 current，而且同一个上下文的 `mpv_render_*` 不能并发。
    func createRenderContext(apiType: String = "opengl") -> Bool {
        guard let ctx = handle else { return false }
        guard renderContext == nil else { return true }

        var initParams = mpv_opengl_init_params(
            get_proc_address: { _, name in
                guard let name else { return nil }
                return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
            },
            get_proc_address_ctx: nil
        )

        // 显式选 gpu-next：DV 整形（`pl_shader_dovi_reshape`）只在它里面。
        // legacy `gpu` 会把 IPT 当 YCbCr 解，P5 画面发紫（framebuffer 实测）。
        // 参数类型是 `char*`（字符串本身），不是 `char**`。
        let renderer = strdup("gpu-next")
        defer { free(renderer) }

        let apiTypeC = strdup(apiType)
        defer { free(apiTypeC) }

        var params: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                             data: UnsafeMutableRawPointer(apiTypeC)),
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS,
                             data: UnsafeMutableRawPointer(&initParams)),
            mpv_render_param(type: MPV_RENDER_PARAM_RENDERER,
                             data: UnsafeMutableRawPointer(renderer)),
            mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
        ]

        var rctx: OpaquePointer?
        let rc = mpv_render_context_create(&rctx, ctx, &params)
        guard rc >= 0, let rctx else {
            NSLog("[Mpv] render_context_create 失败 rc=%d (%@)",
                  rc, String(cString: mpv_error_string(rc)))
            return false
        }
        renderContext = rctx
        return true
    }

    /// 销毁渲染上下文。必须在 GL 上下文 current 的线程调用（渲染队列）。
    func destroyRenderContext() {
        guard let rctx = renderContext else { return }
        renderContext = nil
        mpv_render_context_set_update_callback(rctx, nil, nil)
        mpv_render_context_free(rctx)
    }

    /// 渲染一帧到**当前绑定**的 framebuffer。
    ///
    /// `CAOpenGLLayer` 给的不是默认 FBO（0），而是它自己建的离屏 FBO，
    /// 所以必须问 GL 当前绑的是哪个；传死 0 会画到别处去，读出来全黑。
    ///
    /// `width` / `height` 是**像素**（不是点）；`flipY` 让 OpenGL 左下原点的
    /// 画面正过来。
    func render(width: Int, height: Int, flipY: Bool = true) {
        guard let rctx = renderContext, width > 0, height > 0 else { return }
        var boundFBO: GLint = 0
        glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &boundFBO)
        var target = mpv_opengl_fbo(fbo: Int32(boundFBO),
                                    w: Int32(width), h: Int32(height),
                                    internal_format: 0)
        var flip: Int32 = flipY ? 1 : 0
        withUnsafeMutablePointer(to: &target) { targetPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                var params: [mpv_render_param] = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO,
                                     data: UnsafeMutableRawPointer(targetPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y,
                                     data: UnsafeMutableRawPointer(flipPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                ]
                _ = mpv_render_context_render(rctx, &params)
            }
        }
    }

    /// 注册「有新帧要画」的回调。
    ///
    /// 回调在 mpv 的线程上执行，**不能**在里面调 `mpv_render_*`（文档禁止），
    /// 也不能绕主线程——主线程忙的时候绕一圈就是掉帧。调用方直接把它转投到
    /// 自己的渲染队列。
    func setUpdateCallback(_ callback: @escaping () -> Void) {
        guard let rctx = renderContext else { return }
        if let old = updateBox {
            mpv_render_context_set_update_callback(rctx, nil, nil)
            old.release()
        }
        let box = Unmanaged.passRetained(UpdateBox(callback))
        updateBox = box
        mpv_render_context_set_update_callback(rctx, { data in
            guard let data else { return }
            Unmanaged<UpdateBox>.fromOpaque(data).takeUnretainedValue().fire()
        }, box.toOpaque())
    }

    /// 告诉 mpv 这一帧已经显示（帧率 / 掉帧统计用）。
    func reportSwap() {
        guard let rctx = renderContext else { return }
        mpv_render_context_report_swap(rctx)
    }

    // MARK: - 命令

    /// 发一条命令，例如 `command(["set_property", "pause", "yes"])`。
    ///
    /// 一律走 `mpv_command_async`：
    /// - 同步的 `mpv_command` 会等 mpv core 处理完，主线程上可能卡几十毫秒
    ///   （旧 IPC 只是往 socket 写一行，从不阻塞）；
    /// - 异步接口在内部立刻把参数解析成自己的副本，所以函数返回后就能释放
    ///   C 字符串；
    /// - 队列顺序由 mpv 保证，`set_property start` 在 `loadfile` 之前照样生效。
    func command(_ args: [Any], reply: ((Reply) -> Void)? = nil) {
        gate.lock()
        let alive = !closed
        let ctx = alive ? handle : nil
        gate.unlock()
        guard alive, let ctx else {
            reply?(.failure("mpv 已退出"))
            return
        }

        // `set_property` / `get_property` / `observe_property` 不是 mpv 的
        // input 命令，它们是 JSON IPC 层的语法糖（`input/ipc.c` 里单独处理的）。
        // 进程内没有那一层，要自己转成对应的 C API。
        if let name = args.first as? String, Self.isPropertyCommand(name) {
            runPropertyCommand(name, args: args, ctx: ctx, reply: reply)
            return
        }

        var strings: [UnsafePointer<CChar>?] = args.map { arg in
            let text: String
            switch arg {
                case let value as String: text = value
                case let value as Bool: text = value ? "yes" : "no"
                case let value as Int: text = String(value)
                case let value as Int64: text = String(value)
                case let value as Double: text = String(value)
                default: text = String(describing: arg)
            }
            return UnsafePointer(strdup(text))
        }
        strings.append(nil)
        defer {
            for pointer in strings {
                if let pointer { free(UnsafeMutablePointer(mutating: pointer)) }
            }
        }

        let id: Int = {
            gate.lock(); defer { gate.unlock() }
            let value = nextRequestId
            nextRequestId += 1
            if let reply { pending[value] = reply }
            return value
        }()

        let rc = mpv_command_async(ctx, UInt64(id), &strings)
        if rc < 0 {
            gate.lock()
            let callback = pending.removeValue(forKey: id)
            gate.unlock()
            if let callback {
                DispatchQueue.main.async { callback(.failure("mpv 命令被拒绝 rc=\(rc)")) }
            } else {
                NSLog("[Mpv] 命令被拒绝 rc=%d args=%@", rc, args.description)
            }
        }
    }

    private static func isPropertyCommand(_ name: String) -> Bool {
        name == "set_property" || name == "get_property" || name == "observe_property"
    }

    /// 把 JSON IPC 的属性命令转成 C API。
    private func runPropertyCommand(_ name: String, args: [Any],
                                    ctx: OpaquePointer,
                                    reply: ((Reply) -> Void)?) {
        let id: Int = {
            gate.lock(); defer { gate.unlock() }
            let value = nextRequestId
            nextRequestId += 1
            if let reply { pending[value] = reply }
            return value
        }()

        // `observe_property` 的参数是 (id, name)，我们自己的 id 跟它无关，
        // 统一用内部自增的 observe id。
        if name == "observe_property" {
            guard args.count >= 3, let property = args[2] as? String else {
                reply?(.failure("observe_property 参数不对"))
                return
            }
            gate.lock()
            let observeId = nextObserveId
            nextObserveId += 1
            let alive = !closed
            gate.unlock()
            guard alive else {
                reply?(.failure("mpv 已退出"))
                return
            }
            let rc = mpv_observe_property(ctx, UInt64(observeId), property, MPV_FORMAT_NODE)
            finishPropertyCall(id, rc, reply: reply)
            return
        }

        guard args.count >= 2, let property = args[1] as? String else {
            finishPropertyCall(id, MPV_ERROR_INVALID_PARAMETER.rawValue, reply: reply)
            return
        }

        if name == "get_property" {
            let rc = mpv_get_property_async(ctx, UInt64(id), property, MPV_FORMAT_NODE)
            if rc < 0 {
                gate.lock()
                let callback = pending.removeValue(forKey: id)
                gate.unlock()
                DispatchQueue.main.async {
                    callback?(.failure("mpv 属性读取被拒绝 rc=\(rc)"))
                }
            }
            return
        }

        // set_property：值可以是字符串 / 数字 / 布尔，统一转成 NODE。
        let value = args.count >= 3 ? args[2] : "no"
        var node = mpv_node()
        var allocated: [UnsafeMutableRawPointer] = []
        defer { for pointer in allocated { free(pointer) } }

        if let text = value as? String {
            let copy = strdup(text)!
            allocated.append(UnsafeMutableRawPointer(copy))
            node.format = MPV_FORMAT_STRING
            node.u.string = copy
        } else if let flag = value as? Bool {
            node.format = MPV_FORMAT_FLAG
            node.u.flag = flag ? 1 : 0
        } else if let number = value as? Int {
            node.format = MPV_FORMAT_INT64
            node.u.int64 = Int64(number)
        } else if let number = value as? Int64 {
            node.format = MPV_FORMAT_INT64
            node.u.int64 = number
        } else if let number = value as? Double {
            node.format = MPV_FORMAT_DOUBLE
            node.u.double_ = number
        } else {
            let copy = strdup(String(describing: value))!
            allocated.append(UnsafeMutableRawPointer(copy))
            node.format = MPV_FORMAT_STRING
            node.u.string = copy
        }

        let rc = mpv_set_property_async(ctx, UInt64(id), property, MPV_FORMAT_NODE, &node)
        if rc < 0 {
            gate.lock()
            let callback = pending.removeValue(forKey: id)
            gate.unlock()
            DispatchQueue.main.async {
                callback?(.failure("mpv 属性设置被拒绝 rc=\(rc)"))
            }
        }
    }

    /// 同步完成的属性调用（`observe_property` 没有异步版本）。
    private func finishPropertyCall(_ id: Int, _ rc: Int32, reply: ((Reply) -> Void)?) {
        gate.lock()
        let callback = pending.removeValue(forKey: id)
        gate.unlock()
        guard let callback else { return }
        if rc < 0 {
            DispatchQueue.main.async {
                callback(.failure(String(cString: mpv_error_string(rc))))
            }
        } else {
            DispatchQueue.main.async { callback(.success(nil)) }
        }
    }

    /// 订阅属性；mpv 会先推一次当前值。
    func observe(_ name: String) {
        guard let ctx = handle else { return }
        gate.lock()
        let id = nextObserveId
        nextObserveId += 1
        let alive = !closed
        gate.unlock()
        guard alive else { return }
        let rc = mpv_observe_property(ctx, UInt64(id), name, MPV_FORMAT_NODE)
        if rc < 0 {
            NSLog("[Mpv] observe %@ 失败 rc=%d", name, rc)
        }
    }

    /// 销毁 mpv 核心。**调用前必须先 `destroyRenderContext()`**（在渲染队列上）。
    func close() {
        gate.lock()
        if closed {
            gate.unlock()
            return
        }
        closed = true
        let waiting = pending
        pending.removeAll()
        gate.unlock()
        for (_, callback) in waiting { callback(.failure("mpv 已关闭")) }

        running = false
        if let rctx = renderContext {
            // 兜底：调用方漏了 destroyRenderContext，这里也不能直接 free
            // （需要 GL 上下文），只把指针丢掉，靠 mpv_terminate_destroy 收尾。
            NSLog("[Mpv] close 时渲染上下文还在，说明调用方没在渲染队列销毁")
            renderContext = nil
            _ = rctx
        }
        if let box = updateBox {
            updateBox = nil
            box.release()
        }
        if let ctx = handle {
            handle = nil
            mpv_terminate_destroy(ctx)
        }
    }

    // MARK: - 事件循环

    private func eventLoop() {
        guard let ctx = handle else { return }
        while running {
            guard let event = mpv_wait_event(ctx, 0.1) else { continue }

            switch event.pointee.event_id {
                case MPV_EVENT_NONE:
                    continue

                case MPV_EVENT_SHUTDOWN:
                    DispatchQueue.main.async { [weak self] in self?.onDisconnect?() }
                    running = false
                    return

                case MPV_EVENT_PROPERTY_CHANGE:
                    guard let data = event.pointee.data else { continue }
                    let prop = data.assumingMemoryBound(to: mpv_event_property.self).pointee
                    guard let namePtr = prop.name else { continue }
                    let name = String(cString: namePtr)
                    // `data` 只在事件有效期内可用，必须当场转成 Swift 值。
                    let value = Self.nodeValue(prop)
                    DispatchQueue.main.async { [weak self] in
                        self?.onEvent?(name, value)
                    }

                case MPV_EVENT_COMMAND_REPLY,
                     MPV_EVENT_SET_PROPERTY_REPLY,
                     MPV_EVENT_GET_PROPERTY_REPLY:
                    let id = Int(event.pointee.reply_userdata)
                    let error = event.pointee.error
                    // `get_property` 的结果在事件数据里（`mpv_event_property`），
                    // 命令的结果在 `mpv_event_command.result` 里，都必须当场转成 Swift 值。
                    var result: Any?
                    if error >= 0, let data = event.pointee.data {
                        if event.pointee.event_id == MPV_EVENT_GET_PROPERTY_REPLY {
                            let prop = data.assumingMemoryBound(
                                to: mpv_event_property.self).pointee
                            result = Self.nodeValue(prop)
                        } else if event.pointee.event_id == MPV_EVENT_COMMAND_REPLY {
                            let command = data.assumingMemoryBound(
                                to: mpv_event_command.self).pointee
                            result = Self.nodeToSwift(command.result)
                        }
                    }
                    gate.lock()
                    let callback = pending.removeValue(forKey: id)
                    gate.unlock()
                    if let callback {
                        let text = error < 0
                            ? String(cString: mpv_error_string(error))
                            : "success"
                        DispatchQueue.main.async {
                            callback(error < 0 ? .failure(text) : .success(result))
                        }
                    }

                case MPV_EVENT_END_FILE:
                    // `@end-file` 的形状和 JSON IPC 一致：{reason, file_error}。
                    var payload: [String: Any] = [:]
                    if let data = event.pointee.data {
                        let info = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                        switch info.reason {
                            case MPV_END_FILE_REASON_EOF: payload["reason"] = "eof"
                            case MPV_END_FILE_REASON_STOP: payload["reason"] = "stop"
                            case MPV_END_FILE_REASON_QUIT: payload["reason"] = "quit"
                            case MPV_END_FILE_REASON_ERROR:
                                payload["reason"] = "error"
                                payload["file_error"] = String(cString: mpv_error_string(info.error))
                            case MPV_END_FILE_REASON_REDIRECT: payload["reason"] = "redirect"
                            default: payload["reason"] = "unknown"
                        }
                    }
                    DispatchQueue.main.async { [weak self] in
                        self?.onEvent?("@end-file", payload)
                    }

                case MPV_EVENT_FILE_LOADED:
                    DispatchQueue.main.async { [weak self] in
                        self?.onEvent?("@file-loaded", nil)
                    }

                case MPV_EVENT_LOG_MESSAGE:
                    guard let data = event.pointee.data else { continue }
                    let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                    let text = message.text.map { String(cString: $0) } ?? ""
                    let prefix = message.prefix.map { String(cString: $0) } ?? ""
                    DispatchQueue.main.async { [weak self] in
                        self?.onEvent?("@log-message", ["prefix": prefix, "text": text])
                    }

                default:
                    break
            }
        }
    }

    /// 把 `mpv_event_property` 转成 Swift 值。
    ///
    /// 统一用 NODE 格式订阅：数字 / 字符串 / 布尔 / 数组 / 对象都能还原，
    /// 而 `MpvEngine` 是按 JSON 的形状取值的（`as? Double` / `as? [String: Any]`）。
    private static func nodeValue(_ prop: mpv_event_property) -> Any? {
        guard let data = prop.data else { return nil }
        guard prop.format == MPV_FORMAT_NODE else { return nil }
        let node = data.assumingMemoryBound(to: mpv_node.self).pointee
        return nodeToSwift(node)
    }

    private static func nodeToSwift(_ node: mpv_node) -> Any? {
        switch node.format {
            case MPV_FORMAT_STRING:
                guard let text = node.u.string else { return nil }
                return String(cString: text)
            case MPV_FORMAT_FLAG:
                return node.u.flag != 0
            case MPV_FORMAT_INT64:
                return node.u.int64
            case MPV_FORMAT_DOUBLE:
                return node.u.double_
            case MPV_FORMAT_NODE_ARRAY:
                guard let list = node.u.list else { return nil }
                var out: [Any] = []
                out.reserveCapacity(Int(list.pointee.num))
                for index in 0..<Int(list.pointee.num) {
                    out.append(nodeToSwift(list.pointee.values[index]) as Any)
                }
                return out
            case MPV_FORMAT_NODE_MAP:
                guard let list = node.u.list else { return nil }
                var out: [String: Any] = [:]
                for index in 0..<Int(list.pointee.num) {
                    guard let key = list.pointee.keys[index] else { continue }
                    out[String(cString: key)] = nodeToSwift(list.pointee.values[index])
                }
                return out
            default:
                return nil
        }
    }
}

/// 渲染更新回调的持有者（C 回调没有闭包捕获，用这个包一层）。
///
/// 直接在 mpv 的线程上调用 `callback`，不绕主线程：调用方负责转投渲染队列。
private final class UpdateBox {
    private let callback: () -> Void
    init(_ callback: @escaping () -> Void) { self.callback = callback }
    func fire() { callback() }
}
