//
// Copyright © 2020 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import <stdbool.h>
#import <stdint.h>
#import "UTMProcess.h"
#import "UTMQemuSystemBackends.h"
@import QEMUKitInternal;

NS_ASSUME_NONNULL_BEGIN

/// The guest's current framebuffer, mirrored from HuskFrameInfo in
/// husk-display.h. Kept in step by hand because an Xcode target cannot include
/// QEMU's headers; the field order and widths are the ABI.
typedef struct _UTMHuskFrame {
    const void * _Nullable pixels;
    int32_t width;
    int32_t height;
    int32_t stride;
    uint32_t bpp;
    uint64_t generation;
    uint64_t sequence;
} UTMHuskFrame;

/// The app's view of the Husk backend inside the QEMU library.
///
/// QEMU is loaded with dlopen() rather than linked, so every entry point has to
/// be resolved from the handle the process loader was given. Symbol names that
/// are not exported by system/qemu.symbols resolve to NULL here and every call
/// becomes a no-op, which is how a build without the Husk integration degrades
/// instead of failing to launch.
@interface UTMHuskBackend : NSObject

@property (class, nonatomic, readonly) UTMHuskBackend *shared;
@property (nonatomic, readonly) BOOL isAvailable;

- (void)loadSymbolsFromHandle:(void *)handle;

/// Register the software DisplayChangeListener. QEMU thread only, after
/// qemu_init() and before qemu_main_loop().
- (void)startDisplayOnQemuThread;

- (BOOL)lockFrame:(UTMHuskFrame *)out;
- (void)unlockFrame;
- (uint64_t)frameSequence;
- (void)guestSizeWidth:(int32_t *)width height:(int32_t *)height;
- (void)sendPointerX:(int32_t)x y:(int32_t)y down:(BOOL)down;
- (BOOL)sendKey:(NSString *)qcode down:(BOOL)down;
- (void)requestUpdate;
- (NSInteger)pullAudio:(int16_t *)dst frames:(NSInteger)frames;
- (BOOL)audioActive;
- (void)balloonToBytes:(int64_t)bytes;

@end

@interface UTMQemuSystem : UTMProcess <QEMULauncher>

@property (nonatomic, nullable, copy) NSArray<NSURL *> *resources;
@property (nonatomic, nullable) NSDictionary<NSURL *, NSData *> *remoteBookmarks;
@property (nonatomic) UTMQEMURendererBackend rendererBackend;
@property (nonatomic) UTMQEMUVulkanDriver vulkanDriver;
@property (nonatomic) UTMQEMUDirectXDriver directXDriver;
@property (nonatomic) NSURL *shmemDirectoryURL;
@property (nonatomic, nullable) NSString *appSandboxGroupId;
@property (nonatomic, weak) id<QEMULauncherDelegate> launcherDelegate;
@property (nonatomic, nullable) QEMULogging *logging;
@property (nonatomic) BOOL hasDebugLog;
/// Register the Husk display listener once QEMU is initialised. Set before the
/// machine starts; harmless when the QEMU library was built without it.
@property (nonatomic) BOOL usesHuskBackend;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithArguments:(NSArray<NSString *> *)arguments NS_UNAVAILABLE;
- (instancetype)initWithArguments:(NSArray<NSString *> *)arguments architecture:(NSString *)architecture NS_DESIGNATED_INITIALIZER;
- (void)startQemuWithCompletion:(void(^)(NSError * _Nullable))completion;

@end

NS_ASSUME_NONNULL_END
