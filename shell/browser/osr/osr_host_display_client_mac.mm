// Copyright (c) 2019 GitHub, Inc.
// Use of this source code is governed by the MIT license that can be
// found in the LICENSE file.

#include "shell/browser/osr/osr_host_display_client.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkImageInfo.h"

#include <IOSurface/IOSurface.h>

#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <servers/bootstrap.h>
#include <iostream>

#import <sys/socket.h>
#import <sys/un.h>
#import <unistd.h>

#include "base/command_line.h"
#include "base/strings/string_number_conversions.h"

namespace electron {

#define SERVICE_NAME "com.mycompany.iosurface.test"

IOSurfaceRef GetSharedSurface() {
  static IOSurfaceRef shared_surface = nil;
  if (shared_surface == nil) {
    const int width = 640;
    const int height = 480;
    NSDictionary* props = @{
      (__bridge NSString*)kIOSurfaceWidth : @(width),
      (__bridge NSString*)kIOSurfaceHeight : @(height),
      (__bridge NSString*)kIOSurfaceBytesPerElement : @4,
      (__bridge NSString*)kIOSurfacePixelFormat : @(kCVPixelFormatType_32BGRA)
    };
    shared_surface = IOSurfaceCreate((__bridge CFDictionaryRef)props);
  }
  return shared_surface;
}

void MaybeSendMachPortForSharedSurface() {
  static bool port_sent = false;
  if (port_sent) {
    return;
  }
  port_sent = true;

  IOSurfaceRef shared_surface = GetSharedSurface();
  mach_port_t port_to_send = IOSurfaceCreateMachPort(shared_surface);

  mach_port_t remote_port;
  auto kr = bootstrap_look_up(bootstrap_port, SERVICE_NAME, &remote_port);
  if (kr != KERN_SUCCESS) {
    NSLog(@"❌ bootstrap_look_up failed: %d", kr);
    return;
  }
  struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t port_descriptor;
  } message;

  message.header.msgh_bits =
      MACH_MSGH_BITS_COMPLEX | MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
  message.header.msgh_size = sizeof(message);
  message.header.msgh_remote_port = remote_port;
  message.header.msgh_local_port = MACH_PORT_NULL;
  message.header.msgh_id = 100;

  message.body.msgh_descriptor_count = 1;
  message.port_descriptor.name = port_to_send;
  message.port_descriptor.disposition = MACH_MSG_TYPE_COPY_SEND;
  message.port_descriptor.type = MACH_MSG_PORT_DESCRIPTOR;

  auto res = mach_msg(&message.header, MACH_SEND_MSG, message.header.msgh_size,
                      0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
  if (res != KERN_SUCCESS) {
    NSLog(@"❌ mach_msg send failed: %d", kr);
    return;
  }
  NSLog(@"✅ Successfully sent iosurface");
}

void RefreshSharedSurface(mach_port_t new_surface_mach_port) {
  MaybeSendMachPortForSharedSurface();
  IOSurfaceRef shared_surface = GetSharedSurface();
  base::apple::ScopedCFTypeRef<IOSurfaceRef> new_surface(
      IOSurfaceLookupFromMachPort(new_surface_mach_port));
  CIImage* input = [CIImage imageWithIOSurface:new_surface.get()];
  CIContext* context = [CIContext contextWithOptions:nil];

  CGRect rect = CGRectMake(0, 0, 640, 480);
  CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);

  [context render:input
      toIOSurface:shared_surface
           bounds:rect
       colorSpace:colorSpace];

  CGColorSpaceRelease(colorSpace);
}

void OffScreenHostDisplayClient::OnDisplayReceivedCALayerParams(
    const gfx::CALayerParams& ca_layer_params) {
  std::cout << "OnDisplayReceivedCALayerParams: " << ca_layer_params.is_empty
            << std::endl;
  if (!ca_layer_params.is_empty) {
    RefreshSharedSurface(ca_layer_params.io_surface_mach_port.get());
    /*
    base::apple::ScopedCFTypeRef<IOSurfaceRef> io_surface(
        IOSurfaceLookupFromMachPort(
            ca_layer_params.io_surface_mach_port.get()));
    CIImage* inputImage = [CIImage imageWithIOSurface:io_surface.get()];
    CIContext* ciContext = [CIContext contextWithOptions:nil];
    IOSurfaceRef destSurface = nullptr;
    gfx::Size surface_size = ca_layer_params.pixel_size;
    CGRect rect = CGRectMake(0, 0, surface_size.width(), surface_size.height());
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    [ciContext render:inputImage toIOSurface:destSurface bounds:rect
    colorSpace:colorSpace]; SendMachPort(IOSurfaceCreateMachPort(destSurface));

    gfx::Size pixel_size_ = ca_layer_params.pixel_size;
    void* pixels =
        static_cast<void*>(IOSurfaceGetBaseAddress(io_surface.get()));
    size_t stride = IOSurfaceGetBytesPerRow(io_surface.get());

    struct IOSurfacePinner {
      base::apple::ScopedCFTypeRef<IOSurfaceRef> io_surface;
    };

    SkBitmap bitmap;
    bitmap.installPixels(
        SkImageInfo::MakeN32(pixel_size_.width(), pixel_size_.height(),
                             kPremul_SkAlphaType),
        pixels, stride);
    bitmap.setImmutable();
    callback_.Run(ca_layer_params.damage, bitmap, {});
    */
  }
}

}  // namespace electron
