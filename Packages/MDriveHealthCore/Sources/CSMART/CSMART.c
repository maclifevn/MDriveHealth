/*
 * CSMART.c — implementation of the NVMe/ATA SMART bridge.
 *
 * NVMe plug-in UUIDs and vtable layout ported from smartmontools
 * os_darwin.h (GPL-2.0-or-later).
 *
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

#include "include/CSMART.h"

#include <stdlib.h>
#include <string.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/ata/ATASMARTLib.h>

/* ============================== NVMe ================================== */

#define kMDNVMeSMARTUserClientTypeID CFUUIDGetConstantUUIDWithBytes(NULL, \
    0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F, 0xB1, 0x0B,          \
    0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)

#define kMDNVMeSMARTInterfaceID CFUUIDGetConstantUUIDWithBytes(NULL,      \
    0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF, 0xBF, 0x95,          \
    0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)

/* Private interface exposed by NVMeSMARTLib.plugin (IONVMeFamily). */
typedef struct IONVMeSMARTInterface {
    IUNKNOWN_C_GUTS;

    UInt16 version;
    UInt16 revision;

    IOReturn (*SMARTReadData)(void *interface, MDNVMeSMARTLog *data);
    IOReturn (*GetIdentifyData)(void *interface, MDNVMeIdentifyController *data,
                                unsigned int ns);
    UInt64 reserved0;
    UInt64 reserved1;

    /* numDWords is zero-based (n means n+1 dwords). */
    IOReturn (*GetLogPage)(void *interface, void *data, unsigned int logPageId,
                           unsigned int numDWords);

    UInt64 reserved2;
    UInt64 reserved3;
    UInt64 reserved4;
    UInt64 reserved5;
    UInt64 reserved6;
    UInt64 reserved7;
    UInt64 reserved8;
    UInt64 reserved9;
    UInt64 reserved10;
    UInt64 reserved11;
    UInt64 reserved12;
    UInt64 reserved13;
    UInt64 reserved14;
    UInt64 reserved15;
    UInt64 reserved16;
    UInt64 reserved17;
    UInt64 reserved18;
    UInt64 reserved19;
} IONVMeSMARTInterface;

struct MDNVMeSession {
    IOCFPlugInInterface **plugin;
    IONVMeSMARTInterface **smart;
};

kern_return_t MDNVMeSessionCreate(io_service_t service, MDNVMeSession **outSession)
{
    if (outSession == NULL) return kIOReturnBadArgument;
    *outSession = NULL;

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kMDNVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID,
        &plugin, &score);
    if (kr != KERN_SUCCESS || plugin == NULL)
        return kr != KERN_SUCCESS ? kr : kIOReturnNoResources;

    IONVMeSMARTInterface **smart = NULL;
    HRESULT hr = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kMDNVMeSMARTInterfaceID), (LPVOID *)&smart);
    if (hr != S_OK || smart == NULL) {
        IODestroyPlugInInterface(plugin);
        return kIOReturnUnsupported;
    }

    MDNVMeSession *session = calloc(1, sizeof(MDNVMeSession));
    if (session == NULL) {
        (*smart)->Release(smart);
        IODestroyPlugInInterface(plugin);
        return kIOReturnNoMemory;
    }
    session->plugin = plugin;
    session->smart = smart;
    *outSession = session;
    return KERN_SUCCESS;
}

void MDNVMeSessionDestroy(MDNVMeSession *session)
{
    if (session == NULL) return;
    if (session->smart) (*session->smart)->Release(session->smart);
    if (session->plugin) IODestroyPlugInInterface(session->plugin);
    free(session);
}

kern_return_t MDNVMeReadSMARTLog(MDNVMeSession *session, MDNVMeSMARTLog *outLog)
{
    if (session == NULL || outLog == NULL) return kIOReturnBadArgument;
    memset(outLog, 0, sizeof(*outLog));
    return (*session->smart)->SMARTReadData(session->smart, outLog);
}

kern_return_t MDNVMeReadIdentify(MDNVMeSession *session,
                                 MDNVMeIdentifyController *outIdentify,
                                 uint32_t nsid)
{
    if (session == NULL || outIdentify == NULL) return kIOReturnBadArgument;
    memset(outIdentify, 0, sizeof(*outIdentify));
    return (*session->smart)->GetIdentifyData(session->smart, outIdentify, nsid);
}

/* =============================== ATA =================================== */

struct MDATASession {
    IOCFPlugInInterface **plugin;
    IOATASMARTInterface **smart;
};

kern_return_t MDATASessionCreate(io_service_t service, MDATASession **outSession)
{
    if (outSession == NULL) return kIOReturnBadArgument;
    *outSession = NULL;

    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kIOATASMARTUserClientTypeID, kIOCFPlugInInterfaceID,
        &plugin, &score);
    if (kr != KERN_SUCCESS || plugin == NULL)
        return kr != KERN_SUCCESS ? kr : kIOReturnNoResources;

    IOATASMARTInterface **smart = NULL;
    HRESULT hr = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIOATASMARTInterfaceID), (LPVOID *)&smart);
    if (hr != S_OK || smart == NULL) {
        IODestroyPlugInInterface(plugin);
        return kIOReturnUnsupported;
    }

    MDATASession *session = calloc(1, sizeof(MDATASession));
    if (session == NULL) {
        (*smart)->Release(smart);
        IODestroyPlugInInterface(plugin);
        return kIOReturnNoMemory;
    }
    session->plugin = plugin;
    session->smart = smart;
    *outSession = session;
    return KERN_SUCCESS;
}

void MDATASessionDestroy(MDATASession *session)
{
    if (session == NULL) return;
    if (session->smart) (*session->smart)->Release(session->smart);
    if (session->plugin) IODestroyPlugInInterface(session->plugin);
    free(session);
}

kern_return_t MDATASMARTEnable(MDATASession *session)
{
    if (session == NULL) return kIOReturnBadArgument;
    return (*session->smart)->SMARTEnableDisableOperations(session->smart, true);
}

kern_return_t MDATAReadSMARTData(MDATASession *session, uint8_t outData[512])
{
    if (session == NULL || outData == NULL) return kIOReturnBadArgument;
    ATASMARTData data;
    memset(&data, 0, sizeof(data));
    IOReturn ret = (*session->smart)->SMARTReadData(session->smart, &data);
    if (ret != kIOReturnSuccess) return ret;
    _Static_assert(sizeof(ATASMARTData) == 512, "ATA SMART data must be 512 bytes");
    const uint8_t *bytes = (const uint8_t *)&data;
    uint8_t checksum = 0;
    for (size_t i = 0; i < 512; i++) checksum += bytes[i];
    if (checksum != 0) return kIOReturnBadMedia;
    memcpy(outData, &data, 512);
    return kIOReturnSuccess;
}

kern_return_t MDATAReadSMARTThresholds(MDATASession *session, uint8_t outData[512])
{
    if (session == NULL || outData == NULL) return kIOReturnBadArgument;
    ATASMARTDataThresholds data;
    memset(&data, 0, sizeof(data));
    IOReturn ret = (*session->smart)->SMARTReadDataThresholds(session->smart, &data);
    if (ret != kIOReturnSuccess) return ret;
    _Static_assert(sizeof(ATASMARTDataThresholds) == 512,
                   "ATA SMART thresholds must be 512 bytes");
    const uint8_t *bytes = (const uint8_t *)&data;
    uint8_t checksum = 0;
    for (size_t i = 0; i < 512; i++) checksum += bytes[i];
    if (checksum != 0) return kIOReturnBadMedia;
    memcpy(outData, &data, 512);
    return kIOReturnSuccess;
}

kern_return_t MDATAReturnStatus(MDATASession *session, bool *outExceeded)
{
    if (session == NULL || outExceeded == NULL) return kIOReturnBadArgument;
    Boolean exceeded = false;
    IOReturn ret = (*session->smart)->SMARTReturnStatus(session->smart, &exceeded);
    if (ret != kIOReturnSuccess) return ret;
    *outExceeded = exceeded;
    return kIOReturnSuccess;
}

kern_return_t MDATAExecuteSelfTest(MDATASession *session, bool extended)
{
    if (session == NULL) return kIOReturnBadArgument;
    return (*session->smart)->SMARTExecuteOffLineImmediate(session->smart, extended);
}

kern_return_t MDATAReadIdentify(MDATASession *session, uint8_t outData[512])
{
    if (session == NULL || outData == NULL) return kIOReturnBadArgument;
    UInt32 outSize = 0;
    IOReturn ret = (*session->smart)->GetATAIdentifyData(session->smart, outData, 512, &outSize);
    if (ret != kIOReturnSuccess) return ret;
    return outSize == 512 ? kIOReturnSuccess : kIOReturnBadMedia;
}

kern_return_t MDATAReadLogAtAddress(MDATASession *session, uint8_t address,
                                    void *buffer, uint32_t size)
{
    if (session == NULL || buffer == NULL) return kIOReturnBadArgument;
    return (*session->smart)->SMARTReadLogAtAddress(session->smart, address,
                                                    buffer, size);
}
