#pragma once
#import <UIKit/UIKit.h>

@interface ZNRangeControl : UIControl
@property(nonatomic,assign) double minimumValue;
@property(nonatomic,assign) double maximumValue;
@property(nonatomic,assign) double value;
@property(nonatomic,strong) UIColor *minimumTrackTintColor;
@property(nonatomic,strong) UIColor *maximumTrackTintColor;
@property(nonatomic,strong) UIColor *thumbTintColor;
@end
