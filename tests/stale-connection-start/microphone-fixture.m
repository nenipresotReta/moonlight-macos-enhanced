#import <Foundation/Foundation.h>
#include <assert.h>
#define Log(...) ((void)0)
#define LI_MIC_CONTROL_START 1
#define AVMediaTypeAudio @"FakeAudio"
#define AVAuthorizationStatus NSInteger
#define AVAuthorizationStatusAuthorized 1
@interface AVCaptureDevice:NSObject
+ (AVAuthorizationStatus)authorizationStatusForMediaType:(id)media;
@end
@implementation AVCaptureDevice
+ (AVAuthorizationStatus)authorizationStatusForMediaType:(id)media { return AVAuthorizationStatusAuthorized; }
@end
@protocol ConnectionCallbacks
- (void)connectionTerminated:(int)error;
@end
@interface Config:NSObject
@property BOOL enableMic;
@end
@implementation Config @end
static NSMutableArray<dispatch_block_t> *MainQueue, *BackgroundQueue;
static void TestEnqueue(dispatch_queue_t queue, dispatch_block_t block) { [(queue == dispatch_get_main_queue() ? MainQueue : BackgroundQueue) addObject:[block copy]]; }
static void Drain(NSMutableArray *queue) { NSArray *batch=[queue copy]; [queue removeAllObjects]; for (dispatch_block_t b in batch) b(); }
#define dispatch_async(queue,block) TestEnqueue(queue,block)
static void *gMicQueueKey=&gMicQueueKey;
@interface Connection:NSObject { @public
    int32_t _hasTerminated;
    Config *_streamConfig;
    int _micSendFailures;
    BOOL _micStopping, _micEncryptionStatusLogged;
    dispatch_queue_t _micQueue;
    NSMutableData *_micPcmQueue;
}
@property (readonly) BOOL hasTerminated;
- (void)startMicrophoneIfNeeded;
- (void)stopMicrophoneIfNeeded;
- (void)startMicrophoneEngineLocked;
@end
static Connection *Current;
static NSUInteger EngineStarts, Stops;
static Connection *CurrentConnection(void) { return Current; }
static id<ConnectionCallbacks> ConnectionGetCallbacksSnapshot(Connection *c) { return nil; }
@implementation Connection
- (void)stopMicrophoneIfNeeded { Stops++; _micStopping=YES; }
- (void)startMicrophoneEngineLocked { EngineStarts++; }
// PRODUCTION_METHODS
@end
static void Setup(void) { Current=[Connection new]; Current->_streamConfig=[Config new]; Current->_streamConfig.enableMic=YES; MainQueue=[NSMutableArray new]; BackgroundQueue=[NSMutableArray new]; EngineStarts=Stops=0; }
int main(void) { @autoreleasepool {
    Setup(); [Current startMicrophoneIfNeeded]; Drain(MainQueue); assert(EngineStarts==1);
    Setup(); Current->_streamConfig.enableMic=NO; [Current startMicrophoneIfNeeded]; Drain(MainQueue); assert(EngineStarts==0);
    // The connection callback's main-queue microphone start arrives after the
    // termination callback and its background microphone stop already finished.
    Setup(); dispatch_async(dispatch_get_main_queue(), ^{ [Current startMicrophoneIfNeeded]; });
    ClConnectionTerminated(0); Drain(BackgroundQueue); assert(Stops==1);
    Drain(MainQueue); Drain(MainQueue); assert(EngineStarts==0 && Current->_micStopping);
    puts("PASS: a queued microphone start cannot clear the stop state after termination");
    // Termination also invalidates a start already queued by startMicrophoneIfNeeded,
    // before the background stop has had an opportunity to update _micStopping.
    Setup(); [Current startMicrophoneIfNeeded]; assert(MainQueue.count==1);
    ClConnectionTerminated(0); Drain(MainQueue); assert(EngineStarts==0);
    Drain(BackgroundQueue);
    puts("PASS: termination cancels the nested engine-start hop before microphone cleanup runs");
    Current=nil; MainQueue=nil; BackgroundQueue=nil;
} return 0; }
