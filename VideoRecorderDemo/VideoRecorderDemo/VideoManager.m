//
//  VideoManager.m
//  VideoRecorderDemo
//
//  Created by GrayLeo on 2017/1/6.
//  Copyright © 2017年 GrayLeo. All rights reserved.
//

#import "VideoManager.h"
#import "MovieRecorder.h"
#import <CoreMedia/CMBufferQueue.h>
#import <CoreMedia/CMAudioClock.h>
#import <AssetsLibrary/AssetsLibrary.h>

typedef NS_ENUM( NSInteger, VideoRecordingStatus ) {
    VideoRecordingStatusIdle = 0,
    VideoRecordingStatusStartingRecording,
    VideoRecordingStatusRecording,
    VideoRecordingStatusStoppingRecording,
}; // internal state machine

static CGFloat angleOffsetFromPortraitOrientationToOrientation(AVCaptureVideoOrientation orientation) {
    CGFloat angle = 0.0;
    switch (orientation) {
        case AVCaptureVideoOrientationPortrait:
            angle = 0.0;
            break;
        case AVCaptureVideoOrientationPortraitUpsideDown:
            angle = M_PI;
            break;
        case AVCaptureVideoOrientationLandscapeRight:
            angle = -M_PI_2;
            break;
        case AVCaptureVideoOrientationLandscapeLeft:
            angle = M_PI_2;
            break;
        default:
            break;
    }
    return angle;
}



@interface VideoManager () <AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, MovieRecorderDelegate>
@property (nonatomic, strong) MovieRecorder *recorder;
@property (nonatomic, strong) NSURL *recordingURL;
@property (nonatomic, strong) __attribute__((NSObject)) CMFormatDescriptionRef outputVideoFormatDescription;
@property (nonatomic, strong) __attribute__((NSObject)) CMFormatDescriptionRef outputAudioFormatDescription;

@property (nonatomic, assign) VideoRecordingStatus recordingStatus;



@end

@implementation VideoManager

+ (instancetype)sharedInstance {
    static VideoManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[VideoManager alloc] init];
        [instance setupCaptureSession];
    });
    return instance;
}

- (void)setupCaptureSession {
    if (_captureSession) return;
    
    _captureSession = [[AVCaptureSession alloc] init];
    _recordingOrientation = AVCaptureVideoOrientationPortrait;
    
    /* audio */
    AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
    AVCaptureDeviceInput *audioIn = [[AVCaptureDeviceInput alloc] initWithDevice:audioDevice error:nil];
    if ([_captureSession canAddInput:audioIn])
        [_captureSession addInput:audioIn];

    AVCaptureAudioDataOutput *audioOut = [[AVCaptureAudioDataOutput alloc] init];
    // Put audio on its own queue to ensure that our video processing doesn't cause us to drop audio
    dispatch_queue_t audioCaptureQueue = dispatch_queue_create("com.apple.sample.sessionmanager.audio", DISPATCH_QUEUE_SERIAL);
    [audioOut setSampleBufferDelegate:self queue:audioCaptureQueue];
    
    if ([_captureSession canAddOutput:audioOut])
        [_captureSession addOutput:audioOut];
    _audioConnection = [audioOut connectionWithMediaType:AVMediaTypeAudio];
    
    /* video */
    AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
//    _videoDevice = videoDevice;
    AVCaptureDeviceInput *videoIn = [[AVCaptureDeviceInput alloc] initWithDevice:videoDevice error:nil];
    if ([_captureSession canAddInput:videoIn])
        [_captureSession addInput:videoIn];
    
    AVCaptureVideoDataOutput *videoOut = [[AVCaptureVideoDataOutput alloc] init];
    [videoOut setVideoSettings:[NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey]];
    dispatch_queue_t videoDataOutputQueue = dispatch_queue_create( "com.apple.sample.sessionmanager.video", DISPATCH_QUEUE_SERIAL );
    dispatch_set_target_queue( videoDataOutputQueue, dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_HIGH, 0) );
    [videoOut setSampleBufferDelegate:self queue:videoDataOutputQueue];
    
    // VideoSnake records videos and we prefer not to have any dropped frames in the video recording.
    // By setting alwaysDiscardsLateVideoFrames to NO we ensure that minor fluctuations in system load or in our processing time for a given frame won't cause framedrops.
    // We do however need to ensure that on average we can process frames in realtime.
    // If we were doing preview only we would probably want to set alwaysDiscardsLateVideoFrames to YES.
    [videoOut setAlwaysDiscardsLateVideoFrames:NO];
    
    if ([_captureSession canAddOutput:videoOut])
        [_captureSession addOutput:videoOut];
    _videoConnection = [videoOut connectionWithMediaType:AVMediaTypeVideo];
    
    int frameRate;
    CMTime frameDuration = kCMTimeInvalid;
    // For single core systems like iPhone 4 and iPod Touch 4th Generation we use a lower resolution and framerate to maintain real-time performance.
    if ( [[NSProcessInfo processInfo] processorCount] == 1 ) {
        if ( [_captureSession canSetSessionPreset:AVCaptureSessionPreset640x480] )
            _captureSession.sessionPreset = AVCaptureSessionPreset640x480;
        frameRate = 15;
    }
    else {
        _captureSession.sessionPreset = AVCaptureSessionPresetHigh;
        frameRate = 30;
    }
    frameDuration = CMTimeMake( 1, frameRate );
    
    NSError *error;
    if ([videoDevice lockForConfiguration:&error]) {
        [videoDevice setActiveVideoMaxFrameDuration:frameDuration];
        [videoDevice setActiveVideoMinFrameDuration:frameDuration];
        [videoDevice unlockForConfiguration];
    } else {
        NSLog(@"videoDevice lockForConfiguration returned error %@", error);
    }
    
    /* layer */
    self.layer = [AVCaptureVideoPreviewLayer layerWithSession:self.captureSession];
}


- (void)startRunning {
    if (!_captureSession) {
        [self setupCaptureSession];
    }
    [_captureSession startRunning];
}

- (void)stopRunning {
    [_captureSession stopRunning];
}

- (void)startRecording {
    @synchronized( self ) {
        if ( _recordingStatus != VideoRecordingStatusIdle ) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Already recording" userInfo:nil];
            return;
        }
        [self transitionToRecordingStatus:VideoRecordingStatusStartingRecording error:nil];
    }
    
    
    if (!_recorder) {
        _recordingURL = [[NSURL alloc] initFileURLWithPath:[NSString pathWithComponents:@[NSTemporaryDirectory(), @"Movie.MOV"]]];
        _recorder = [[MovieRecorder alloc] initWithURL:_recordingURL];
    }
    
    [_recorder addAudioTrackWithSourceFormatDescription:self.outputAudioFormatDescription];
    
    CGAffineTransform videoTransform = [self transformFromVideoBufferOrientationToOrientation:self.recordingOrientation withAutoMirroring:NO]; // Front camera recording shouldn't be mirrored
    [_recorder addVideoTrackWithSourceFormatDescription:self.outputVideoFormatDescription transform:videoTransform];
    
    dispatch_queue_t callbackQueue = dispatch_queue_create( "com.apple.sample.sessionmanager.recordercallback", DISPATCH_QUEUE_SERIAL ); // guarantee ordering of callbacks with a serial queue
    [_recorder setDelegate:self callbackQueue:callbackQueue];
    [_recorder prepareToRecord]; // asynchronous, will call us back with recorderDidFinishPreparing: or recorder:didFailWithError: when done

}

- (void)stopRecording {
    @synchronized( self ) {
        if ( _recordingStatus != VideoRecordingStatusRecording ) {
            return;
        }
        [self transitionToRecordingStatus:VideoRecordingStatusStoppingRecording error:nil];
    }
    [self.recorder finishRecording]; // asynchronous, will call us back with recorderDidFinishRecording: or recorder:didFailWithError: when done
}

// Auto mirroring: Front camera is mirrored; back camera isn't
- (CGAffineTransform)transformFromVideoBufferOrientationToOrientation:(AVCaptureVideoOrientation)orientation withAutoMirroring:(BOOL)mirror
{
    CGAffineTransform transform = CGAffineTransformIdentity;
    
    // Calculate offsets from an arbitrary reference orientation (portrait)
    CGFloat orientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation( orientation );
    CGFloat videoOrientationAngleOffset = angleOffsetFromPortraitOrientationToOrientation( [self.videoConnection videoOrientation] );
    
    // Find the difference in angle between the desired orientation and the video orientation
    CGFloat angleOffset = orientationAngleOffset - videoOrientationAngleOffset;
    transform = CGAffineTransformMakeRotation(angleOffset);
    
    return transform;
}

#pragma mark - Recording State Machine

// call under @synchonized( self )
- (void)transitionToRecordingStatus:(VideoRecordingStatus)newStatus error:(NSError*)error
{
    SEL delegateSelector = NULL;
    VideoRecordingStatus oldStatus = _recordingStatus;
    _recordingStatus = newStatus;
    
#if LOG_STATUS_TRANSITIONS
    NSLog( @"VideoSnakeSessionManager recording state transition: %@->%@", [self stringForRecordingStatus:oldStatus], [self stringForRecordingStatus:newStatus] );
#endif
    
    if ( newStatus != oldStatus ) {
        if ( error && ( newStatus == VideoRecordingStatusIdle ) ) {
            delegateSelector = @selector(sessionManager:recordingDidFailWithError:);
        }
        else {
            error = nil; // only the above delegate method takes an error
            if ( ( oldStatus == VideoRecordingStatusStartingRecording ) && ( newStatus == VideoRecordingStatusRecording ) )
                delegateSelector = @selector(sessionManagerRecordingDidStart:);
            else if ( ( oldStatus == VideoRecordingStatusRecording ) && ( newStatus == VideoRecordingStatusStoppingRecording ) )
                delegateSelector = @selector(sessionManagerRecordingWillStop:);
            else if ( ( oldStatus == VideoRecordingStatusStoppingRecording ) && ( newStatus == VideoRecordingStatusIdle ) )
                delegateSelector = @selector(sessionManagerRecordingDidStop:);
        }
    }
    
    if ( delegateSelector && [self delegate] ) {
        @autoreleasepool {
            if ( error )
                [[self delegate] performSelector:delegateSelector withObject:self withObject:error];
            else
                [[self delegate] performSelector:delegateSelector withObject:self];
        }
    }
}

#pragma mark - AVCapture Video and Audio DataOutputSampleBufferDelegate
- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
    
    if ( connection == _videoConnection ) {
        self.outputVideoFormatDescription = formatDescription;
        @synchronized( self ) {
            if ( _recordingStatus == VideoRecordingStatusRecording ) {
                [self.recorder appendVideoSampleBuffer:sampleBuffer];
            }
        }

    } else if ( connection == _audioConnection ) {
        self.outputAudioFormatDescription = formatDescription;
        @synchronized( self ) {
            if ( _recordingStatus == VideoRecordingStatusRecording ) {
                [self.recorder appendAudioSampleBuffer:sampleBuffer];
            }
        }
    }

}

#pragma mark - MovieRecorderDelegate
- (void)movieRecorderDidFinishPreparing:(MovieRecorder *)recorder {
    @synchronized( self ) {
        if ( _recordingStatus != VideoRecordingStatusStartingRecording ) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Expected to be in StartingRecording state" userInfo:nil];
            return;
        }
        [self transitionToRecordingStatus:VideoRecordingStatusRecording error:nil];
    }
}

- (void)movieRecorder:(MovieRecorder *)recorder didFailWithError:(NSError *)error {
    @synchronized( self ) {
        self.recorder = nil;
        [self transitionToRecordingStatus:VideoRecordingStatusIdle error:error];
    }
}

- (void)movieRecorderDidFinishRecording:(MovieRecorder *)recorder {
    @synchronized( self ) {
        if ( _recordingStatus != VideoRecordingStatusStoppingRecording ) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Expected to be in StoppingRecording state" userInfo:nil];
            return;
        }
        
        // No state transition, we are still in the process of stopping.
        // We will be stopped once we save to the assets library.
    }
    
    self.recorder = nil;
    
    ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
    [library writeVideoAtPathToSavedPhotosAlbum:_recordingURL completionBlock:^(NSURL *assetURL, NSError *error) {
        
        [[NSFileManager defaultManager] removeItemAtURL:_recordingURL error:NULL];
        
        @synchronized( self ) {
            if ( _recordingStatus != VideoRecordingStatusStoppingRecording ) {
                @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Expected to be in StoppingRecording state" userInfo:nil];
                return;
            }
            [self transitionToRecordingStatus:VideoRecordingStatusIdle error:error];
        }
    }];
}



@end























