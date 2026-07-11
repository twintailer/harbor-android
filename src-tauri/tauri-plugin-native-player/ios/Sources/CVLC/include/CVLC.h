// Minimal interop declarations for MobileVLCKit. The framework binary is
// linked by the app's Xcode project (added in CI); SwiftPM's CLI build used
// by swift-rs cannot consume binary xcframework targets, so the plugin only
// compiles against these declarations and the symbols resolve at app link.
//
// Enum orders and selectors mirror MobileVLCKit 3.x public headers.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, VLCMediaPlayerState) {
    VLCMediaPlayerStateStopped,
    VLCMediaPlayerStateOpening,
    VLCMediaPlayerStateBuffering,
    VLCMediaPlayerStateEnded,
    VLCMediaPlayerStateError,
    VLCMediaPlayerStatePlaying,
    VLCMediaPlayerStatePaused,
    VLCMediaPlayerStateESAdded,
};

typedef NS_ENUM(unsigned, VLCMediaPlaybackSlaveType) {
    VLCMediaPlaybackSlaveTypeSubtitle = 0,
    VLCMediaPlaybackSlaveTypeAudio,
};

@interface VLCTime : NSObject
+ (VLCTime *)timeWithInt:(int)aInt;
@property (readonly) int intValue;
@end

@interface VLCAudio : NSObject
@property (getter=isMuted) BOOL muted;
@property (assign) int volume;
@end

@interface VLCMedia : NSObject
+ (instancetype)mediaWithURL:(NSURL *)anURL;
@property (nonatomic, readonly) VLCTime *length;
@end

@protocol VLCMediaPlayerDelegate <NSObject>
@optional
- (void)mediaPlayerStateChanged:(NSNotification *)aNotification;
- (void)mediaPlayerTimeChanged:(NSNotification *)aNotification;
@end

@interface VLCMediaPlayer : NSObject
@property (weak, nonatomic, nullable) id<VLCMediaPlayerDelegate> delegate;
@property (strong, nullable) id drawable;
@property (strong, nullable) VLCMedia *media;
@property (readonly) VLCMediaPlayerState state;
@property (strong) VLCTime *time;
@property (nonatomic) float position;
@property (nonatomic) float rate;
@property (getter=isSeekable, readonly) BOOL seekable;
@property (readonly, weak, nullable) VLCAudio *audio;
@property (readonly) CGSize videoSize;
@property (readwrite) int currentAudioTrackIndex;
@property (readonly, copy, nullable) NSArray *audioTrackNames;
@property (readonly, copy, nullable) NSArray *audioTrackIndexes;
@property (readwrite) int currentVideoSubTitleIndex;
@property (readonly, copy, nullable) NSArray *videoSubTitlesNames;
@property (readonly, copy, nullable) NSArray *videoSubTitlesIndexes;
- (void)play;
- (void)pause;
- (void)stop;
- (int)addPlaybackSlave:(NSURL *)slaveURL type:(VLCMediaPlaybackSlaveType)slaveType enforce:(BOOL)enforceSelection;
@end

NS_ASSUME_NONNULL_END
