#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// All methods are asynchronous and available only after mutual code-signing
// validation. Version 1 remains transport-only; version 2 adds tab ownership.
@protocol WMBrowserSurfaceOwner
- (void)performAction:(NSString *)action
             surface:(NSString *)surface
               epoch:(NSString *)epoch
           operation:(NSString *)operation
            revision:(uint64_t)revision
          generation:(uint64_t)generation
               reply:(void (^)(NSString *outcome))reply;
@end

@protocol WMWorkspaceBridge
- (void)negotiateVersion:(NSInteger)version
                  reply:(void (^)(NSInteger version, NSString *_Nullable epoch))reply;
- (void)pingEpoch:(NSString *)epoch
        sequence:(uint64_t)sequence
           reply:(void (^)(BOOL accepted, uint64_t sequence))reply;
- (void)publishInventory:(NSData *)inventory
                  epoch:(NSString *)epoch
               sequence:(uint64_t)sequence
                  reply:(void (^)(BOOL accepted, uint64_t revision))reply;
@end

NS_ASSUME_NONNULL_END
