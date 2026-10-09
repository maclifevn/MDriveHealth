/*
 * CHIDSensors.c — temperature read helper over private IOHID APIs.
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

#include "include/CHIDSensors.h"

double MDHIDServiceReadTemperature(IOHIDServiceClientRef service)
{
    if (service == NULL) return -1;
    IOHIDEventRef event = IOHIDServiceClientCopyEvent(
        service, kMDHIDEventTypeTemperature, 0, 0);
    if (event == NULL) return -1;
    double value = IOHIDEventGetFloatValue(event, kMDHIDTemperatureField);
    CFRelease(event);
    return value;
}
