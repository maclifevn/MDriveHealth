/*
 * CSMART.h — C bridge for macOS SMART access (NVMe + ATA).
 *
 * NVMe: wraps the private NVMeSMARTLib IOKit plug-in interface.
 *   Interface layout and UUIDs ported from smartmontools os_darwin.h
 *   (GPL-2.0-or-later), see https://www.smartmontools.org
 * ATA: wraps the public ATASMARTLib IOKit plug-in interface.
 *
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

#ifndef CSMART_H
#define CSMART_H

#include <stdint.h>
#include <stdbool.h>
#include <IOKit/IOKitLib.h>

#include "CHIDSensors.h"
#include "CMeasurementCancellation.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ============================== NVMe ================================== */

/* NVMe SMART / Health Information Log (log page 02h), NVMe spec layout. */
typedef struct {
    uint8_t  criticalWarning;
    uint8_t  temperature[2];            /* composite, Kelvin, LE */
    uint8_t  availableSpare;            /* % */
    uint8_t  availableSpareThreshold;   /* % */
    uint8_t  percentageUsed;            /* % of rated endurance, may exceed 100 */
    uint8_t  reserved6[26];
    uint8_t  dataUnitsRead[16];         /* unit = 1000 * 512 bytes, LE 128-bit */
    uint8_t  dataUnitsWritten[16];
    uint8_t  hostReadCommands[16];
    uint8_t  hostWriteCommands[16];
    uint8_t  controllerBusyTime[16];    /* minutes */
    uint8_t  powerCycles[16];
    uint8_t  powerOnHours[16];
    uint8_t  unsafeShutdowns[16];
    uint8_t  mediaErrors[16];
    uint8_t  errorLogEntries[16];
    uint32_t warningTempTime;           /* minutes */
    uint32_t criticalCompTime;          /* minutes */
    uint16_t temperatureSensor[8];      /* Kelvin */
    uint32_t thmTemp1TransCount;
    uint32_t thmTemp2TransCount;
    uint32_t thmTemp1TotalTime;
    uint32_t thmTemp2TotalTime;
    uint8_t  reserved232[280];
} MDNVMeSMARTLog;

_Static_assert(sizeof(MDNVMeSMARTLog) == 512, "NVMe SMART log must be 512 bytes");

/* NVMe Identify Controller data structure (CNS 01h), NVMe spec layout. */
typedef struct {
    uint16_t vid;
    uint16_t ssvid;
    char     serialNumber[20];          /* space padded, not NUL terminated */
    char     modelNumber[40];
    char     firmwareRevision[8];
    uint8_t  rab;
    uint8_t  ieee[3];
    uint8_t  cmic;
    uint8_t  mdts;
    uint16_t cntlid;
    uint32_t ver;
    uint32_t rtd3r;
    uint32_t rtd3e;
    uint32_t oaes;
    uint32_t ctratt;
    uint8_t  reserved100[156];
    uint16_t oacs;
    uint8_t  acl;
    uint8_t  aerl;
    uint8_t  frmw;
    uint8_t  lpa;
    uint8_t  elpe;
    uint8_t  npss;
    uint8_t  avscc;
    uint8_t  apsta;
    uint16_t wctemp;                    /* warning composite temp, Kelvin */
    uint16_t cctemp;                    /* critical composite temp, Kelvin */
    uint16_t mtfa;
    uint32_t hmpre;
    uint32_t hmmin;
    uint8_t  tnvmcap[16];               /* total NVM capacity, bytes, LE 128-bit */
    uint8_t  unvmcap[16];
    uint32_t rpmbs;
    uint16_t edstt;
    uint8_t  dsto;
    uint8_t  fwug;
    uint16_t kas;
    uint16_t hctma;
    uint16_t mntmt;
    uint16_t mxtmt;
    uint32_t sanicap;
    uint8_t  reserved332[180];
    uint8_t  sqes;
    uint8_t  cqes;
    uint16_t maxcmd;
    uint32_t nn;
    uint16_t oncs;
    uint16_t fuses;
    uint8_t  fna;
    uint8_t  vwc;
    uint16_t awun;
    uint16_t awupf;
    uint8_t  nvscc;
    uint8_t  reserved531;
    uint16_t acwu;
    uint8_t  reserved534[2];
    uint32_t sgls;
    uint8_t  reserved540[228];
    char     subnqn[256];
    uint8_t  reserved1024[768];
    uint32_t ioccsz;
    uint32_t iorcsz;
    uint16_t icdoff;
    uint8_t  ctrattr;
    uint8_t  msdbd;
    uint8_t  reserved1804[244];
    uint8_t  powerStateDescriptors[32][32];
    uint8_t  vendorSpecific[1024];
} MDNVMeIdentifyController;

_Static_assert(sizeof(MDNVMeIdentifyController) == 4096, "NVMe identify must be 4096 bytes");

typedef struct MDNVMeSession MDNVMeSession;

/* Creates a SMART session on an IOKit service whose registry entry carries
 * "NVMe SMART Capable" = Yes (an IOBlockStorageDevice subclass). */
kern_return_t MDNVMeSessionCreate(io_service_t service, MDNVMeSession **outSession);
void MDNVMeSessionDestroy(MDNVMeSession *session);
kern_return_t MDNVMeReadSMARTLog(MDNVMeSession *session, MDNVMeSMARTLog *outLog);
kern_return_t MDNVMeReadIdentify(MDNVMeSession *session, MDNVMeIdentifyController *outIdentify,
                                 uint32_t nsid);

/* =============================== ATA =================================== */

typedef struct MDATASession MDATASession;

/* Creates a SMART session on an IOKit service whose registry entry carries
 * "SMART Capable" = Yes. */
kern_return_t MDATASessionCreate(io_service_t service, MDATASession **outSession);
void MDATASessionDestroy(MDATASession *session);

kern_return_t MDATASMARTEnable(MDATASession *session);
/* Raw 512-byte SMART READ DATA structure (bytes 2..361 hold 30 x 12-byte
 * attribute entries). */
kern_return_t MDATAReadSMARTData(MDATASession *session, uint8_t outData[512]);
/* Raw 512-byte SMART READ THRESHOLDS structure. */
kern_return_t MDATAReadSMARTThresholds(MDATASession *session, uint8_t outData[512]);
/* SMART RETURN STATUS: true if thresholds exceeded (drive failing). */
kern_return_t MDATAReturnStatus(MDATASession *session, bool *outExceeded);
/* Starts an offline self-test (short or extended). */
kern_return_t MDATAExecuteSelfTest(MDATASession *session, bool extended);
/* Raw 512-byte ATA IDENTIFY DEVICE data. */
kern_return_t MDATAReadIdentify(MDATASession *session, uint8_t outData[512]);
/* SMART READ LOG at the given address (0x00 directory, 0x06 self-test log...). */
kern_return_t MDATAReadLogAtAddress(MDATASession *session, uint8_t address,
                                    void *buffer, uint32_t size);

#ifdef __cplusplus
}
#endif

#endif /* CSMART_H */
