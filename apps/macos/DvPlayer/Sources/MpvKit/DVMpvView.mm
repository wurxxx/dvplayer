// macOS 的 libmpv 渲染封装。
//
// 和 Windows 那边的「mpv 自己开窗口」不同，macOS 走 render API：
// mpv 只负责解码，把画面画进我们的 NSOpenGLView，SwiftUI 的浮层再叠在上面。
// 这是 m0-render 验证过的路径（advanced-control=0 + OpenGL 3.2 core）。

#import "MpvKit.h"

#import <CoreVideo/CoreVideo.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#import <QuartzCore/QuartzCore.h>

#include <mpv/client.h>
#include <mpv/render_gl.h>

#include <cstdio>
#include <cstring>

#pragma mark - 小工具

static void *DVGetProcAddress(void *ctx, const char *name) {
    (void)ctx;
    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.opengl"));
    if (!bundle) return nullptr;
    CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
    void *p = s ? CFBundleGetFunctionPointerForName(bundle, s) : nullptr;
    if (s) CFRelease(s);
    return p;
}

static void DVUpdateCallback(void *ctx);

/// 需要观察的 mpv 属性。格式在 prepareOpenGL 里按名字挑。
static const char *const kObservedProperties[] = {
    "time-pos", "duration", "pause", "eof-reached", "speed", "volume", "mute",
    "track-list", "aid", "sid", nullptr,
};

/// node 里取字段：只处理 track-list 需要的 map 结构。
static mpv_node *DVNodeField(mpv_node *map, const char *key) {
    if (!map || map->format != MPV_FORMAT_NODE_MAP || !map->u.list) return nullptr;
    for (int i = 0; i < map->u.list->num; i++) {
        const char *name = map->u.list->keys[i];
        if (name && strcmp(name, key) == 0) return &map->u.list->values[i];
    }
    return nullptr;
}

static NSString *DVNodeString(mpv_node *node) {
    if (!node) return @"";
    if (node->format == MPV_FORMAT_STRING && node->u.string) return @(node->u.string);
    if (node->format == MPV_FORMAT_INT64) return [NSString stringWithFormat:@"%lld", node->u.int64];
    if (node->format == MPV_FORMAT_DOUBLE) return [NSString stringWithFormat:@"%g", node->u.double_];
    return @"";
}

static int64_t DVNodeInt(mpv_node *node) {
    if (!node) return 0;
    if (node->format == MPV_FORMAT_INT64) return node->u.int64;
    if (node->format == MPV_FORMAT_DOUBLE) return (int64_t)node->u.double_;
    if (node->format == MPV_FORMAT_STRING && node->u.string) return strtoll(node->u.string, nullptr, 10);
    return 0;
}

static BOOL DVNodeFlag(mpv_node *node) { return DVNodeInt(node) != 0; }

#pragma mark - DVMpvTrack

@implementation DVMpvTrack
@end

#pragma mark - DVMpvView

@interface DVMpvView () {
    mpv_handle *_mpv;
    mpv_render_context *_render;
    BOOL _prepared;
    BOOL _shuttingDown;

    // 等渲染上下文就绪再 loadfile（窗口刚显示时 GL 还没 prepare）。
    BOOL _hasPending;
    NSString *_pendingURL;
    NSDictionary<NSString *, NSString *> *_pendingHeaders;
    double _pendingStart;

    // 事件线程直接写、主线程读的少量状态。
    NSArray<DVMpvTrack *> *_audioTracks;
    NSArray<DVMpvTrack *> *_subtitleTracks;
    int64_t _audioId;
    int64_t _subtitleId;

    CFAbsoluteTime _lastPositionEmit;
    BOOL _eofSent;
    double _volume;
    BOOL _muted;
    NSString *_tracksSignature;
    NSString *_capturePath;
    long _draws;
}
@property (nonatomic, readwrite) BOOL isLoaded;
@property (nonatomic, readwrite) double position;
@property (nonatomic, readwrite) double duration;
@property (nonatomic, readwrite) BOOL paused;
@property (nonatomic, readwrite) double speed;
@property (nonatomic, readwrite) BOOL eofReached;
@end

@implementation DVMpvView

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
    NSOpenGLPixelFormat *pf = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
    if (!pf) {
        return nil;
    }
    self = [super initWithFrame:frame pixelFormat:pf];
    if (self) {
        _audioTracks = @[];
        _subtitleTracks = @[];
        _speed = 1;
        _volume = 100;
    }
    return self;
}

- (BOOL)isOpaque { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (void)dealloc {
    [self shutdown];
}

- (void)prepareOpenGL {
    [super prepareOpenGL];
    if (_prepared) return;
    _prepared = YES;

    [[self openGLContext] makeCurrentContext];
    GLint swap = 1;
    [[self openGLContext] setValues:&swap forParameter:NSOpenGLContextParameterSwapInterval];

    mpv_handle *h = mpv_create();
    if (!h) {
        [self reportError:@"mpv_create 失败"];
        return;
    }

    mpv_set_option_string(h, "vo", "libmpv");
    mpv_set_option_string(h, "hwdec", "auto-safe");
    mpv_set_option_string(h, "osc", "no");
    mpv_set_option_string(h, "input-default-bindings", "no");
    mpv_set_option_string(h, "input-vo-keyboard", "no");
    mpv_set_option_string(h, "keep-open", "yes");
    mpv_set_option_string(h, "terminal", "no");
    mpv_set_option_string(h, "msg-level", "all=info");
    // HDR10 提示：有 HDR 屏时让系统按 PQ 输出；SDR 屏上 mpv 自己 tone map。
    mpv_set_option_string(h, "target-colorspace-hint", "yes");

    if (mpv_initialize(h) < 0) {
        mpv_destroy(h);
        [self reportError:@"mpv_initialize 失败"];
        return;
    }
    _mpv = h;
    mpv_request_log_messages(h, "info");

    // 用观察代替主动读取：跨线程 mpv_get_property 会卡住（m0 踩过）。
    for (int i = 0; kObservedProperties[i]; i++) {
        const char *name = kObservedProperties[i];
        mpv_format format = MPV_FORMAT_STRING;
        if (strcmp(name, "time-pos") == 0 || strcmp(name, "duration") == 0 ||
            strcmp(name, "speed") == 0 || strcmp(name, "volume") == 0) {
            format = MPV_FORMAT_DOUBLE;
        } else if (strcmp(name, "pause") == 0 || strcmp(name, "mute") == 0 ||
                   strcmp(name, "eof-reached") == 0) {
            format = MPV_FORMAT_FLAG;
        } else if (strcmp(name, "track-list") == 0) {
            format = MPV_FORMAT_NODE;
        }
        int rc = mpv_observe_property(h, 100 + i, name, format);
        if (rc < 0) {
            fprintf(stderr, "[mpv] observe %s 失败: %s\n", name, mpv_error_string(rc));
        }
    }

    mpv_opengl_init_params gl_init = {
        .get_proc_address = DVGetProcAddress,
        .get_proc_address_ctx = nullptr,
    };
    int advanced = 0;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_API_TYPE, const_cast<char *>(MPV_RENDER_API_TYPE_OPENGL)},
        {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init},
        {MPV_RENDER_PARAM_ADVANCED_CONTROL, &advanced},
        {MPV_RENDER_PARAM_INVALID, nullptr},
    };
    if (mpv_render_context_create(&_render, h, params) < 0) {
        _render = nullptr;
        [self reportError:@"mpv 渲染上下文创建失败"];
        return;
    }
    mpv_render_context_set_update_callback(_render, DVUpdateCallback, (__bridge void *)self);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self runEventLoop:h];
    });

    // 排在 prepareOpenGL 里的 loadfile：上下文这会儿才可用。
    if (_hasPending) {
        [self startPendingLoad];
    }
}

#pragma mark 事件线程

- (void)runEventLoop:(mpv_handle *)h {
    while (YES) {
        mpv_event *event = mpv_wait_event(h, 1.0);
        if (!event) continue;

        if (event->event_id == MPV_EVENT_SHUTDOWN) {
            break;
        }

        switch (event->event_id) {
            case MPV_EVENT_PROPERTY_CHANGE: {
                auto *prop = (mpv_event_property *)event->data;
                if (!prop || !prop->name) break;
                [self handleProperty:prop];
                break;
            }
            case MPV_EVENT_FILE_LOADED: {
                // keep-open 播完会停在暂停态；同一个文件重新 load（续播点正好在片尾）
                // 时 pause 不会自己复位，这里显式清一次，保证每次起播都在播。
                mpv_set_property_string(h, "pause", "no");
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self->_shuttingDown) return;
                    self->_eofSent = NO;
                    self.isLoaded = YES;
                    // duration 的下一次属性回调会补；这里先把已有的发出去。
                    self.onLoaded(self.duration);
                });
                break;
            }
            case MPV_EVENT_END_FILE: {
                auto *end = (mpv_event_end_file *)event->data;
                if (end && end->reason == MPV_END_FILE_REASON_ERROR) {
                    const char *text = mpv_error_string(end->error);
                    NSString *message = [NSString stringWithFormat:@"播放失败：%s",
                                         text ? text : "unknown"];
                    dispatch_async(dispatch_get_main_queue(), ^{
                        if (!self->_shuttingDown) self.onError(message);
                    });
                }
                break;
            }
            case MPV_EVENT_VIDEO_RECONFIG: {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self setNeedsDisplay:YES];
                });
                break;
            }
            case MPV_EVENT_LOG_MESSAGE: {
                auto *log = (mpv_event_log_message *)event->data;
                if (!log || !log->text) break;
                const char *level = log->level ? log->level : "";
                BOOL noisy = getenv("DVPLAYER_MPV_LOG") != nullptr;
                if (noisy || strcmp(level, "error") == 0 || strcmp(level, "fatal") == 0) {
                    fprintf(stderr, "[mpv/%s] %s", level, log->text);
                    fflush(stderr);
                }
                break;
            }
            default:
                break;
        }
    }
}

- (void)handleProperty:(mpv_event_property *)prop {
    const char *name = prop->name;

    if (strcmp(name, "track-list") == 0) {
        if (prop->format != MPV_FORMAT_NODE || !prop->data) return;
        auto *node = (mpv_node *)prop->data;
        NSMutableArray<DVMpvTrack *> *audio = [NSMutableArray array];
        NSMutableArray<DVMpvTrack *> *subs = [NSMutableArray array];

        if (node->format == MPV_FORMAT_NODE_ARRAY && node->u.list) {
            for (int i = 0; i < node->u.list->num; i++) {
                mpv_node *item = &node->u.list->values[i];
                NSString *type = DVNodeString(DVNodeField(item, "type"));
                if (![type isEqualToString:@"audio"] && ![type isEqualToString:@"sub"]) {
                    continue;
                }

                DVMpvTrack *track = [[DVMpvTrack alloc] init];
                track.trackId = DVNodeInt(DVNodeField(item, "id"));
                track.type = type;
                track.title = DVNodeString(DVNodeField(item, "title"));
                track.language = DVNodeString(DVNodeField(item, "lang"));
                track.codec = DVNodeString(DVNodeField(item, "codec"));
                track.isDefault = DVNodeFlag(DVNodeField(item, "default"));
                track.isExternal = DVNodeFlag(DVNodeField(item, "external"));
                if ([type isEqualToString:@"audio"]) {
                    [audio addObject:track];
                } else {
                    [subs addObject:track];
                }
            }
        }

        _audioTracks = [audio copy];
        _subtitleTracks = [subs copy];
        [self emitTracks];
        return;
    }

    if (strcmp(name, "aid") == 0 || strcmp(name, "sid") == 0) {
        if (prop->format != MPV_FORMAT_STRING || !prop->data) return;
        const char *value = *(char **)prop->data;
        int64_t trackId = (value && strcmp(value, "no") != 0 && strcmp(value, "auto") != 0)
            ? strtoll(value, nullptr, 10) : 0;
        if (strcmp(name, "aid") == 0) _audioId = trackId; else _subtitleId = trackId;
        [self emitTracks];
        return;
    }

    if (strcmp(name, "time-pos") == 0) {
        if (prop->format != MPV_FORMAT_DOUBLE || !prop->data) return;
        double value = *(double *)prop->data;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_shuttingDown) return;
            self.position = value;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - self->_lastPositionEmit >= 0.15) {
                self->_lastPositionEmit = now;
                if (self.onPosition) self.onPosition(value, self.duration);
            }
        });
        return;
    }

    if (strcmp(name, "duration") == 0) {
        if (prop->format != MPV_FORMAT_DOUBLE || !prop->data) return;
        double value = *(double *)prop->data;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_shuttingDown) return;
            self.duration = value;
            if (self.onPosition) self.onPosition(self.position, value);
        });
        return;
    }

    if (strcmp(name, "pause") == 0) {
        if (prop->format != MPV_FORMAT_FLAG || !prop->data) return;
        BOOL value = *(int *)prop->data != 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_shuttingDown) return;
            self.paused = value;
            if (self.onPause) self.onPause(value);
        });
        return;
    }

    if (strcmp(name, "eof-reached") == 0) {
        if (prop->format != MPV_FORMAT_FLAG || !prop->data) return;
        BOOL value = *(int *)prop->data != 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_shuttingDown) return;
            self.eofReached = value;
            if (value && !self->_eofSent) {
                self->_eofSent = YES;
                if (self.onEOF) self.onEOF();
            }
        });
        return;
    }

    if (strcmp(name, "speed") == 0) {
        if (prop->format != MPV_FORMAT_DOUBLE || !prop->data) return;
        double value = *(double *)prop->data;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_shuttingDown) return;
            self.speed = value;
            if (self.onSpeed) self.onSpeed(value);
        });
        return;
    }

    if (strcmp(name, "volume") == 0) {
        if (prop->format != MPV_FORMAT_DOUBLE || !prop->data) return;
        double value = *(double *)prop->data;
        _volume = value;
        BOOL muted = _muted;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_shuttingDown) return;
            if (self.onVolume) self.onVolume(value, muted);
        });
        return;
    }

    if (strcmp(name, "mute") == 0) {
        if (prop->format != MPV_FORMAT_FLAG || !prop->data) return;
        BOOL value = *(int *)prop->data != 0;
        _muted = value;
        double volume = _volume;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_shuttingDown) return;
            if (self.onVolume) self.onVolume(volume, value);
        });
        return;
    }
}

- (void)emitTracks {
    NSArray<DVMpvTrack *> *audio = _audioTracks ?: @[];
    NSArray<DVMpvTrack *> *subs = _subtitleTracks ?: @[];
    int64_t aid = _audioId;
    int64_t sid = _subtitleId;

    // track-list / aid / sid 会连着来好几条，签名没变就不重复上报。
    NSString *signature = [NSString stringWithFormat:@"%lu/%lu/%lld/%lld",
                           (unsigned long)audio.count, (unsigned long)subs.count, aid, sid];
    if ([signature isEqualToString:_tracksSignature ?: @""]) return;
    _tracksSignature = signature;

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_shuttingDown) return;
        if (self.onTracks) self.onTracks(audio, subs, aid, sid);
    });
}

- (void)reportError:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self->_shuttingDown && self.onError) self.onError(message);
    });
}

#pragma mark 播放控制

- (void)loadURL:(NSString *)url
        headers:(NSDictionary<NSString *, NSString *> *)headers
          start:(double)start {
    if (_shuttingDown) return;
    _pendingURL = [url copy];
    _pendingHeaders = [headers copy];
    _pendingStart = start;
    _hasPending = YES;
    if (_render) {
        [self startPendingLoad];
    }
}

- (void)startPendingLoad {
    if (!_mpv || !_hasPending || !_pendingURL) return;
    _hasPending = NO;

    // 每集都重设一次：换集时请求头 / 续播点可能都不一样。
    NSString *start = _pendingStart > 1
        ? [NSString stringWithFormat:@"%.3f", _pendingStart] : @"0";
    mpv_set_property_string(_mpv, "start", start.UTF8String);
    mpv_set_property_string(_mpv, "pause", "no");

    if (_pendingHeaders.count > 0) {
        NSMutableArray<NSString *> *fields = [NSMutableArray array];
        for (NSString *name in _pendingHeaders) {
            [fields addObject:[NSString stringWithFormat:@"%@: %@", name, _pendingHeaders[name]]];
        }
        NSString *joined = [fields componentsJoinedByString:@","];
        int rc = mpv_set_property_string(_mpv, "http-header-fields", joined.UTF8String);
        if (rc < 0) {
            fprintf(stderr, "[mpv] 设置请求头失败: %s\n", mpv_error_string(rc));
        }
    } else {
        mpv_set_property_string(_mpv, "http-header-fields", "");
    }

    _tracksSignature = nil;
    const char *cmd[] = {"loadfile", _pendingURL.UTF8String, "replace", nullptr};
    int rc = mpv_command_async(_mpv, 0, cmd);
    if (rc < 0) {
        [self reportError:[NSString stringWithFormat:@"loadfile 失败：%s", mpv_error_string(rc)]];
    }
    _pendingURL = nil;
    _pendingHeaders = nil;
}

- (void)play { if (_mpv) mpv_set_property_string(_mpv, "pause", "no"); }
- (void)pause { if (_mpv) mpv_set_property_string(_mpv, "pause", "yes"); }

- (void)togglePause {
    if (_mpv) mpv_command_string(_mpv, "cycle pause");
}

- (void)seekTo:(double)seconds {
    if (!_mpv) return;
    NSString *value = [NSString stringWithFormat:@"%.3f", MAX(0, seconds)];
    const char *cmd[] = {"seek", value.UTF8String, "absolute", nullptr};
    mpv_command_async(_mpv, 0, cmd);
    _lastPositionEmit = 0;
}

- (void)setVolumePercent:(double)percent {
    if (!_mpv) return;
    mpv_set_property_string(_mpv, "volume", [NSString stringWithFormat:@"%.1f", percent].UTF8String);
}

- (void)setMuted:(BOOL)muted {
    if (!_mpv) return;
    mpv_set_property_string(_mpv, "mute", muted ? "yes" : "no");
}

- (void)setSpeed:(double)speed {
    if (!_mpv) return;
    mpv_set_property_string(_mpv, "speed", [NSString stringWithFormat:@"%.3f", speed].UTF8String);
}

- (void)selectAudio:(int64_t)trackId {
    if (!_mpv) return;
    NSString *value = trackId > 0 ? [NSString stringWithFormat:@"%lld", trackId] : @"no";
    mpv_set_property_string(_mpv, "aid", value.UTF8String);
}

- (void)selectSubtitle:(int64_t)trackId {
    if (!_mpv) return;
    NSString *value = trackId > 0 ? [NSString stringWithFormat:@"%lld", trackId] : @"no";
    mpv_set_property_string(_mpv, "sid", value.UTF8String);
}

- (void)captureFrameTo:(NSString *)path {
    _capturePath = [path copy];
    [self setNeedsDisplay:YES];
}

/// 后台缓冲 → PNG。调用时 GL 上下文是 current 的。
- (void)writeFramebufferTo:(NSString *)path width:(int)w height:(int)h {
    if (w <= 0 || h <= 0) return;

    size_t rowBytes = (size_t)w * 4;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:w
                      pixelsHigh:h
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSDeviceRGBColorSpace
                     bytesPerRow:rowBytes
                    bitsPerPixel:32];
    if (!rep) return;

    unsigned char *raw = (unsigned char *)malloc(rowBytes * (size_t)h);
    if (!raw) return;

    glPixelStorei(GL_PACK_ALIGNMENT, 1);
    glReadPixels(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, raw);

    // GL 的原点在左下，PNG 在上左：按行倒着拷。
    unsigned char *dst = rep.bitmapData;
    for (int y = 0; y < h; y++) {
        memcpy(dst + (size_t)y * rowBytes,
               raw + (size_t)(h - 1 - y) * rowBytes,
               rowBytes);
    }
    free(raw);

    NSData *data = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (data) {
        [data writeToFile:path atomically:YES];
        fprintf(stderr, "[gl] frame saved %s %dx%d\n", path.UTF8String, w, h);
        fflush(stderr);
    }
}

- (void)screenshotTo:(NSString *)path {
    if (!_mpv) return;
    const char *cmd[] = {"screenshot-to-file", path.UTF8String, "video", nullptr};
    mpv_command_async(_mpv, 0, cmd);
}

- (void)shutdown {
    if (_shuttingDown) return;
    _shuttingDown = YES;
    _hasPending = NO;

    if (_render) {
        mpv_render_context_set_update_callback(_render, nullptr, nullptr);
        [[self openGLContext] makeCurrentContext];
        mpv_render_context_free(_render);
        _render = nullptr;
    }

    if (_mpv) {
        mpv_handle *h = _mpv;
        _mpv = nullptr;
        mpv_terminate_destroy(h);
    }
}

#pragma mark 渲染

- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    if (!_render) {
        [[NSColor blackColor] setFill];
        NSRectFill(self.bounds);
        return;
    }

    [[self openGLContext] makeCurrentContext];
    NSRect backing = [self convertRectToBacking:self.bounds];
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

    if (_capturePath) {
        NSString *path = _capturePath;
        _capturePath = nil;
        [self writeFramebufferTo:path width:fbo.w height:fbo.h];
    }

    [[self openGLContext] flushBuffer];
    mpv_render_context_report_swap(_render);

    if (getenv("DVPLAYER_MPV_LOG") != nullptr) {
        _draws += 1;
        if (_draws % 120 == 0) {
            fprintf(stderr, "[gl] draws=%ld size=%dx%d\n", (long)_draws,
                    fbo.w, fbo.h);
            fflush(stderr);
        }
    }
}

@end

static void DVUpdateCallback(void *ctx) {
    DVMpvView *view = (__bridge DVMpvView *)ctx;
    dispatch_async(dispatch_get_main_queue(), ^{
        [view setNeedsDisplay:YES];
    });
}
