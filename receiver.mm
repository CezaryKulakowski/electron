#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <IOSurface/IOSurface.h>
#import <Foundation/Foundation.h>
#include <optional>
#import <mach/mach.h>
#import <servers/bootstrap.h>

#define SERVICE_NAME "com.mycompany.iosurface.test"

typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port; // The port we're transferring
} port_message_t;

@interface IOSurfaceView : NSView
@property (nonatomic, assign) IOSurfaceRef surface;
@end

@implementation IOSurfaceView
+ (Class)layerClass {
    return [CALayer class];
}

- (void)setSurface:(IOSurfaceRef)surface {
    if (_surface) CFRelease(_surface);
    _surface = surface;
    if (_surface) CFRetain(_surface);

    self.wantsLayer = YES;
    CALayer *layer = self.layer;
    layer.contents = (__bridge id)_surface;
    layer.contentsGravity = kCAGravityResizeAspect;
    layer.contentsScale = [NSScreen mainScreen].backingScaleFactor;
}


- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    if (!_surface) return;

    CIImage *image = [CIImage imageWithIOSurface:_surface];
    if (!image) {
        NSLog(@"⚠️ Failed to create CIImage from IOSurface");
        return;
    }

    CGContextRef cgContext = [[NSGraphicsContext currentContext] CGContext];
    if (!cgContext) {
        NSLog(@"❌ No current CGContext");
        return;
    }

    CIContext *ciContext = [CIContext contextWithCGContext:cgContext options:nil];

    CGRect bounds = NSRectToCGRect(self.bounds);
    [ciContext drawImage:image inRect:bounds fromRect:image.extent];
}

- (void)dealloc {
    if (_surface) CFRelease(_surface);
    [super dealloc];
}
@end

std::optional<mach_port_t> ReceivePort() {
    kern_return_t kr;
    mach_port_t receivePort;

    // Step 1: Allocate a receive right
    kr = mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &receivePort);
    if (kr != KERN_SUCCESS) {
        NSLog(@"❌ Failed to allocate receive port: %s", mach_error_string(kr));
        return std::nullopt;
    }

    // Step 2: Insert send right (needed for bootstrap registration)
    kr = mach_port_insert_right(mach_task_self(), receivePort, receivePort, MACH_MSG_TYPE_MAKE_SEND);
    if (kr != KERN_SUCCESS) {
        NSLog(@"❌ Failed to insert send right: %s", mach_error_string(kr));
        return std::nullopt;
    }

    // Step 3: Register port under a service name
    kr = bootstrap_register(bootstrap_port, SERVICE_NAME, receivePort);
    if (kr != KERN_SUCCESS) {
        NSLog(@"❌ bootstrap_register failed: %s", mach_error_string(kr));
        return std::nullopt;
    }

    NSLog(@"✅ Receiver is ready and waiting for a message...");

    // Step 4: Receive the message into a large enough buffer
    uint8_t buffer[4096] = {0};
    mach_msg_header_t *header = (mach_msg_header_t *)buffer;

    kr = mach_msg(header,
                  MACH_RCV_MSG,
                  0,
                  sizeof(buffer),
                  receivePort,
                  MACH_MSG_TIMEOUT_NONE,
                  MACH_PORT_NULL);

    if (kr != KERN_SUCCESS) {
        NSLog(@"❌ mach_msg receive failed: %s (%d)", mach_error_string(kr), kr);
        return std::nullopt;
    }

    // Step 5: Extract the received port from the message
    port_message_t *msg = (port_message_t *)header;
    mach_port_t received = msg->port.name;

    NSLog(@"✅ Received mach port: %u", received);

    // Optional: Verify what kind of port we got
    mach_port_type_t type;
    kr = mach_port_type(mach_task_self(), received, &type);
    if (kr == KERN_SUCCESS) {
        NSLog(@"🔍 Received port type: 0x%x", type);
    } else {
        NSLog(@"⚠️ Failed to get port type: %s", mach_error_string(kr));
        return std::nullopt;
    }

    return received;
}

int main() {
  auto maybe_port = ReceivePort();
  if (maybe_port == std::nullopt) {
    return -1;
  }
  mach_port_t receivedMachPort = *maybe_port;
  @autoreleasepool {
        // Convert mach_port_t to IOSurfaceRef
        IOSurfaceRef surface = IOSurfaceLookupFromMachPort(receivedMachPort);
        if (!surface) {
            NSLog(@"❌ Failed to lookup IOSurface");
            return 1;
        }

        // Setup Cocoa App
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        NSRect frame = NSMakeRect(100, 100,
                                  IOSurfaceGetWidth(surface),
                                  IOSurfaceGetHeight(surface));

        NSWindow *window = [[NSWindow alloc] initWithContentRect:frame
                                                       styleMask:(NSWindowStyleMaskTitled |
                                                                  NSWindowStyleMaskClosable |
                                                                  NSWindowStyleMaskResizable)
                                                         backing:NSBackingStoreBuffered
                                                           defer:NO];
        [window setTitle:@"IOSurface Viewer"];

        IOSurfaceView* view = [[IOSurfaceView alloc] initWithFrame:frame];
        [view setSurface:surface];
        [view setWantsLayer:YES];
        [window setContentView:view];

        [window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        [NSTimer scheduledTimerWithTimeInterval:1.0/60.0
                                        repeats:YES
                                          block: ^void(NSTimer* timer) {
                                            //dispatch_async(dispatch_get_main_queue(), ^{
                                              [[window contentView] setNeedsDisplay:YES];
                                              [[window contentView] displayIfNeeded];
                                            //});
                                          }
        ];
        [NSApp run];
    }
    return 0;
}
