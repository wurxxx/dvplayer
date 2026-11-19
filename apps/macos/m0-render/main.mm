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

@interface MpvView : NSOpenGLView
@property(nonatomic) mpv_handle* mpv;
@property(nonatomic) mpv_render_context* render;
@end

@implementation MpvView

- (instancetype)initWithFrame:(NSRect)frame {
    NSOpenGLPixelFormatAttribute attrs[] = {
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
    mpv_set_option_string(h, "hwdec", "no");
    mpv_set_option_string(h, "osc", "no");
    mpv_set_option_string(h, "input-default-bindings", "no");
    mpv_set_option_string(h, "input-vo-keyboard", "no");
    mpv_set_option_string(h, "keep-open", "yes");
    mpv_set_option_string(h, "terminal", "yes");
    mpv_set_option_string(h, "msg-level", "all=info");
    if (mpv_initialize(h) < 0) {
        fprintf(stderr, "mpv_initialize failed\n");
        exit(1);
    }
    mpv_request_log_messages(h, "info");

    mpv_opengl_init_params gl_init = {
        .get_proc_address = get_proc_address,
        .get_proc_address_ctx = nullptr,
    };
    int advanced = 1;
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
        while (h) {
            mpv_event* ev = mpv_wait_event(h, 1.0);
            if (!ev) continue;
            if (ev->event_id == MPV_EVENT_NONE) continue;
            if (ev->event_id == MPV_EVENT_SHUTDOWN) break;
            if (ev->event_id == MPV_EVENT_FILE_LOADED) {
                char* vp = mpv_get_property_string(h, "video-params");
                char* dv = mpv_get_property_string(h, "dolby-vision-profile");
                fprintf(stdout, "[file-loaded]\n  video-params: %s\n  dv-profile: %s\n",
                        vp ? vp : "-", dv ? dv : "-");
                fflush(stdout);
                mpv_free(vp);
                mpv_free(dv);
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
        fprintf(stdout, "[done] %.1fs\n", seconds);
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
