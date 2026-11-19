// m0-render: 最小 libmpv render API 验证程序（macOS）
//
// 目的：证明 render API + OpenGL + legacy gpu 能在 macOS 上正确出画，
// 并打印 DV profile / 像素格式 / 帧率，供 A3 验收。
#import <Cocoa/Cocoa.h>
#import <OpenGL/gl.h>
#import <OpenGL/OpenGL.h>

#include <mpv/client.h>
#include <mpv/render_gl.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

static void* get_proc_address(void* /*ctx*/, const char* name) {
    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengl"));
    if (!bundle) return nullptr;
    CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
    void* p = s ? CFBundleGetFunctionPointerForName(bundle, s) : nullptr;
    if (s) CFRelease(s);
    return p;
}

static void on_mpv_update(void* ctx);

static long g_draws = 0;

// mpv 0.42 没有 dolby-vision-profile 属性：
// DV 只能靠 video-params/colormatrix=dolbyvision 判断，
// profile 与 EL 类型要自己解析 RPU（见 core/dovi）。
static const char* const k_probe_names[] = {
    "video-params/w",
    "video-params/h",
    "video-params/pixelformat",
    "video-params/colormatrix",
    "video-params/primaries",
    "video-params/gamma",
    "video-params/sig-peak",
    "video-codec",
    "estimated-frame-number",
    "decoder-frame-drop-count",
    "vo-drop-frame-count",
    "vo-configured",
    nullptr,
};

@interface MpvView : NSOpenGLView
@property(nonatomic) mpv_handle* mpv;
@property(nonatomic) mpv_render_context* render;
@end

@implementation MpvView

- (instancetype)initWithFrame:(NSRect)frame {
    NSOpenGLPixelFormatAttribute attrs[] = {
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersion3_2Core,
        NSOpenGLPFAAccelerated,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize, 24,
        NSOpenGLPFAAlphaSize, 8,
        NSOpenGLPFADepthSize, 0,
        0,
    };
    NSOpenGLPixelFormat* pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
    if (!pf) return nil;
    self = [super initWithFrame:frame pixelFormat:pf];
    return self;
}

- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)prepareOpenGL {
    [super prepareOpenGL];
    [[self openGLContext] makeCurrentContext];
    GLint swap = 1;
    [[self openGLContext] setValues:&swap forParameter:NSOpenGLContextParameterSwapInterval];

    mpv_handle* h = mpv_create();
    if (!h) {
        fprintf(stderr, "mpv_create failed\n");
        exit(1);
    }
    mpv_set_option_string(h, "vo", "libmpv");
    mpv_set_option_string(h, "hwdec", getenv("HWDEC") ? getenv("HWDEC") : "no");
    mpv_set_option_string(h, "osc", "no");
    mpv_set_option_string(h, "input-default-bindings", "no");
    mpv_set_option_string(h, "input-vo-keyboard", "no");
    mpv_set_option_string(h, "keep-open", "yes");
    mpv_set_option_string(h, "terminal", "yes");
    mpv_set_option_string(h, "msg-level",
                          getenv("MPV_MSGLVL") ? getenv("MPV_MSGLVL") : "all=info");

    // MPV_EXTRA：额外的 mpv 选项，用来做对比实验，例如
    //   MPV_EXTRA='tone-mapping=clip;vf=format:colormatrix=bt.2020-ncl'
    // 多个选项用 ';' 分隔，每个都是 name=value。
    if (const char* extra = getenv("MPV_EXTRA")) {
        std::string s(extra);
        size_t pos = 0;
        while (pos <= s.size()) {
            size_t end = s.find(';', pos);
            if (end == std::string::npos) end = s.size();
            std::string item = s.substr(pos, end - pos);
            size_t eq = item.find('=');
            if (eq != std::string::npos && eq > 0) {
                std::string name = item.substr(0, eq);
                std::string value = item.substr(eq + 1);
                if (mpv_set_option_string(h, name.c_str(), value.c_str()) < 0)
                    fprintf(stderr, "[MPV_EXTRA] 设置失败: %s=%s\n", name.c_str(), value.c_str());
                else
                    fprintf(stdout, "[MPV_EXTRA] %s=%s\n", name.c_str(), value.c_str());
            }
            pos = end + 1;
        }
    }

    if (mpv_initialize(h) < 0) {
        fprintf(stderr, "mpv_initialize failed\n");
        exit(1);
    }
    mpv_request_log_messages(h, "info");

    // 用观察代替主动读取：跨线程 mpv_get_property 会卡住，
    // observe 的回调直接带值，事件线程里打印即可。
    for (int i = 0; k_probe_names[i]; i++)
        mpv_observe_property(h, 100 + i, k_probe_names[i], MPV_FORMAT_STRING);

    mpv_opengl_init_params gl_init = {
        .get_proc_address = get_proc_address,
        .get_proc_address_ctx = nullptr,
    };
    // 先不用 advanced control：它要求精确的 update/report_swap 节奏，
    // 这里的 drawRect 驱动模型用普通模式更稳。
    int advanced = 0;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, const_cast<char*>(MPV_RENDER_API_TYPE_OPENGL)},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    if (mpv_render_context_create(&_render, h, params) < 0) {
        fprintf(stderr, "mpv_render_context_create failed\n");
        exit(1);
    }
    mpv_render_context_set_update_callback(_render, on_mpv_update, (__bridge void*)self);

    self.mpv = h;

    // 事件线程
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char* g_last_value[sizeof(k_probe_names) / sizeof(k_probe_names[0])] = {0};
        bool header = false;
        while (h) {
            mpv_event* ev = mpv_wait_event(h, 1.0);
            if (!ev) continue;
            if (ev->event_id == MPV_EVENT_SHUTDOWN) break;
            if (ev->event_id == MPV_EVENT_PROPERTY_CHANGE) {
                mpv_event_property* p = (mpv_event_property*)ev->data;
                if (p && p->name && p->format == MPV_FORMAT_STRING && p->data) {
                    int idx = (int)ev->reply_userdata - 100;
                    if (idx >= 0 && idx < (int)(sizeof(g_last_value) / sizeof(g_last_value[0]))) {
                        if (!header) {
                            fprintf(stdout, "[probe]\n");
                            header = true;
                        }
                        const char* v = *(char**)p->data;
                        char* last = g_last_value[idx];
                        if (!last || !v || strcmp(last, v) != 0) {
                            free(g_last_value[idx]);
                            g_last_value[idx] = v ? strdup(v) : nullptr;
                            fprintf(stdout, "  %-28s %s\n", p->name, v ? v : "-");
                            fflush(stdout);
                        }
                    }
                }
            }
            if (ev->event_id == MPV_EVENT_LOG_MESSAGE) {
                mpv_event_log_message* m = (mpv_event_log_message*)ev->data;
                if (m && m->text) {
                    fputs(m->text, stdout);
                    fflush(stdout);
                }
            }
        }
    });
}

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    if (!_render) return;
    g_draws++;
    [[self openGLContext] makeCurrentContext];

    NSRect backing = [self convertRectToBacking:[self bounds]];
    mpv_opengl_fbo fbo = {
        .fbo = 0,
        .w = (int)backing.size.width,
        .h = (int)backing.size.height,
        .internal_format = 0,
    };
    int flip = 1;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_OPENGL_FBO, &fbo},
        {MPV_RENDER_PARAM_FLIP_Y, &flip},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    mpv_render_context_render(_render, params);
    [[self openGLContext] flushBuffer];
    mpv_render_context_report_swap(_render);
}

- (void)keyDown:(NSEvent*)event {
    if ([[event charactersIgnoringModifiers] isEqualToString:@"q"]) {
        [NSApp terminate:nil];
    } else if ([[event charactersIgnoringModifiers] isEqualToString:@" "]) {
        mpv_command_string(_mpv, "cycle pause");
    } else {
        [super keyDown:event];
    }
}

- (void)dealloc {
    if (_render) {
        mpv_render_context_free(_render);
        _render = nullptr;
    }
    if (_mpv) {
        mpv_terminate_destroy(_mpv);
        _mpv = nullptr;
    }
}

@end

static void on_mpv_update(void* ctx) {
    MpvView* view = (__bridge MpvView*)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view setNeedsDisplay:YES];
    });
}

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic) NSWindow* window;
@property(nonatomic) MpvView* view;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)note {
    (void)note;
    NSRect rect = NSMakeRect(0, 0, 1280, 720);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                              NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable;
    _window = [[NSWindow alloc] initWithContentRect:rect
                                          styleMask:style
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    [_window setTitle:@"dvplayer m0-render"];
    _view = [[MpvView alloc] initWithFrame:rect];
    [_window setContentView:_view];
    [_window makeKeyAndOrderFront:nil];
    [_window center];
    [NSApp activateIgnoringOtherApps:YES];
    [_window makeFirstResponder:_view];

    NSArray* args = [[NSProcessInfo processInfo] arguments];
    if (args.count < 2) {
        fprintf(stderr, "usage: m0-render <file> [seconds]\n");
        [NSApp terminate:nil];
        return;
    }
    NSString* path = args[1];
    double seconds = args.count >= 3 ? [args[2] doubleValue] : 10.0;

    // 等渲染上下文建好再 loadfile
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        const char* cmd[] = {"loadfile", [path UTF8String], nullptr};
        int rc = mpv_command(self.view.mpv, cmd);
        fprintf(stdout, "[loadfile] rc=%d path=%s\n", rc, [path UTF8String]);
        fflush(stdout);
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        fprintf(stdout, "[done] %.1fs draws=%ld\n", seconds, g_draws);
        fflush(stdout);
        [NSApp terminate:nil];
    });
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    (void)sender;
    return YES;
}

@end

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        AppDelegate* delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
