//
//  VideoManager.h
//  VideoRecorderDemo
//
//  Created by GrayLeo on 2017/1/6.
//  Copyright © 2017年 GrayLeo. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

@protocol VideoSessionManagerDelegate;
@interface VideoManager : NSObject
@property (nonatomic, weak) id<VideoSessionManagerDelegate> delegate;
@property (strong, nonatomic) AVCaptureSession *captureSession;//影音采集会话对象
@property (strong, nonatomic) AVCaptureVideoPreviewLayer *layer;//用于展示session采集到的内容
@property (nonatomic, strong) AVCaptureConnection *audioConnection;
@property (nonatomic, strong) AVCaptureConnection *videoConnection;

@property (readwrite) AVCaptureVideoOrientation recordingOrientation; // client can set the orientation for the recorded movie

+ (instancetype)sharedInstance;

- (void)startRunning;
- (void)stopRunning;

- (void)startRecording;
- (void)stopRecording;


@end




@protocol VideoSessionManagerDelegate <NSObject>
@required

- (void)sessionManager:(VideoManager *)videoManager didStopRunningWithError:(NSError *)error;

// Preview
- (void)sessionManager:(VideoManager *)videoManager previewPixelBufferReadyForDisplay:(CVPixelBufferRef)previewPixelBuffer;
- (void)sessionManagerDidRunOutOfPreviewBuffers:(VideoManager *)videoManager;

// Recording
- (void)sessionManagerRecordingDidStart:(VideoManager *)videoManager;
- (void)sessionManager:(VideoManager *)videoManager recordingDidFailWithError:(NSError *)error; // Can happen at any point after a startRecording call, for example: startRecording->didFail (without a didStart), willStop->didFail (without a didStop)
- (void)sessionManagerRecordingWillStop:(VideoManager *)videoManager;
- (void)sessionManagerRecordingDidStop:(VideoManager *)videoManager;

@end













