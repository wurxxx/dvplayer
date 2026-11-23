import AppKit
import OpenGL.GL3

/// 视频画布：mpv 通过 render API 把画面直接画进这个视图。
///
/// 和 Windows 的 `MpvHost` 同构——视频和控件在**同一个窗口**里，
/// 所以拖动 / 缩放 / 层级天然同步，不需要 `geometry` 来回追两个窗口。
///
/// 为什么是 `NSOpenGLView` + 自己 swap，而不是 `CAOpenGLLayer`：
/// `CAOpenGLLayer` 在 `isAsynchronous = false` 时，`display()` 只是打标记，
/// 真正的 `draw` 在主线程的 CATransaction 里执行。实测拖动窗口时主线程被
/// 事件跟踪占住，拖动 0.9 秒内一帧都没画出来（`frames 16->16`）。
/// 这里改成在**渲染队列**上持有 GL 上下文、直接 `flushBuffer`：swap 是 GPU 侧
/// 操作，和窗口移动（WindowServer 侧）互不阻塞。
///
/// 渲染队列也是 IINA 的做法。IINA 的注释说得很直接：在主线程渲染时，
/// 侧栏滑出和浮动控制条的拖动会明显发涩。
final class MpvVideoView: NSOpenGLView {
    private let client: MpvClient
    /// 串行渲染队列：`mpv_render_*` 对同一个上下文不能并发。
    private let glQueue = DispatchQueue(label: "dvplayer.mpvgl", qos: .userInteractive)
    private let stateLock = NSRecursiveLock()

    private var renderReady = false
    private var pendingRender = false
    private var rendering = false
    /// `prepareOpenGL` 只做一次（layer-backed 容器里不会自动调）。
    private var prepared = false

    /// 首帧真的画上去了（给上层判断 loading 结束）。
    private(set) var hasDrawnFrame = false
    /// 累计画了多少帧（拖动自检用它确认视频没停）。
    private(set) var drawnFrames = 0
    var onRenderReady: (() -> Void)?
    var onFirstDraw: (() -> Void)?

    init(client: MpvClient) {
        self.client = client
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAColorSize), 24,
            UInt32(NSOpenGLPFAAlphaSize), 8,
            0,
        ]
        let format = NSOpenGLPixelFormat(attributes: attributes)
        super.init(frame: .zero, pixelFormat: format)!
        wantsBestResolutionOpenGLSurface = true
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isOpaque: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        // layer-backed 容器里 `prepareOpenGL` 不会自动调用（AppKit 只在
        // 传统 drawing path 里调它），这里手动来一次，保证 GL 上下文建好。
        if !prepared {
            prepared = true
            prepareOpenGL()
        }
        scheduleRender()
    }

    override func prepareOpenGL() {
        super.prepareOpenGL()
        guard let context = openGLContext else { return }
        context.makeCurrentContext()
        var swapInterval: GLint = 1
        context.setValues(&swapInterval, for: .swapInterval)

        // 渲染上下文必须在 GL 上下文 current 的线程上建；之后所有 mpv_render_*
        // 也都在同一个渲染队列、同一个 GL 上下文上跑。
        // GL 上下文不是线程绑定的，但每个线程调用前都要自己 makeCurrent。
        glQueue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            self.openGLContext?.makeCurrentContext()
            guard self.client.createRenderContext() else {
                NSLog("[Video] render context 创建失败")
                return
            }
            self.renderReady = true
            // 新帧回调在 mpv 的线程上，不能在里面碰 GL：只投递渲染任务。
            self.client.setUpdateCallback { [weak self] in
                self?.scheduleRender()
            }
            DispatchQueue.main.async { [weak self] in
                self?.onRenderReady?()
            }
            self.scheduleRenderLocked()
        }
    }

    override func reshape() {
        super.reshape()
        scheduleRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        scheduleRender()
    }

    /// 有新帧 / 尺寸变了：投递一次渲染。
    ///
    /// 渲染队列上最多排一个任务：mpv 的出帧速度比显示器快，排一队只会
    /// 让延迟越来越大，拖动时看起来更「粘」。
    func scheduleRender() {
        stateLock.lock()
        defer { stateLock.unlock() }
        scheduleRenderLocked()
    }

    private func scheduleRenderLocked() {
        guard renderReady else { return }
        guard !rendering else {
            pendingRender = true
            return
        }
        rendering = true
        glQueue.async { [weak self] in
            self?.renderOnce()
        }
    }

    private func renderOnce() {
        stateLock.lock()
        guard let context = openGLContext, renderReady else {
            rendering = false
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        context.makeCurrentContext()
        let backing = convertToBacking(bounds)
        let width = Int(backing.width)
        let height = Int(backing.height)
        if width > 1, height > 1 {
            glViewport(0, 0, GLsizei(width), GLsizei(height))
            client.render(width: width, height: height)
            context.flushBuffer()
            client.reportSwap()

            stateLock.lock()
            drawnFrames += 1
            let first = !hasDrawnFrame
            hasDrawnFrame = true
            stateLock.unlock()

            if first {
                DispatchQueue.main.async { [weak self] in self?.onFirstDraw?() }
            }
        }

        // 期间又来了新帧：再排一次。
        stateLock.lock()
        rendering = false
        let again = pendingRender
        pendingRender = false
        stateLock.unlock()
        if again { scheduleRender() }
    }

    /// 在渲染队列上销毁 mpv 渲染上下文。
    ///
    /// `mpv_render_context_free` 要求 GL 上下文在调用线程 current，
    /// 所以不能顺手在主线程 `client.close()` 里做。
    func shutdownRenderContext() {
        glQueue.sync { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            defer { self.stateLock.unlock() }
            guard self.renderReady else { return }
            self.renderReady = false
            self.openGLContext?.makeCurrentContext()
            self.client.destroyRenderContext()
        }
    }

    /// 从当前 GL framebuffer 读一帧存成 PNG。
    ///
    /// 不能用 mpv 的 `screenshot-to-file`：render API 下它会**静默回退到软件路径**，
    /// 截出来的是解码帧直接转 RGB、不含 DV reshape（实测会发紫）。
    func snapshot(to path: String) -> Bool {
        var ok = false
        glQueue.sync { [weak self] in
            guard let self, let context = self.openGLContext else { return }
            context.makeCurrentContext()
            let backing = self.convertToBacking(self.bounds)
            let width = Int(backing.width)
            let height = Int(backing.height)
            guard width > 1, height > 1 else { return }

            glViewport(0, 0, GLsizei(width), GLsizei(height))
            self.client.render(width: width, height: height)

            let rowBytes = width * 4
            var pixels = [UInt8](repeating: 0, count: rowBytes * height)
            glReadBuffer(GLenum(GL_BACK))
            glPixelStorei(GLenum(GL_PACK_ALIGNMENT), 1)
            glReadPixels(0, 0, GLsizei(width), GLsizei(height),
                         GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &pixels)

            // OpenGL 原点在左下，PNG 要左上：翻行。
            var temp = [UInt8](repeating: 0, count: rowBytes)
            pixels.withUnsafeMutableBufferPointer { buffer in
                temp.withUnsafeMutableBufferPointer { scratch in
                    guard let base = buffer.baseAddress,
                          let scratchBase = scratch.baseAddress else { return }
                    for y in 0..<(height / 2) {
                        let top = y * rowBytes
                        let bottom = (height - 1 - y) * rowBytes
                        memcpy(scratchBase, base + top, rowBytes)
                        memcpy(base + top, base + bottom, rowBytes)
                        memcpy(base + bottom, scratchBase, rowBytes)
                    }
                }
            }

            guard let provider = CGDataProvider(data: Data(pixels) as CFData),
                  let image = CGImage(width: width, height: height,
                                      bitsPerComponent: 8, bitsPerPixel: 32,
                                      bytesPerRow: rowBytes,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(
                                        rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                      provider: provider, decode: nil,
                                      shouldInterpolate: false, intent: .defaultIntent),
                  let png = NSBitmapImageRep(cgImage: image)
                    .representation(using: .png, properties: [:])
            else { return }

            ok = (try? png.write(to: URL(fileURLWithPath: path))) != nil
        }
        return ok
    }
}
