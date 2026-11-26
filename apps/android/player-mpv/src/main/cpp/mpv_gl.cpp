// libmpv + EGL/OpenGL ES 渲染层（A4 最小出画 + A5 HDR 输出）。
//
// 结构：
//   - mpv 的 event 线程独立跑（mpv_wait_event 会阻塞）；
//   - EGLDisplay / EGLContext / EGLSurface 与 mpv_render_context 全部归渲染线程所有，
//     attach/detach 只是把 Surface 投递给渲染线程，避免跨线程 makeCurrent；
//   - mpv_render_context 的 update 回调只置标志 + 唤醒，真正绘制在渲染线程里。
//
// HDR：事件线程监听 video-params/primaries 与 gamma，算出目标 dataspace；
// 渲染线程据此重建 EGLSurface（EGL_GL_COLORSPACE_BT2020_PQ_EXT 等）并调用
// ANativeWindow_setBuffersDataSpace。两者必须一起做，只改其中一个不会真的进 HDR。
#include <jni.h>

#include <android/data_space.h>
#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#include <dlfcn.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>

#include <mpv/client.h>
#include <mpv/render_gl.h>

#include <atomic>
#include <condition_variable>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#define LOG_TAG "DvMpv"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

namespace {

constexpr int32_t kDataspaceSrgb = ADATASPACE_SRGB;
// ADATASPACE_* 在 API 28 才进 NDK 头，这里是同名的字面值，运行时由系统解释。
constexpr int32_t kDataspaceBt2020Pq = ADATASPACE_BT2020_PQ;
constexpr int32_t kDataspaceBt2020Hlg = ADATASPACE_BT2020_HLG;

void *egl_proc_address(void *ctx, const char *name) {
    (void)ctx;
    return reinterpret_cast<void *>(eglGetProcAddress(name));
}

// ANativeWindow_setBuffersDataSpace 是 __INTRODUCED_IN(28)，minSdk 是 26，
// 直接调用会链接失败，所以运行时 dlsym。
using SetBuffersDataSpaceFn = int32_t (*)(ANativeWindow *, int32_t);

SetBuffersDataSpaceFn set_buffers_dataspace() {
    static SetBuffersDataSpaceFn fn = [] {
        void *lib = dlopen("libandroid.so", RTLD_NOW | RTLD_LOCAL);
        if (!lib) {
            return static_cast<SetBuffersDataSpaceFn>(nullptr);
        }
        return reinterpret_cast<SetBuffersDataSpaceFn>(
            dlsym(lib, "ANativeWindow_setBuffersDataSpace"));
    }();
    return fn;
}

// 静态 HDR 元数据走 EGL 的 surface 扩展，随 buffer 一起交给 SurfaceFlinger：
//   EGL_EXT_surface_SMPTE2086_metadata / EGL_EXT_surface_CTA861_3_metadata
// 这比 ASurfaceControl_* 可靠：后者只能建一个 child layer，元数据挂不在
// SurfaceView 自己的 buffer layer 上，SF 侧的 `hdr metadata types` 仍是 0。
// HDR10+ 的动态元数据（ST2094-40）没有公开写入接口，必须走平台解码器（Media3）。
// 常量用 NDK eglext.h 里的 EGL_SMPTE2086_*_EXT / EGL_CTA861_3_*_EXT。

/** eglSurfaceAttrib 的浮点属性要按 IEEE-754 位模式塞进 EGLint。 */
EGLint float_bits(float v) {
    EGLint out = 0;
    static_assert(sizeof(out) == sizeof(v), "float 与 EGLint 尺寸不一致");
    memcpy(&out, &v, sizeof(out));
    return out;
}

struct Player {
    mpv_handle *mpv = nullptr;
    mpv_render_context *render = nullptr;

    std::thread render_thread;
    std::thread event_thread;

    // attach / detach 与渲染线程之间的交接口
    std::mutex mu;
    std::condition_variable cv;
    ANativeWindow *pending_window = nullptr;  // 非空表示要换窗口
    bool detach_requested = false;
    bool quit = false;
    std::atomic<bool> redraw{false};

    // GL 就绪前 loadfile 会让 mpv 认为「没有视频输出」，只播音频；
    // 所以先把文件攒起来，等 render context 建好再真正加载。
    std::string pending_file;
    bool has_pending = false;
    int pending_width = 0;
    int pending_height = 0;

    // 事件线程写、渲染线程读
    std::atomic<int32_t> desired_dataspace{kDataspaceSrgb};
    // HDR 直出开关：false 时 mpv 做 HDR→SDR tone mapping，surface 固定 sRGB。
    std::atomic<bool> hdr_passthrough{true};
    std::atomic<bool> surface_dirty{false};
    std::string primaries;
    std::string gamma;

    // 以下只允许渲染线程访问
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLConfig config = nullptr;
    ANativeWindow *window = nullptr;  // 持有引用，直到 detach
    bool hdr_static_applied = false;
    int32_t applied_dataspace = -1;
    int32_t surface_dataspace = kDataspaceSrgb;
    int width = 0;
    int height = 0;
    // 换 surface / 换 colorspace 后即使没有新帧也要重画一次，否则 PiP 缩放
    // 或 HDR 切换后画面会停在黑的缓冲区上。只在渲染线程读写。
    bool force_render = false;
    std::atomic<bool> gl_ready{false};
    bool has_pq_colorspace = false;
    bool has_hlg_colorspace = false;
    bool has_smpte2086_meta = false;
    bool has_cta861_meta = false;
};

void on_render_update(void *ctx) {
    auto *p = static_cast<Player *>(ctx);
    p->redraw.store(true, std::memory_order_release);
    p->cv.notify_one();
}

bool init_egl(Player *p) {
    if (p->display != EGL_NO_DISPLAY) {
        return true;
    }

    p->display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (p->display == EGL_NO_DISPLAY) {
        LOGE("eglGetDisplay 失败: 0x%x", eglGetError());
        return false;
    }
    if (!eglInitialize(p->display, nullptr, nullptr)) {
        LOGE("eglInitialize 失败: 0x%x", eglGetError());
        p->display = EGL_NO_DISPLAY;
        return false;
    }

    const char *exts = eglQueryString(p->display, EGL_EXTENSIONS);
    p->has_pq_colorspace = exts && strstr(exts, "EGL_EXT_gl_colorspace_bt2020_pq");
    p->has_hlg_colorspace = exts && strstr(exts, "EGL_EXT_gl_colorspace_bt2020_hlg");
    p->has_smpte2086_meta = exts && strstr(exts, "EGL_EXT_surface_SMPTE2086_metadata");
    p->has_cta861_meta = exts && strstr(exts, "EGL_EXT_surface_CTA861_3_metadata");
    if (exts) {
        LOGI("EGL 扩展: %.*s", 900, exts);
    }

    const EGLint attribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    EGLint num_configs = 0;
    if (!eglChooseConfig(p->display, attribs, &p->config, 1, &num_configs) || num_configs < 1) {
        LOGE("eglChooseConfig 失败: 0x%x", eglGetError());
        return false;
    }

    const EGLint ctx_attribs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
    p->context = eglCreateContext(p->display, p->config, EGL_NO_CONTEXT, ctx_attribs);
    if (p->context == EGL_NO_CONTEXT) {
        LOGE("eglCreateContext 失败: 0x%x", eglGetError());
        return false;
    }
    LOGI("EGL 就绪: %s · PQ colorspace %s · HLG colorspace %s",
         eglQueryString(p->display, EGL_VERSION), p->has_pq_colorspace ? "有" : "无",
         p->has_hlg_colorspace ? "有" : "无");
    return true;
}

void load_file(mpv_handle *mpv, const std::string &url) {
    const char *args[] = {"loadfile", url.c_str(), nullptr};
    int err = mpv_command(mpv, args);
    if (err < 0) {
        LOGE("loadfile 失败: %s", mpv_error_string(err));
    } else {
        LOGI("loadfile %s", url.c_str());
    }
}

bool create_render_context(Player *p) {
    if (p->render) {
        return true;
    }
    mpv_opengl_init_params init_params = {egl_proc_address, nullptr};
    int advanced = 1;
    const char *backend = "gpu-next";
    // 必须显式要 gpu-next：走默认探测时，gpu-next 初始化失败会被**静默**回退到
    // 老的 gpu 渲染器，而老渲染器会把 DV 映射剥掉（P5 直接渲染成绿紫），
    // HDR10+ / target-colorspace-hint 也不完整。失败时再用默认后端兜底，
    // 但会把原因打进日志。
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL)},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &init_params},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
        {MPV_RENDER_PARAM_RENDERER, const_cast<char *>(backend)},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    int err = mpv_render_context_create(&p->render, p->mpv, params);
    if (err < 0) {
        LOGE("mpv_render_context_create(gpu-next) 失败: %s", mpv_error_string(err));
        mpv_render_param fallback[] = {
            {MPV_RENDER_PARAM_API_TYPE, const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL)},
            {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &init_params},
            {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
            {MPV_RENDER_PARAM_INVALID, nullptr},
        };
        err = mpv_render_context_create(&p->render, p->mpv, fallback);
        if (err < 0) {
            LOGE("mpv_render_context_create 失败: %s", mpv_error_string(err));
            return false;
        }
        LOGE("已回退默认渲染后端（DV / HDR10+ 会不完整）");
    }
    mpv_render_context_set_update_callback(p->render, on_render_update, p);
    return true;
}

/** dataspace → EGL surface 的 GL colorspace。设备不支持时回退 SRGB。 */
EGLint egl_colorspace_for(Player *p, int32_t dataspace) {
    if (dataspace == kDataspaceBt2020Pq && p->has_pq_colorspace) {
        return EGL_GL_COLORSPACE_BT2020_PQ_EXT;
    }
    if (dataspace == kDataspaceBt2020Hlg && p->has_hlg_colorspace) {
        return EGL_GL_COLORSPACE_BT2020_HLG_EXT;
    }
    return EGL_GL_COLORSPACE_SRGB_KHR;
}

/** 用指定 colorspace 重建 EGLSurface（换窗口、切 HDR 都走这里）。 */
bool rebuild_surface(Player *p, EGLint colorspace) {
    if (!init_egl(p)) {
        return false;
    }
    if (!p->window) {
        return false;
    }

    if (p->surface != EGL_NO_SURFACE) {
        eglMakeCurrent(p->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroySurface(p->display, p->surface);
        p->surface = EGL_NO_SURFACE;
    }

    EGLint used_colorspace = colorspace;
    const EGLint attribs[] = {EGL_GL_COLORSPACE_KHR, colorspace, EGL_NONE};
    p->surface = eglCreateWindowSurface(p->display, p->config, p->window, attribs);
    if (p->surface == EGL_NO_SURFACE) {
        LOGE("eglCreateWindowSurface(colorspace 0x%x) 失败: 0x%x，回退 SRGB", colorspace,
             eglGetError());
        used_colorspace = EGL_GL_COLORSPACE_SRGB_KHR;
        const EGLint fallback[] = {EGL_GL_COLORSPACE_KHR, used_colorspace, EGL_NONE};
        p->surface = eglCreateWindowSurface(p->display, p->config, p->window, fallback);
        if (p->surface == EGL_NO_SURFACE) {
            // 有些实现（模拟器的 SwiftShader、部分老盒子）整个不认识
            // EGL_KHR_gl_colorspace：带这个属性一律 EGL_BAD_ATTRIBUTE。
            // 再不传属性创建一次，颜色按 surface 默认来，至少有画面。
            LOGE("回退 SRGB 也失败: 0x%x，改用无属性创建", eglGetError());
            p->surface = eglCreateWindowSurface(p->display, p->config, p->window, nullptr);
            if (p->surface == EGL_NO_SURFACE) {
                LOGE("无属性创建也失败: 0x%x", eglGetError());
                return false;
            }
            used_colorspace = 0;
        }
    }

    if (used_colorspace == EGL_GL_COLORSPACE_BT2020_PQ_EXT) {
        p->surface_dataspace = kDataspaceBt2020Pq;
    } else if (used_colorspace == EGL_GL_COLORSPACE_BT2020_HLG_EXT) {
        p->surface_dataspace = kDataspaceBt2020Hlg;
    } else {
        p->surface_dataspace = kDataspaceSrgb;
    }
    if (!eglMakeCurrent(p->display, p->surface, p->surface, p->context)) {
        LOGE("eglMakeCurrent 失败: 0x%x", eglGetError());
        return false;
    }

    p->applied_dataspace = -1;  // 强制重新设置 window dataspace
    p->hdr_static_applied = false;
    p->force_render = true;
    p->gl_ready.store(create_render_context(p), std::memory_order_release);
    p->redraw.store(true, std::memory_order_release);
    LOGI("EGLSurface 重建：colorspace 0x%x · %dx%d", colorspace, p->width, p->height);
    return p->gl_ready.load(std::memory_order_acquire);
}

/**
 * 把片源的静态 HDR 元数据挂到 EGLSurface 上（SMPTE2086 / CTA861_3 扩展）。
 * 元数据随 buffer 一起进 SurfaceFlinger，`dumpsys SurfaceFlinger --layers`
 * 能看到 hdr metadata types。动态 HDR10+ 不在这里：平台没有公开写入接口，
 * 只能走平台解码器（Media3）。
 * 返回 true 表示已经写入；false 会在下一帧重试（属性可能还没就绪）。
 */
bool apply_static_hdr(Player *p) {
    // PQ 与 HLG 都试：EGL_EXT_surface_SMPTE2086_metadata 在多数实现上只对
    // PQ surface 生效，HLG 写入会被忽略，但先写上去由显示端决定。
    if (p->surface_dataspace == kDataspaceSrgb || !p->hdr_passthrough.load()) {
        return false;
    }
    if (p->surface == EGL_NO_SURFACE || !p->has_smpte2086_meta) {
        return false;
    }

    // mpv 的属性读取是线程安全的，直接在渲染线程取当前值。
    auto read_prop = [p](const char *name) -> float {
        double value = 0.0;
        if (mpv_get_property(p->mpv, name, MPV_FORMAT_DOUBLE, &value) < 0) {
            return 0.0f;
        }
        return static_cast<float>(value);
    };
    const float max_luma = read_prop("video-params/max-luma");
    const float min_luma = read_prop("video-params/min-luma");
    const float max_cll = read_prop("video-params/max-cll");
    const float max_fall = read_prop("video-params/max-fall");
    if (!(max_luma > 0.0f)) {
        return false;
    }

    auto set_f = [p](EGLint attr, float value) {
        if (!eglSurfaceAttrib(p->display, p->surface, attr, float_bits(value))) {
            LOGW("eglSurfaceAttrib 0x%x 失败: 0x%x", attr, eglGetError());
        }
    };

    // BT.2020 主色 + D65。片源是 HDR10，这里报的就是容器色域。
    set_f(EGL_SMPTE2086_DISPLAY_PRIMARY_RX_EXT, 0.708f);
    set_f(EGL_SMPTE2086_DISPLAY_PRIMARY_RY_EXT, 0.292f);
    set_f(EGL_SMPTE2086_DISPLAY_PRIMARY_GX_EXT, 0.170f);
    set_f(EGL_SMPTE2086_DISPLAY_PRIMARY_GY_EXT, 0.797f);
    set_f(EGL_SMPTE2086_DISPLAY_PRIMARY_BX_EXT, 0.131f);
    set_f(EGL_SMPTE2086_DISPLAY_PRIMARY_BY_EXT, 0.046f);
    set_f(EGL_SMPTE2086_WHITE_POINT_X_EXT, 0.3127f);
    set_f(EGL_SMPTE2086_WHITE_POINT_Y_EXT, 0.3290f);
    set_f(EGL_SMPTE2086_MAX_LUMINANCE_EXT, max_luma);
    // min_luma 为 0 表示未知，用一个很小的正数表示「接近纯黑」。
    set_f(EGL_SMPTE2086_MIN_LUMINANCE_EXT, min_luma > 0.0f ? min_luma : 0.0001f);
    if (p->has_cta861_meta && (max_cll > 0.0f || max_fall > 0.0f)) {
        set_f(EGL_CTA861_3_MAX_CONTENT_LIGHT_LEVEL_EXT, max_cll);
        set_f(EGL_CTA861_3_MAX_FRAME_AVERAGE_LEVEL_EXT, max_fall);
    }
    LOGI("静态 HDR 元数据(EGL)：max=%.0f min=%.4f cll=%.0f fall=%.0f", max_luma, min_luma,
         max_cll, max_fall);
    return true;
}

/** 第一次拿到 window：存引用并建面。 */
bool install_window(Player *p, ANativeWindow *win, int w, int h) {
    if (p->window) {
        ANativeWindow_release(p->window);
    }
    p->window = win;
    p->width = w;
    p->height = h;
    return rebuild_surface(p, egl_colorspace_for(p, p->desired_dataspace.load()));
}

void release_surface(Player *p) {
    if (p->display == EGL_NO_DISPLAY) {
        return;
    }
    eglMakeCurrent(p->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (p->surface != EGL_NO_SURFACE) {
        eglDestroySurface(p->display, p->surface);
        p->surface = EGL_NO_SURFACE;
    }
    p->gl_ready.store(false, std::memory_order_release);
}

void draw_frame(Player *p) {
    if (!p->render || !p->gl_ready.load(std::memory_order_acquire)) {
        return;
    }
    if (!eglMakeCurrent(p->display, p->surface, p->surface, p->context)) {
        LOGE("渲染线程 makeCurrent 失败: 0x%x", eglGetError());
        return;
    }

    // dataspace 要在分配新 buffer 之前设好，新的一帧才会带 HDR 标记。
    const int32_t ds = p->surface_dataspace;
    if (p->window && ds != p->applied_dataspace) {
        auto fn = set_buffers_dataspace();
        if (fn) {
            int32_t err = fn(p->window, ds);
            if (err == 0) {
                p->applied_dataspace = ds;
                LOGI("window dataspace -> 0x%x", ds);
            } else {
                LOGW("setBuffersDataSpace(0x%x) 失败: %d", ds, err);
            }
        }
    }

    const uint64_t flags = mpv_render_context_update(p->render);
    // 新 surface 是未初始化的缓冲区；没有新帧时手动重画上一帧。
    if (!(flags & MPV_RENDER_UPDATE_FRAME) && !p->force_render) {
        return;
    }
    p->force_render = false;

    mpv_opengl_fbo fbo{0, p->width, p->height, 0};
    int flip_y = 1;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
        {MPV_RENDER_PARAM_FLIP_Y, &flip_y},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    int err = mpv_render_context_render(p->render, params);
    if (err < 0) {
        LOGE("mpv_render_context_render 失败: %s", mpv_error_string(err));
        return;
    }
    // 静态元数据要在 swap 之前挂到 EGLSurface 上，才会随这一帧的 buffer 走。
    // 属性还没就绪（max_luma 为 0）时返回 false，下一帧再试。
    if (!p->hdr_static_applied && p->surface_dataspace != kDataspaceSrgb &&
        p->hdr_passthrough.load(std::memory_order_acquire)) {
        p->hdr_static_applied = apply_static_hdr(p);
    }
    eglSwapBuffers(p->display, p->surface);
    // advanced control 打开时必须报告 swap，否则 mpv 的帧调度会停摆。
    mpv_render_context_report_swap(p->render);

    static int frames = 0;
    if (frames < 3) {
        ++frames;
        LOGI("渲染第 %d 帧 flags=0x%llx dataspace=0x%x", frames,
             static_cast<unsigned long long>(flags), p->applied_dataspace);
    }
}

void render_loop(Player *p) {
    std::unique_lock<std::mutex> lock(p->mu);
    while (!p->quit) {
        p->cv.wait(lock, [p] {
            return p->quit || p->pending_window != nullptr || p->detach_requested ||
                   p->surface_dirty.load(std::memory_order_acquire) ||
                   p->redraw.load(std::memory_order_acquire);
        });
        if (p->quit) {
            break;
        }

        ANativeWindow *win = p->pending_window;
        p->pending_window = nullptr;
        const int w = p->pending_width;
        const int h = p->pending_height;
        const bool detach = p->detach_requested;
        const bool colorspace_change = p->surface_dirty.exchange(false);
        p->detach_requested = false;
        p->redraw.store(false, std::memory_order_release);
        lock.unlock();

        if (detach) {
            if (win) {
                ANativeWindow_release(win);
            }
            release_surface(p);
            if (p->window) {
                ANativeWindow_release(p->window);
                p->window = nullptr;
            }
        } else if (win != nullptr) {
            install_window(p, win, w, h);
            std::string pending;
            {
                std::lock_guard<std::mutex> guard(p->mu);
                if (p->has_pending) {
                    pending.swap(p->pending_file);
                    p->has_pending = false;
                }
            }
            if (!pending.empty()) {
                load_file(p->mpv, pending);
            }
        } else if (colorspace_change && p->window) {
            rebuild_surface(p, egl_colorspace_for(p, p->desired_dataspace.load()));
        }

        draw_frame(p);
        lock.lock();
    }
    lock.unlock();

    // render context 必须在创建它的 GL 线程、且 GL 上下文 current 时释放，
    // 否则它自己申请的 GL 对象没机会销毁。
    if (p->render) {
        if (p->display != EGL_NO_DISPLAY && p->surface != EGL_NO_SURFACE) {
            eglMakeCurrent(p->display, p->surface, p->surface, p->context);
        }
        mpv_render_context_free(p->render);
        p->render = nullptr;
    }
}

int32_t pick_dataspace(const std::string &primaries, const std::string &gamma) {
    const bool bt2020 = primaries == "bt.2020" || primaries == "bt2020";
    if (bt2020 && gamma == "pq") {
        return kDataspaceBt2020Pq;
    }
    if (bt2020 && gamma == "hlg") {
        return kDataspaceBt2020Hlg;
    }
    return kDataspaceSrgb;
}

void update_colorspace(Player *p) {
    std::string prim;
    std::string g;
    {
        std::lock_guard<std::mutex> lock(p->mu);
        prim = p->primaries;
        g = p->gamma;
    }
    const int32_t ds = p->hdr_passthrough.load(std::memory_order_acquire)
                           ? pick_dataspace(prim, g)
                           : kDataspaceSrgb;
    if (ds != p->desired_dataspace.load(std::memory_order_acquire)) {
        p->desired_dataspace.store(ds, std::memory_order_release);
        p->surface_dirty.store(true, std::memory_order_release);
        LOGI("色彩空间变化：prim=%s gamma=%s hdr=%s -> dataspace 0x%x", prim.c_str(), g.c_str(),
             p->hdr_passthrough.load() ? "on" : "sdr", ds);
        p->cv.notify_one();
    }
}

void event_loop(Player *p) {
    while (true) {
        mpv_event *ev = mpv_wait_event(p->mpv, -1);
        switch (ev->event_id) {
        case MPV_EVENT_NONE:
            break;
        case MPV_EVENT_SHUTDOWN:
            LOGI("mpv 已 shutdown");
            return;
        case MPV_EVENT_LOG_MESSAGE: {
            auto *msg = static_cast<mpv_event_log_message *>(ev->data);
            __android_log_print(ANDROID_LOG_INFO, LOG_TAG, "[%s] %s", msg->prefix,
                                msg->text);
            break;
        }
        case MPV_EVENT_END_FILE: {
            auto *end = static_cast<mpv_event_end_file *>(ev->data);
            LOGI("播放结束: reason=%d error=%s", end->reason,
                 end->error < 0 ? mpv_error_string(end->error) : "none");
            break;
        }
        case MPV_EVENT_FILE_LOADED: {
            char *vo = mpv_get_property_string(p->mpv, "current-vo");
            char *hwdec = mpv_get_property_string(p->mpv, "hwdec-current");
            char *pixfmt = mpv_get_property_string(p->mpv, "video-params/pixelformat");
            char *prim = mpv_get_property_string(p->mpv, "video-params/primaries");
            char *gamma = mpv_get_property_string(p->mpv, "video-params/gamma");
            LOGI("file loaded: vo=%s hwdec=%s pixfmt=%s prim=%s gamma=%s", vo ? vo : "?",
                 hwdec ? hwdec : "?", pixfmt ? pixfmt : "?", prim ? prim : "?",
                 gamma ? gamma : "?");
            mpv_free(vo);
            mpv_free(hwdec);
            mpv_free(pixfmt);
            mpv_free(prim);
            mpv_free(gamma);
            break;
        }
        case MPV_EVENT_PROPERTY_CHANGE: {
            auto *prop = static_cast<mpv_event_property *>(ev->data);
            if (prop->format != MPV_FORMAT_STRING || !prop->data) {
                break;
            }
            const char *value = *static_cast<char **>(prop->data);
            {
                std::lock_guard<std::mutex> lock(p->mu);
                if (strcmp(prop->name, "video-params/primaries") == 0) {
                    p->primaries = value ? value : "";
                } else if (strcmp(prop->name, "video-params/gamma") == 0) {
                    p->gamma = value ? value : "";
                }
            }
            update_colorspace(p);
            break;
        }
        default:
            break;
        }
    }
}

void set_option(mpv_handle *mpv, const char *name, const char *value) {
    int err = mpv_set_option_string(mpv, name, value);
    if (err < 0) {
        LOGW("option %s=%s 失败: %s", name, value, mpv_error_string(err));
    }
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_dvplayer_player_mpv_MpvNative_create(JNIEnv *, jobject, jboolean verbose) {
    auto *p = new Player();
    p->mpv = mpv_create();
    if (!p->mpv) {
        LOGE("mpv_create 失败");
        delete p;
        return 0;
    }

    // 只保留一条渲染路径：OpenGL ES。直通 / 硬解由 A6 之后的策略决定。
    set_option(p->mpv, "config", "no");
    set_option(p->mpv, "terminal", "no");
    set_option(p->mpv, "idle", "yes");
    set_option(p->mpv, "vo", "libmpv");
    set_option(p->mpv, "gpu-api", "opengl");
    set_option(p->mpv, "hwdec", "auto-safe");
    // A5：把片源的色彩空间（PQ / BT.2020）交给显示端，不做 tone mapping。
    set_option(p->mpv, "target-colorspace-hint", "yes");
    // ffmpeg 的 https 走静态 mbedTLS。Android 的系统 CA 不在 mbedTLS 的默认
    // 路径里，开校验会让所有 https 直接失败；局域网 NAS 也多为自签证书。
    // 所以默认不校验，需要时用 tls-ca-file（源级开关待接）。
    set_option(p->mpv, "tls-verify", "no");
    set_option(p->mpv, "msg-level", verbose ? "all=v" : "all=warn");

    // libmpv 默认不产生日志事件；默认只要 warn（错误与告警），排障时用 verbose。
    // msg-level 是 pre-parse 选项，只能在 initialize 之前定，不能运行期改。
    mpv_request_log_messages(p->mpv, verbose ? "v" : "warn");

    int err = mpv_initialize(p->mpv);
    if (err < 0) {
        LOGE("mpv_initialize 失败: %s", mpv_error_string(err));
        mpv_terminate_destroy(p->mpv);
        delete p;
        return 0;
    }

    // 色彩属性变化会驱动 EGLSurface / dataspace 切换。
    mpv_observe_property(p->mpv, 1, "video-params/primaries", MPV_FORMAT_STRING);
    mpv_observe_property(p->mpv, 2, "video-params/gamma", MPV_FORMAT_STRING);

    p->event_thread = std::thread(event_loop, p);
    p->render_thread = std::thread(render_loop, p);
    char *version = mpv_get_property_string(p->mpv, "mpv-version");
    LOGI("%s", version ? version : "mpv ?");
    mpv_free(version);
    return reinterpret_cast<jlong>(p);
}

JNIEXPORT void JNICALL
Java_com_dvplayer_player_mpv_MpvNative_attach(JNIEnv *env, jobject, jlong handle,
                                              jobject jsurface, jint width, jint height) {
    auto *p = reinterpret_cast<Player *>(handle);
    if (!p) {
        return;
    }
    ANativeWindow *win = ANativeWindow_fromSurface(env, jsurface);
    if (!win) {
        LOGE("ANativeWindow_fromSurface 失败");
        return;
    }

    {
        std::lock_guard<std::mutex> lock(p->mu);
        if (p->pending_window) {
            ANativeWindow_release(p->pending_window);
        }
        p->pending_window = win;
        p->pending_width = width;
        p->pending_height = height;
    }
    p->cv.notify_one();
}

JNIEXPORT void JNICALL
Java_com_dvplayer_player_mpv_MpvNative_detach(JNIEnv *, jobject, jlong handle) {
    auto *p = reinterpret_cast<Player *>(handle);
    if (!p) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(p->mu);
        p->detach_requested = true;
    }
    p->cv.notify_one();
}

JNIEXPORT void JNICALL
Java_com_dvplayer_player_mpv_MpvNative_play(JNIEnv *env, jobject, jlong handle, jstring jurl) {
    auto *p = reinterpret_cast<Player *>(handle);
    if (!p) {
        return;
    }
    const char *url = env->GetStringUTFChars(jurl, nullptr);
    std::string copy(url);
    env->ReleaseStringUTFChars(jurl, url);

    // GL 还没就绪就先攒着；install_window 建好 render context 后会加载。
    // 判断和暂存都放在 p->mu 里：否则可能出现「渲染线程刚建好 context、
    // 检查完 has_pending 之后，我们才写入 pending_file」的窗口，文件就不加载了。
    {
        std::lock_guard<std::mutex> lock(p->mu);
        if (!p->gl_ready.load(std::memory_order_acquire)) {
            p->pending_file = copy;
            p->has_pending = true;
            LOGI("GL 未就绪，暂存 %s", copy.c_str());
            return;
        }
    }
    load_file(p->mpv, copy);
}

JNIEXPORT jstring JNICALL
Java_com_dvplayer_player_mpv_MpvNative_command(JNIEnv *env, jobject, jlong handle,
                                                jobjectArray jargs) {
    auto *p = reinterpret_cast<Player *>(handle);
    if (!p) {
        return env->NewStringUTF("handle 为空");
    }

    const jsize count = env->GetArrayLength(jargs);
    std::vector<const char *> args;
    args.reserve(static_cast<size_t>(count) + 1);
    for (jsize i = 0; i < count; ++i) {
        auto *s = static_cast<jstring>(env->GetObjectArrayElement(jargs, i));
        args.push_back(env->GetStringUTFChars(s, nullptr));
        env->DeleteLocalRef(s);
    }
    args.push_back(nullptr);

    int err = mpv_command(p->mpv, args.data());
    for (jsize i = 0; i < count; ++i) {
        auto *s = static_cast<jstring>(env->GetObjectArrayElement(jargs, i));
        env->ReleaseStringUTFChars(s, args[static_cast<size_t>(i)]);
        env->DeleteLocalRef(s);
    }

    if (err < 0) {
        return env->NewStringUTF(mpv_error_string(err));
    }
    return nullptr;
}

JNIEXPORT jstring JNICALL
Java_com_dvplayer_player_mpv_MpvNative_setProperty(JNIEnv *env, jobject, jlong handle,
                                                    jstring jname, jstring jvalue) {
    auto *p = reinterpret_cast<Player *>(handle);
    if (!p) {
        return env->NewStringUTF("handle 为空");
    }
    const char *name = env->GetStringUTFChars(jname, nullptr);
    const char *value = env->GetStringUTFChars(jvalue, nullptr);
    int err = mpv_set_property_string(p->mpv, name, value);
    env->ReleaseStringUTFChars(jname, name);
    env->ReleaseStringUTFChars(jvalue, value);
    if (err < 0) {
        return env->NewStringUTF(mpv_error_string(err));
    }
    return nullptr;
}

JNIEXPORT jstring JNICALL
Java_com_dvplayer_player_mpv_MpvNative_getProperty(JNIEnv *env, jobject, jlong handle,
                                                    jstring jname) {
    auto *p = reinterpret_cast<Player *>(handle);
    if (!p) {
        return nullptr;
    }
    const char *name = env->GetStringUTFChars(jname, nullptr);
    char *value = mpv_get_property_string(p->mpv, name);
    env->ReleaseStringUTFChars(jname, name);
    if (!value) {
        return nullptr;
    }
    jstring result = env->NewStringUTF(value);
    mpv_free(value);
    return result;
}

JNIEXPORT void JNICALL
Java_com_dvplayer_player_mpv_MpvNative_setHdrPassthrough(JNIEnv *, jobject, jlong handle,
                                                         jboolean enabled) {
    auto *p = reinterpret_cast<Player *>(handle);
    if (!p) {
        return;
    }
    const bool on = enabled == JNI_TRUE;
    p->hdr_passthrough.store(on, std::memory_order_release);
    int err = 0;
    if (on) {
        // 回到直出：把片源的 PQ / HLG 交给显示端，不做 tone mapping。
        err |= mpv_set_property_string(p->mpv, "target-colorspace-hint", "yes");
        err |= mpv_set_property_string(p->mpv, "target-prim", "auto");
        err |= mpv_set_property_string(p->mpv, "target-trc", "auto");
    } else {
        // 回退 SDR：mpv 的 gpu VO 按 BT.709 / bt.1886 做 tone mapping。
        err |= mpv_set_property_string(p->mpv, "target-colorspace-hint", "no");
        err |= mpv_set_property_string(p->mpv, "target-prim", "bt.709");
        err |= mpv_set_property_string(p->mpv, "target-trc", "bt.1886");
        err |= mpv_set_property_string(p->mpv, "tone-mapping", "auto");
        err |= mpv_set_property_string(p->mpv, "hdr-compute-peak", "yes");
    }
    // 属性本身没变，需要主动重算一次 dataspace 并重建 surface。
    update_colorspace(p);
    p->redraw.store(true, std::memory_order_release);
    p->cv.notify_one();
    LOGI("HDR 直出 -> %s（option err=%d）", on ? "on" : "SDR tone mapping", err);
}

JNIEXPORT void JNICALL
Java_com_dvplayer_player_mpv_MpvNative_destroy(JNIEnv *, jobject, jlong handle) {
    auto *p = reinterpret_cast<Player *>(handle);
    if (!p) {
        return;
    }

    {
        std::lock_guard<std::mutex> lock(p->mu);
        p->quit = true;
        if (p->pending_window) {
            ANativeWindow_release(p->pending_window);
            p->pending_window = nullptr;
        }
    }
    p->cv.notify_all();
    LOGI("destroy: 等渲染线程");
    if (p->render_thread.joinable()) {
        p->render_thread.join();
    }
    LOGI("destroy: 渲染线程已退出");

    // render context 已经在渲染线程里释放掉了，这里只收 EGL 的尾。
    if (p->display != EGL_NO_DISPLAY) {
        release_surface(p);
        eglDestroyContext(p->display, p->context);
        eglTerminate(p->display);
        p->display = EGL_NO_DISPLAY;
    }
    if (p->window) {
        ANativeWindow_release(p->window);
        p->window = nullptr;
    }

    LOGI("destroy: 释放 mpv");
    mpv_terminate_destroy(p->mpv);
    LOGI("destroy: 等事件线程");
    if (p->event_thread.joinable()) {
        p->event_thread.join();
    }
    LOGI("destroy: 完成");
    delete p;
}

}  // extern "C"
