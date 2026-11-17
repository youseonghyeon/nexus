// AppleSMC 온도 센서·팬 읽기. 원본: ~/.tools/stats-helpers/smctemp.c (같은 구조체·명령 번호). 설명은 include/csmc.h.
#include "csmc.h"
#include <IOKit/IOKitLib.h>
#include <math.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#define KERNEL_INDEX_SMC 2
#define SMC_CMD_READ_BYTES 5
#define SMC_CMD_READ_INDEX 8
#define SMC_CMD_READ_KEYINFO 9

typedef struct { char major, minor, build, reserved; uint16_t release; } SMCKeyData_vers_t;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCKeyData_pLimitData_t;
typedef struct { uint32_t dataSize, dataType; char dataAttributes; } SMCKeyData_keyInfo_t;
typedef struct {
    uint32_t key;
    SMCKeyData_vers_t vers;
    SMCKeyData_pLimitData_t pLimitData;
    SMCKeyData_keyInfo_t keyInfo;
    char result, status, data8;
    uint32_t data32;
    unsigned char bytes[32];
} SMCKeyData_t;

static kern_return_t smc_call(io_connect_t conn, SMCKeyData_t *in, SMCKeyData_t *out) {
    size_t size = sizeof(SMCKeyData_t);
    return IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, in, size, out, &size);
}

static uint32_t str_to_key(const char *s) {
    return ((uint32_t)(unsigned char)s[0] << 24) | ((uint32_t)(unsigned char)s[1] << 16)
         | ((uint32_t)(unsigned char)s[2] << 8) | (uint32_t)(unsigned char)s[3];
}

static void key_to_str(uint32_t k, char *s) {
    s[0] = (k >> 24) & 0xff; s[1] = (k >> 16) & 0xff; s[2] = (k >> 8) & 0xff; s[3] = k & 0xff; s[4] = 0;
}

static int smc_open(io_connect_t *conn) {
    io_service_t dev = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!dev) return 0;
    kern_return_t kr = IOServiceOpen(dev, mach_task_self(), 0, conn);
    IOObjectRelease(dev);
    return kr == KERN_SUCCESS;
}

/* 온도 꼴 키면 1 을 돌려주고 *value 를 채운다. */
static int read_key(io_connect_t conn, uint32_t key, double *value) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = key;
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(conn, &in, &out) != KERN_SUCCESS || out.result != 0) return 0;
    uint32_t size = out.keyInfo.dataSize;
    char type[5];
    key_to_str(out.keyInfo.dataType, type);
    if (size == 0 || size > 32) return 0;
    memset(&in, 0, sizeof in);
    in.key = key;
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_READ_BYTES;
    if (smc_call(conn, &in, &out) != KERN_SUCCESS || out.result != 0) return 0;
    if (strcmp(type, "flt ") == 0 && size == 4) {
        float f; memcpy(&f, out.bytes, 4); *value = f; return 1;
    }
    if (strcmp(type, "sp78") == 0 && size == 2) {
        *value = ((int16_t)((out.bytes[0] << 8) | out.bytes[1])) / 256.0; return 1;
    }
    if (strcmp(type, "ioft") == 0 && size == 8) {
        uint64_t v = 0; for (int i = 0; i < 8; i++) v = (v << 8) | out.bytes[i];
        *value = v / 65536.0; return 1;
    }
    return 0;
}

int csmc_list_temperatures(char *keys, double *values, int max) {
    io_connect_t conn;
    if (!smc_open(&conn)) return -1;
    int filled = 0;
    SMCKeyData_t in = {0}, out = {0};
    in.key = str_to_key("#KEY");
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(conn, &in, &out) == KERN_SUCCESS) {
        uint32_t size = out.keyInfo.dataSize;
        memset(&in, 0, sizeof in);
        in.key = str_to_key("#KEY");
        in.keyInfo.dataSize = size;
        in.data8 = SMC_CMD_READ_BYTES;
        if (smc_call(conn, &in, &out) == KERN_SUCCESS) {
            uint32_t count = ((uint32_t)out.bytes[0] << 24) | ((uint32_t)out.bytes[1] << 16) | ((uint32_t)out.bytes[2] << 8) | out.bytes[3];
            for (uint32_t i = 0; i < count && filled < max; i++) {
                memset(&in, 0, sizeof in); memset(&out, 0, sizeof out);
                in.data8 = SMC_CMD_READ_INDEX;
                in.data32 = i;
                if (smc_call(conn, &in, &out) != KERN_SUCCESS) continue;
                char name[5]; key_to_str(out.key, name);
                if (name[0] != 'T') continue;
                double v;
                if (!read_key(conn, out.key, &v)) continue;
                if (v <= 0.0 || v > 150.0) continue;   /* 비어 있는 센서는 0 이나 엉뚱한 값을 준다 */
                memcpy(keys + filled * 5, name, 5);
                values[filled] = v;
                filled++;
            }
        }
    }
    IOServiceClose(conn);
    return filled;
}

/* ui8 키 (FNum 등). 읽으면 1. */
static int read_ui8(io_connect_t conn, const char *name, int *value) {
    SMCKeyData_t in = {0}, out = {0};
    in.key = str_to_key(name);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(conn, &in, &out) != KERN_SUCCESS || out.result != 0 || out.keyInfo.dataSize != 1) return 0;
    memset(&in, 0, sizeof in);
    in.key = str_to_key(name);
    in.keyInfo.dataSize = 1;
    in.data8 = SMC_CMD_READ_BYTES;
    if (smc_call(conn, &in, &out) != KERN_SUCCESS || out.result != 0) return 0;
    *value = out.bytes[0];
    return 1;
}

int csmc_read_fans(double *actual, double *maximum, int max) {
    io_connect_t conn;
    if (!smc_open(&conn)) return -1;
    int count = 0;
    if (!read_ui8(conn, "FNum", &count)) count = 0;   /* 팬 없는 Mac (Air 등) 은 키가 없다 */
    if (count > max) count = max;
    for (int i = 0; i < count; i++) {
        char key[5];
        double v;
        snprintf(key, sizeof key, "F%dAc", i);
        actual[i] = read_key(conn, str_to_key(key), &v) ? v : NAN;
        snprintf(key, sizeof key, "F%dMx", i);
        maximum[i] = read_key(conn, str_to_key(key), &v) ? v : NAN;
    }
    IOServiceClose(conn);
    return count;
}

int csmc_read_temperatures(const char *keys, int count, double *values) {
    io_connect_t conn;
    if (!smc_open(&conn)) return -1;
    int read = 0;
    for (int i = 0; i < count; i++) {
        double v;
        if (read_key(conn, str_to_key(keys + i * 4), &v)) { values[i] = v; read++; }
        else values[i] = NAN;
    }
    IOServiceClose(conn);
    return read;
}
