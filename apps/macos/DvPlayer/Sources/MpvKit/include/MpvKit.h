#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 一条 mpv 轨道（音频 / 字幕）。
@interface DVMpvTrack : NSObject

@property (nonatomic) int64_t trackId;
/// "audio" / "sub"
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *language;
@property (nonatomic, copy) NSString *codec;
@property (nonatomic) BOOL isDefault;
@property (nonatomic) BOOL isExternal;

@end

/// libmpv render API 的视图：自己建 mpv / GL 上下文，视频画在自己的 NSOpenGLView 里。
///
/// 所有回调都在主线程。属性只在主线程读写（事件线程会转到主线程再回调）。
@interface DVMpvView : NSOpenGLView

// —— 回调（全部主线程） ——
/// 位置 / 片长变化（大致 5 次/秒）。
@property (nonatomic, copy, nullable) void (^onPosition)(double position, double duration);
@property (nonatomic, copy, nullable) void (^onPause)(BOOL paused);
@property (nonatomic, copy, nullable) void (^onLoaded)(double duration);
@property (nonatomic, copy, nullable) void (^onEOF)(void);
@property (nonatomic, copy, nullable) void (^onTracks)(NSArray<DVMpvTrack *> *audio,
                                                      NSArray<DVMpvTrack *> *subtitles,
                                                      int64_t audioId,
                                                      int64_t subtitleId);
@property (nonatomic, copy, nullable) void (^onSpeed)(double speed);
@property (nonatomic, copy, nullable) void (^onVolume)(double volume, BOOL muted);
@property (nonatomic, copy, nullable) void (^onError)(NSString *message);
@property (nonatomic, copy, nullable) void (^onLog)(NSString *message);

// —— 状态（主线程） ——
@property (nonatomic, readonly) BOOL isLoaded;
@property (nonatomic, readonly) double position;
@property (nonatomic, readonly) double duration;
@property (nonatomic, readonly) BOOL paused;
@property (nonatomic, readonly) double speed;
@property (nonatomic, readonly) BOOL eofReached;

/// 起播。headers 会拼成 mpv 的 http-header-fields；start 小于等于 1 时从头放。
- (void)loadURL:(NSString *)url
        headers:(NSDictionary<NSString *, NSString *> *)headers
          start:(double)start;

- (void)play;
- (void)pause;
- (void)togglePause;
- (void)seekTo:(double)seconds;

/// 0...100，和 Windows 的音量条同一个量纲。
- (void)setVolumePercent:(double)percent;
- (void)setMuted:(BOOL)muted;
- (void)setSpeed:(double)speed;

/// 0 表示关闭该轨（mpv 的 "no"）。
- (void)selectAudio:(int64_t)trackId;
- (void)selectSubtitle:(int64_t)trackId;

/// 用 mpv 自己的截图命令导出当前视频帧（解码器输出，不含 GL 后处理）。
- (void)screenshotTo:(NSString *)path;

/// 读回 GL 前台缓冲，存 PNG——这才是屏幕上真正显示的画面。
/// 截图工具拍不到 NSOpenGLView，自检用这个。
- (void)captureFrameTo:(NSString *)path;

/// 关窗时调用：停事件线程、销毁 mpv / 渲染上下文。
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
