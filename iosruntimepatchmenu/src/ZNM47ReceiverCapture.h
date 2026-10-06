#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ZNM47ReceiverCaptureCompletion)(uintptr_t receiver,
                                               NSString * _Nullable error);

FOUNDATION_EXPORT BOOL ZNM47ReceiverCaptureBusy(void);
FOUNDATION_EXPORT BOOL ZNM47StartReceiverCapture(NSDictionary *candidate,
                                                 NSTimeInterval timeout,
                                                 ZNM47ReceiverCaptureCompletion completion,
                                                 NSString * _Nullable * _Nullable error);
FOUNDATION_EXPORT void ZNM47CancelReceiverCapture(void);

NS_ASSUME_NONNULL_END
