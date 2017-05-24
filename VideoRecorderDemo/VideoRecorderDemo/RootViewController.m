//
//  RootViewController.m
//  VideoRecorderDemo
//
//  Created by GrayLeo on 2017/1/6.
//  Copyright © 2017年 GrayLeo. All rights reserved.
//

#import "RootViewController.h"
#import "VideoManager.h"

#import "sys/utsname.h"

@interface RootViewController ()
@property (weak, nonatomic) IBOutlet UIButton *recordButton;

@end

@implementation RootViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view from its nib.

}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    VideoManager *manager = [VideoManager sharedInstance];
    manager.layer.frame = self.view.layer.frame;
    [self.view.layer insertSublayer:manager.layer atIndex:0];
    
    [manager startRunning];
}

- (IBAction)buttonAction:(id)sender {
    if ([_recordButton.titleLabel.text isEqualToString:@"Record"]) {
        [[VideoManager sharedInstance] startRecording];
        [_recordButton setTitle:@"stop" forState:UIControlStateNormal];
    } else {
        [[VideoManager sharedInstance] stopRecording];
        [_recordButton setTitle:@"Record" forState:UIControlStateNormal];
    }
}



@end
