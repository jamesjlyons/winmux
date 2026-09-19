#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// M0 transport proof only. No workspace mutations are exposed until inventory,
// revision and focus semantics are integrated with the Chromium owner.
@protocol WMWorkspaceBridge
- (void)negotiateVersion:(NSInteger)version
                  reply:(void (^)(NSInteger version, NSString *_Nullable epoch))reply;
- (void)pingEpoch:(NSString *)epoch
        sequence:(uint64_t)sequence
           reply:(void (^)(BOOL accepted, uint64_t sequence))reply;
@end

NS_ASSUME_NONNULL_END
