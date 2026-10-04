#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// All methods are asynchronous and available only after mutual code-signing
// validation. Versions 2/3 add tab ownership/layout; version 4 adds navigation; version 5 adds session-owned page creation.
@protocol WMBrowserSurfaceOwner
// Version 5. A nil source creates a page in the last-used regular profile.
// The returned persistent surface identifies the page even before inventory.
- (void)openBrowserTab:(NSString *_Nullable)source
              profile:(NSString *_Nullable)profile
                  url:(NSString *_Nullable)url
                epoch:(NSString *)epoch
            operation:(NSString *)operation
             revision:(uint64_t)revision
                reply:(void (^)(NSString *outcome, NSString *_Nullable surface))reply;
// Version 4. URL is a separate nullable payload and participates in operation
// identity, so retries cannot accidentally issue a different navigation.
- (void)performBrowserAction:(NSString *)action
                    surface:(NSString *)surface
                        url:(NSString *_Nullable)url
                      epoch:(NSString *)epoch
                  operation:(NSString *)operation
                   revision:(uint64_t)revision
                 generation:(uint64_t)generation
                      reply:(void (^)(NSString *outcome))reply;
- (void)applyLayout:(NSData *)layout
              epoch:(NSString *)epoch
          operation:(NSString *)operation
           revision:(uint64_t)revision
         generation:(uint64_t)generation
              reply:(void (^)(NSString *outcome))reply;
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
