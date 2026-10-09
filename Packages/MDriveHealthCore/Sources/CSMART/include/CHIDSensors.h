/*
 * CHIDSensors.h — declarations for the private IOHIDEventSystemClient API
 * used to read temperature sensors on Apple Silicon Macs (the same approach
 * as Stats/macmon/smctemp). These symbols live in IOKit.framework.
 *
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

#ifndef CHID_SENSORS_H
#define CHID_SENSORS_H

#include <CoreFoundation/CoreFoundation.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

/* kIOHIDEventTypeTemperature = 15; float field is (type << 16). */
#define kMDHIDEventTypeTemperature 15
#define kMDHIDTemperatureField (kMDHIDEventTypeTemperature << 16)

/* HID usage page/usage for Apple sensor services. */
#define kMDHIDUsagePageAppleVendor 0xff00
#define kMDHIDUsageAppleVendorTemperatureSensor 0x0005

IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
void IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client,
                                       CFDictionaryRef matching);
CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service,
                                         CFStringRef property);
IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service,
                                          int64_t type, int32_t options,
                                          int64_t timestamp);
double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

/* Convenience wrapper handling the copy/release cycle in C (CFRelease is not
 * callable from Swift): returns the service's current temperature in °C, or
 * -1 when the service has no temperature event. */
double MDHIDServiceReadTemperature(IOHIDServiceClientRef service);

#ifdef __cplusplus
}
#endif

#endif /* CHID_SENSORS_H */
