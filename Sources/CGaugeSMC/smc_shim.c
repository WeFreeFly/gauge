// SPDX-License-Identifier: Apache-2.0
#include "include/smc_shim.h"

#include <string.h>
#include <IOKit/IOKitLib.h>

typedef struct { uint8_t major, minor, build, reserved; uint16_t release; } SMCVersion;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimitData;
typedef struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } SMCKeyInfoData;

typedef struct {
    uint32_t       key;
    SMCVersion     vers;
    SMCPLimitData  pLimitData;
    SMCKeyInfoData keyInfo;
    uint8_t        result;
    uint8_t        status;
    uint8_t        data8;
    uint32_t       data32;
    uint8_t        bytes[32];
} SMCKeyData;

// data8 selectors understood by the SMC user client
enum {
    kSMCReadBytes   = 5,
    kSMCWriteBytes  = 6,
    kSMCKeyFromIndex = 8,
    kSMCGetKeyInfo  = 9,
};

#define kSMCHandleYPCEvent 2

static io_connect_t g_conn = 0;

bool gauge_smc_open(void) {
    if (g_conn != 0) return true;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (service == 0) return false;
    kern_return_t r = IOServiceOpen(service, mach_task_self(), 0, &g_conn);
    IOObjectRelease(service);
    if (r != kIOReturnSuccess) { g_conn = 0; return false; }
    return true;
}

void gauge_smc_close(void) {
    if (g_conn == 0) return;
    IOServiceClose(g_conn);
    g_conn = 0;
}

static uint32_t four_cc(const char *s) {
    if (s == NULL) return 0;
    uint32_t v = 0;
    for (int i = 0; i < 4 && s[i] != '\0'; i++) v = (v << 8) | (uint8_t)s[i];
    return v;
}

static bool smc_call(SMCKeyData *in, SMCKeyData *out) {
    if (g_conn == 0 && !gauge_smc_open()) return false;
    size_t out_size = sizeof(SMCKeyData);
    kern_return_t r = IOConnectCallStructMethod(g_conn, kSMCHandleYPCEvent,
                                                in, sizeof(SMCKeyData),
                                                out, &out_size);
    return r == kIOReturnSuccess;
}

static bool smc_key_info(uint32_t key, SMCKeyInfoData *info) {
    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = key;
    in.data8 = kSMCGetKeyInfo;
    if (!smc_call(&in, &out)) return false;
    if (out.keyInfo.dataSize == 0 || out.keyInfo.dataSize > GAUGE_SMC_MAX_BYTES) return false;
    *info = out.keyInfo;
    return true;
}

bool gauge_smc_read(const char *key, gauge_smc_value *out_value) {
    if (out_value == NULL) return false;
    uint32_t k = four_cc(key);
    SMCKeyInfoData info;
    if (!smc_key_info(k, &info)) return false;

    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = k;
    in.data8 = kSMCReadBytes;
    in.keyInfo = info;
    if (!smc_call(&in, &out)) return false;

    memset(out_value, 0, sizeof *out_value);
    out_value->type = info.dataType;
    out_value->size = info.dataSize;
    memcpy(out_value->bytes, out.bytes, info.dataSize);
    return true;
}

uint32_t gauge_smc_key_count(void) {
    gauge_smc_value v;
    if (!gauge_smc_read("#KEY", &v) || v.size < 4) return 0;
    return ((uint32_t)v.bytes[0] << 24) | ((uint32_t)v.bytes[1] << 16)
         | ((uint32_t)v.bytes[2] << 8)  | (uint32_t)v.bytes[3];
}

bool gauge_smc_key_at_index(uint32_t index, char *out) {
    if (out == NULL) return false;
    SMCKeyData in, res;
    memset(&in, 0, sizeof in);
    memset(&res, 0, sizeof res);
    in.data8 = kSMCKeyFromIndex;
    in.data32 = index;
    if (!smc_call(&in, &res)) return false;
    out[0] = (char)(res.key >> 24);
    out[1] = (char)(res.key >> 16);
    out[2] = (char)(res.key >> 8);
    out[3] = (char)(res.key);
    out[4] = '\0';
    return res.key != 0;
}

bool gauge_smc_write(const char *key, const uint8_t *bytes, uint32_t size) {
    if (bytes == NULL || size == 0 || size > GAUGE_SMC_MAX_BYTES) return false;
    uint32_t k = four_cc(key);
    SMCKeyInfoData info;
    if (!smc_key_info(k, &info)) return false;
    if (info.dataSize != size) return false;

    SMCKeyData in, out;
    memset(&in, 0, sizeof in);
    memset(&out, 0, sizeof out);
    in.key = k;
    in.data8 = kSMCWriteBytes;
    in.keyInfo = info;
    memcpy(in.bytes, bytes, size);
    return smc_call(&in, &out);
}
