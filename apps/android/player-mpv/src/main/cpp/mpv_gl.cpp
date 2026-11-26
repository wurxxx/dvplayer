// libmpv + EGL/OpenGL ES 最小渲染层（A4 的第一步）。
//
// 结构：
//   - mpv 的 event 线程独立跑（mpv_wait_event 会阻塞）；
//   - EGLDisplay / EGLContext / EGLSurface 与 mpv_render_context 全部归渲染线程所有，
//     attach/detach 只是把 Surface 投递给渲染线程，避免跨线程 makeCurrent；
//   - mpv_render_context 的 update 回调只置标志 + 唤醒，真正绘制在渲染线程里。
#include <jni.h>

#include <android/log.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#include <EGL/egl.h>
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

void *egl_proc_address(void *ctx, const char *name) {
    (void)ctx;
    return reinterpret_cast<void *>(eglGetProcAddress(name));
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

    // 以下只允许渲染线程访问
    EGLDisplay display = EGL_NO_DISPLAY;
    EGLContext context = EGL_NO_CONTEXT;
    EGLSurface surface = EGL_NO_SURFACE;
    EGLConfig config = nullptr;
    int width = 0;
    int height = 0;
    std::atomic<bool> gl_ready{false};
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
    LOGI("EGL 就绪: %s", eglQueryString(p->display, EGL_VERSION));
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
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL)},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &init_params},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    int err = mpv_render_context_create(&p->render, p->mpv, params);
    if (err < 0) {
        LOGE("mpv_render_context_create 失败: %s", mpv_error_string(err));
        return false;
    }
    mpv_render_context_set_update_callback(p->render, on_render_update, p);
    return true;
}

// 换窗口：只重建 EGLSurface，display / context / render context 复用。
bool install_window(Player *p, ANativeWindow *win, int w, int h) {
    if (!init_egl(p)) {
        ANativeWindow_release(win);
        return false;
    }

    if (p->surface != EGL_NO_SURFACE) {
        eglMakeCurrent(p->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        eglDestroySurface(p->display, p->surface);
        p->surface = EGL_NO_SURFACE;
    }

    p->surface = eglCreateWindowSurface(p->display, p->config, win, nullptr);
    ANativeWindow_release(win);
    if (p->surface == EGL_NO_SURFACE) {
        LOGE("eglCreateWindowSurface 失败: 0x%x", eglGetError());
        return false;
    }
    if (!eglMakeCurrent(p->display, p->surface, p->surface, p->context)) {
        LOGE("eglMakeCurrent 失败: 0x%x", eglGetError());
        return false;
    }

    p->width = w;
    p->height = h;
    p->gl_ready.store(create_render_context(p), std::memory_order_release);
    p->redraw.store(true, std::memory_order_release);
    LOGI("Surface %dx%d 就绪", w, h);

    if (p->gl_ready.load(std::memory_order_acquire)) {
        std::string pending;
        {
            std::lock_guard<std::mutex> lock(p->mu);
            if (p->has_pending) {
                pending.swap(p->pending_file);
                p->has_pending = false;
            }
        }
        if (!pending.empty()) {
            load_file(p->mpv, pending);
        }
    }
    return p->gl_ready.load(std::memory_order_acquire);
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

    const uint64_t flags = mpv_render_context_update(p->render);
    if (!(flags & MPV_RENDER_UPDATE_FRAME)) {
        return;
    }

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
    eglSwapBuffers(p->display, p->surface);
    // advanced control 打开时必须报告 swap，否则 mpv 的帧调度会停摆。
    mpv_render_context_report_swap(p->render);

    static int frames = 0;
    if (frames < 3) {
        ++frames;
        LOGI("渲染第 %d 帧 flags=0x%llx gl=%s", frames,
             static_cast<unsigned long long>(flags), glGetString(GL_VERSION));
    }
}

void render_loop(Player *p) {
    std::unique_lock<std::mutex> lock(p->mu);
    while (!p->quit) {
        p->cv.wait(lock, [p] {
            return p->quit || p->pending_window != nullptr || p->detach_requested ||
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
        p->detach_requested = false;
        p->redraw.store(false, std::memory_order_release);
        lock.unlock();

        if (win != nullptr) {
            install_window(p, win, w, h);
        }
        if (detach) {
            release_surface(p);
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
            char *configured = mpv_get_property_string(p->mpv, "vo-configured");
            char *hwdec = mpv_get_property_string(p->mpv, "hwdec-current");
            char *pixfmt = mpv_get_property_string(p->mpv, "video-params/pixelformat");
            LOGI("file loaded: vo=%s configured=%s hwdec=%s pixfmt=%s", vo ? vo : "?",
                 configured ? configured : "?", hwdec ? hwdec : "?",
                 pixfmt ? pixfmt : "?");
            mpv_free(vo);
            mpv_free(configured);
            mpv_free(hwdec);
            mpv_free(pixfmt);
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
Java_com_dvplayer_player_mpv_MpvNative_create(JNIEnv *, jobject) {
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
    set_option(p->mpv, "msg-level", "all=warn");

    int err = mpv_initialize(p->mpv);
    if (err < 0) {
        LOGE("mpv_initialize 失败: %s", mpv_error_string(err));
        mpv_terminate_destroy(p->mpv);
        delete p;
        return 0;
    }

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
    if (!p->gl_ready.load(std::memory_order_acquire)) {
        std::lock_guard<std::mutex> lock(p->mu);
        p->pending_file = copy;
        p->has_pending = true;
        LOGI("GL 未就绪，暂存 %s", copy.c_str());
        return;
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
    if (p->render_thread.joinable()) {
        p->render_thread.join();
    }

    // render context 已经在渲染线程里释放掉了，这里只收 EGL 的尾。
    if (p->display != EGL_NO_DISPLAY) {
        release_surface(p);
        eglDestroyContext(p->display, p->context);
        eglTerminate(p->display);
        p->display = EGL_NO_DISPLAY;
    }

    mpv_terminate_destroy(p->mpv);
    if (p->event_thread.joinable()) {
        p->event_thread.join();
    }
    delete p;
}

}  // extern "C"
