#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>

#include <mach/mach.h>

#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "TrackIRUSB.h"
#include "TrackIRUSBTransport.h"

static void print_usage(const char *program)
{
  fprintf(stderr, "Usage: %s [--seize|--capture] [--exercise]\n", program);
}

static void print_error(const char *operation, NSError *error)
{
  if (error != nil) {
    fprintf(stderr, "%s failed: %s (0x%08x)\n", operation,
            [[error localizedDescription] UTF8String],
            (unsigned int)[error code]);
  } else {
    fprintf(stderr, "%s failed\n", operation);
  }
}

static void print_bytes(const unsigned char *data, NSUInteger size)
{
  for (NSUInteger index = 0; index < size; ++index) {
    printf(" %02x", data[index]);
  }
  printf("\n");
}

static bool exercise_control_request(TrackIRUSBTransport *transport)
{
  IOUSBDeviceRequest request = {};
  request.bmRequestType = IOUSBHostDeviceRequestType(
      kIOUSBDeviceRequestDirectionValueIn,
      kIOUSBDeviceRequestTypeValueStandard,
      kIOUSBDeviceRequestRecipientValueDevice);
  request.bRequest = kIOUSBDeviceRequestGetDescriptor;
  request.wValue = static_cast<uint16_t>(1u << 8); // Device descriptor.
  request.wIndex = 0;
  request.wLength = static_cast<uint16_t>(sizeof(IOUSBDeviceDescriptor));

  NSMutableData *data = [NSMutableData dataWithLength:sizeof(IOUSBDeviceDescriptor)];
  NSUInteger bytesTransferred = 0;
  NSError *error = nil;
  if (![transport sendControlRequest:request
                                data:data
                    bytesTransferred:&bytesTransferred
                              timeout:0.5
                                error:&error]) {
    print_error("GET_DESCRIPTOR control request", error);
    return false;
  }
  if (bytesTransferred != sizeof(IOUSBDeviceDescriptor)) {
    fprintf(stderr,
            "GET_DESCRIPTOR returned %lu bytes, expected %lu\n",
            (unsigned long)bytesTransferred,
            (unsigned long)sizeof(IOUSBDeviceDescriptor));
    return false;
  }

  IOUSBDeviceDescriptor descriptor = {};
  memcpy(&descriptor, data.bytes, sizeof(descriptor));
  printf("control GET_DESCRIPTOR succeeded: %lu bytes, %04x:%04x\n",
         (unsigned long)bytesTransferred, descriptor.idVendor,
         descriptor.idProduct);
  if (descriptor.idVendor != TRACKIR_USB_VENDOR_ID ||
      descriptor.idProduct != TRACKIR_USB_PRODUCT_ID) {
    fprintf(stderr, "GET_DESCRIPTOR returned an unexpected device identity\n");
    return false;
  }
  return true;
}

static bool send_bulk_command(TrackIRUSBTransport *transport,
                              const char *operation,
                              const unsigned char *command, NSUInteger size)
{
  NSData *data = [NSData dataWithBytes:command length:size];
  NSUInteger bytesTransferred = 0;
  NSError *error = nil;
  if (![transport sendBulkData:data
              bytesTransferred:&bytesTransferred
                        timeout:0.5
                          error:&error]) {
    print_error(operation, error);
    return false;
  }
  if (bytesTransferred != size) {
    fprintf(stderr, "%s transferred %lu bytes, expected %lu\n", operation,
            (unsigned long)bytesTransferred, (unsigned long)size);
    return false;
  }
  printf("%s succeeded: endpoint 0x%02x, %lu bytes\n", operation,
         transport.bulkOutEndpointAddress, (unsigned long)bytesTransferred);
  return true;
}

static bool read_bulk_packet(TrackIRUSBTransport *transport, const char *operation,
                             NSMutableData *data, NSUInteger *bytesTransferred,
                             bool *timedOut)
{
  NSError *error = nil;
  *bytesTransferred = 0;
  *timedOut = false;
  if (![transport receiveBulkData:data
                 bytesTransferred:bytesTransferred
                           timeout:0.5
                             error:&error]) {
    if (error != nil && [error code] == kIOReturnTimeout) {
      *timedOut = true;
      return false;
    }
    print_error(operation, error);
    return false;
  }
  return true;
}

static bool drain_bulk_input(TrackIRUSBTransport *transport)
{
  for (unsigned int attempt = 0; attempt < 4; ++attempt) {
    NSMutableData *data = [NSMutableData dataWithLength:64];
    NSUInteger bytesTransferred = 0;
    bool timedOut = false;
    if (!read_bulk_packet(transport, "drain bulk IN", data,
                          &bytesTransferred, &timedOut)) {
      if (timedOut) {
        return true;
      }
      return false;
    }
    if (bytesTransferred == 0) {
      return true;
    }
    printf("drained bulk IN packet: endpoint 0x%02x, %lu bytes:\n",
           transport.bulkInEndpointAddress, (unsigned long)bytesTransferred);
    print_bytes(reinterpret_cast<const unsigned char *>(data.bytes),
                bytesTransferred);
  }
  return true;
}

static bool stop_tir5v2_for_diagnostic(TrackIRUSBTransport *transport)
{
  // Match stop_camera_tir5v2() before read_rom_data_tir() in tir_hw.c.
  const unsigned char cameraStop[] = {0x13};
  const unsigned char irOff[] = {0x19, 0x09, 0x10, 0x00, 0x00};
  const unsigned char statusLedOff[] = {0x19, 0x04, 0x10, 0x00, 0x00};

  usleep(5000);
  if (!send_bulk_command(transport, "TIR5V2 camera stop", cameraStop,
                         sizeof(cameraStop))) {
    return false;
  }
  if (!send_bulk_command(transport, "TIR5V2 IR LED off", irOff,
                         sizeof(irOff))) {
    return false;
  }
  if (!send_bulk_command(transport, "TIR5V2 status LED off", statusLedOff,
                         sizeof(statusLedOff))) {
    return false;
  }
  usleep(10000);
  return true;
}

static bool exercise_bulk_transfers(TrackIRUSBTransport *transport)
{
  static const unsigned int kRequestAttempts = 3;
  static const unsigned int kReadsPerRequest = 4;

  if (!stop_tir5v2_for_diagnostic(transport)) {
    return false;
  }

  // Match the read_rom_data_tir() preamble before read_status_tir().
  if (!drain_bulk_input(transport)) {
    return false;
  }

  const unsigned char configRequest[] = {0x17};
  bool configReceived = false;
  for (unsigned int requestAttempt = 0;
       requestAttempt < kRequestAttempts && !configReceived; ++requestAttempt) {
    if (!send_bulk_command(transport, "config bulk OUT request", configRequest,
                           sizeof(configRequest))) {
      return false;
    }
    for (unsigned int readAttempt = 0; readAttempt < kReadsPerRequest;
         ++readAttempt) {
      NSMutableData *configResponseData = [NSMutableData dataWithLength:64];
      NSUInteger bytesTransferred = 0;
      bool timedOut = false;
      if (!read_bulk_packet(transport, "config bulk IN response",
                            configResponseData, &bytesTransferred, &timedOut)) {
        if (timedOut) {
          fprintf(stderr, "config bulk IN response timed out (attempt %u/%u)\n",
                  requestAttempt + 1, kRequestAttempts);
          break;
        }
        return false;
      }
      if (bytesTransferred == 0) {
        continue;
      }
      printf("bulk IN config response: endpoint 0x%02x, %lu bytes:\n",
             transport.bulkInEndpointAddress, (unsigned long)bytesTransferred);
      print_bytes(reinterpret_cast<const unsigned char *>(configResponseData.bytes),
                  bytesTransferred);
      const unsigned char *configResponse =
          reinterpret_cast<const unsigned char *>(configResponseData.bytes);
      if (bytesTransferred >= 3 && configResponse[1] == 0x40) {
        configReceived = true;
        break;
      }
      fprintf(stderr, "config bulk IN response has an unexpected packet header\n");
    }
  }
  if (!configReceived) {
    fprintf(stderr, "config bulk IN response was not received after %u requests\n",
            kRequestAttempts);
    return false;
  }

  // This is the status request used by read_status_tir() in tir_hw.c.
  const unsigned char statusRequest[] = {0x1d};
  bool statusReceived = false;
  for (unsigned int requestAttempt = 0;
       requestAttempt < kRequestAttempts && !statusReceived; ++requestAttempt) {
    if (!send_bulk_command(transport, "status bulk OUT request", statusRequest,
                           sizeof(statusRequest))) {
      return false;
    }

    for (unsigned int readAttempt = 0; readAttempt < kReadsPerRequest;
         ++readAttempt) {
      NSMutableData *statusResponseData = [NSMutableData dataWithLength:64];
      NSUInteger bytesTransferred = 0;
      bool timedOut = false;
      if (!read_bulk_packet(transport, "status bulk IN response",
                            statusResponseData, &bytesTransferred, &timedOut)) {
        if (timedOut) {
          fprintf(stderr,
                  "status bulk IN response timed out (attempt %u/%u)\n",
                  requestAttempt + 1, kRequestAttempts);
          break;
        }
        return false;
      }
      if (bytesTransferred == 0) {
        continue;
      }
      printf("bulk IN status response: endpoint 0x%02x, %lu bytes:\n",
             transport.bulkInEndpointAddress, (unsigned long)bytesTransferred);
      print_bytes(reinterpret_cast<const unsigned char *>(statusResponseData.bytes),
                  bytesTransferred);
      if (bytesTransferred >= 3) {
        const unsigned char *statusResponse =
            reinterpret_cast<const unsigned char *>(statusResponseData.bytes);
        if (statusResponse[0] == 0x07 && statusResponse[1] == 0x20) {
          statusReceived = true;
          break;
        }
      }
      fprintf(stderr, "status bulk IN response has an unexpected packet header\n");
    }
  }
  if (!statusReceived) {
    fprintf(stderr, "status bulk IN response was not received after %u requests\n",
            kRequestAttempts);
  }
  return statusReceived;
}

static bool print_transport(TrackIRUSBTransport *transport, bool exercise)
{
  printf("TrackIR interface opened through IOUSBHost: %04x:%04x\n",
         transport.vendorID, transport.productID);
  printf("configuration %u, interface %u alt %u, class %02x/%02x/%02x\n",
         transport.configurationValue, transport.interfaceNumber,
         transport.alternateSetting, transport.interfaceClass,
         transport.interfaceSubclass, transport.interfaceProtocol);
  printf("endpoint 0x%02x attributes 0x%02x max packet %u interval %u\n",
         transport.bulkOutEndpointAddress, transport.bulkOutAttributes,
         transport.bulkOutMaxPacketSize, transport.bulkOutInterval);
  printf("  pipe ready at endpoint 0x%02x\n",
         transport.bulkOutEndpointAddress);
  printf("endpoint 0x%02x attributes 0x%02x max packet %u interval %u\n",
         transport.bulkInEndpointAddress, transport.bulkInAttributes,
         transport.bulkInMaxPacketSize, transport.bulkInInterval);
  printf("  pipe ready at endpoint 0x%02x\n", transport.bulkInEndpointAddress);

  if (!exercise) {
    return true;
  }
  if (!exercise_control_request(transport)) {
    return false;
  }
  return exercise_bulk_transfers(transport);
}

static int probe(IOUSBHostObjectInitOptions options, bool exercise)
{
  CFMutableDictionaryRef matching =
      [IOUSBHostInterface createMatchingDictionaryWithVendorID:
                                      @(TRACKIR_USB_VENDOR_ID)
                                      productID:@(TRACKIR_USB_PRODUCT_ID)
                                      bcdDevice:nil
                                      interfaceNumber:@(
                                          TRACKIR_USB_INTERFACE_NUMBER)
                                      configurationValue:@(
                                          TRACKIR_USB_CONFIGURATION_VALUE)
                                      interfaceClass:nil
                                      interfaceSubclass:nil
                                      interfaceProtocol:nil
                                      speed:nil
                                      productIDArray:nil];
  if (matching == nullptr) {
    fprintf(stderr, "TrackIR: unable to create IOUSBHost matching dictionary\n");
    return 1;
  }

  io_iterator_t iterator = IO_OBJECT_NULL;
  kern_return_t ret = IOServiceGetMatchingServices(MACH_PORT_NULL, matching,
                                                     &iterator);
  if (ret != kIOReturnSuccess) {
    fprintf(stderr, "TrackIR: IOServiceGetMatchingServices failed: 0x%08x\n",
            (unsigned int)ret);
    return 1;
  }

  io_service_t service = IO_OBJECT_NULL;
  bool matched = false;
  bool opened = false;
  int result = 1;
  while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
    matched = true;
    NSError *error = nil;
    TrackIRUSBTransport *transport =
        [[TrackIRUSBTransport alloc] initWithIOService:service
                                               options:options
                                                 error:&error];
    IOObjectRelease(service);
    service = IO_OBJECT_NULL;

    if (transport == nil) {
      print_error("init TrackIRUSBTransport", error);
      continue;
    }

    opened = true;
    result = print_transport(transport, exercise) ? 0 : 1;
    [transport destroy];
    break;
  }

  if (service != IO_OBJECT_NULL) {
    IOObjectRelease(service);
  }
  IOObjectRelease(iterator);
  if (!matched) {
    fprintf(stderr, "TrackIR: no matching TIR5V2 interface is currently connected\n");
  } else if (!opened) {
    fprintf(stderr,
            "TrackIR: no usable TIR5V2 interface found (another driver may own it)\n");
  } else if (result != 0) {
    fprintf(stderr, "TrackIR: TIR5V2 interface opened, but the diagnostic failed\n");
  }
  return result;
}

int main(int argc, char **argv)
{
  @autoreleasepool {
    IOUSBHostObjectInitOptions options = IOUSBHostObjectInitOptionsNone;
    bool exercise = false;
    for (int index = 1; index < argc; ++index) {
      if (strcmp(argv[index], "--seize") == 0) {
        options = IOUSBHostObjectInitOptionsDeviceSeize;
      } else if (strcmp(argv[index], "--capture") == 0) {
        options = IOUSBHostObjectInitOptionsDeviceCapture;
      } else if (strcmp(argv[index], "--exercise") == 0) {
        exercise = true;
      } else {
        print_usage(argv[0]);
        return 2;
      }
    }
    return probe(options, exercise);
  }
}
