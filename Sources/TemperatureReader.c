#include "TemperatureReader.h"

#include <IOKit/IOKitLib.h>
#include <mach/mach.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpu_limit;
    uint32_t gpu_limit;
    uint32_t memory_limit;
} SMCPLimit;

typedef struct {
    uint32_t data_size;
    uint32_t data_type;
    uint8_t attributes;
} SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVersion version;
    SMCPLimit limit;
    SMCKeyInfo info;
    uint8_t result;
    uint8_t status;
    uint8_t command;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

static uint32_t fourcc(const char name[4]) {
    return ((uint32_t)(uint8_t)name[0] << 24) |
           ((uint32_t)(uint8_t)name[1] << 16) |
           ((uint32_t)(uint8_t)name[2] << 8) |
           (uint32_t)(uint8_t)name[3];
}

static int smc_call(io_connect_t connection, const SMCKeyData *input, SMCKeyData *output) {
    size_t output_size = sizeof(*output);
    memset(output, 0, sizeof(*output));
    kern_return_t result = IOConnectCallStructMethod(
        connection, 2, input, sizeof(*input), output, &output_size
    );
    return result == KERN_SUCCESS && output->result == 0;
}

static int smc_key_info(io_connect_t connection, uint32_t key, SMCKeyInfo *info) {
    SMCKeyData input = {0};
    SMCKeyData output = {0};
    input.key = key;
    input.command = 9;
    if (!smc_call(connection, &input, &output)) return 0;
    *info = output.info;
    return 1;
}

static int smc_read_float(io_connect_t connection, const char name[4], double *value) {
    SMCKeyData input = {0};
    SMCKeyData output = {0};
    input.key = fourcc(name);
    input.command = 5;
    if (!smc_key_info(connection, input.key, &input.info)) return 0;
    if (input.info.data_size != 4 || input.info.data_type != fourcc("flt ")) return 0;
    if (!smc_call(connection, &input, &output)) return 0;

    float decoded = 0;
    memcpy(&decoded, output.bytes, sizeof(decoded));
    if (!isfinite(decoded)) return 0;
    *value = decoded;
    return 1;
}

static io_connect_t open_smc(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator
        ) != KERN_SUCCESS) {
        return IO_OBJECT_NULL;
    }

    io_connect_t connection = IO_OBJECT_NULL;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        io_name_t name = {0};
        IORegistryEntryGetName(service, name);
        if (strcmp(name, "AppleSMCKeysEndpoint") == 0) {
            IOServiceOpen(service, mach_task_self(), 0, &connection);
        }
        IOObjectRelease(service);
        if (connection != IO_OBJECT_NULL) break;
    }
    IOObjectRelease(iterator);
    return connection;
}

double mc_cpu_average_temperature(void) {
    // CPU Core Average as defined by Macs Fan Control for Macmini11,2, the
    // mapped model identifier used for the M4 Pro Mac mini.
    static const char *core_keys[] = {
        "Tp01", "Tp09", "Tp0H", "Tp0P", "Tp0X", "Tp0Y", "Te05", "Te0S"
    };

    io_connect_t connection = open_smc();
    if (connection == IO_OBJECT_NULL) return NAN;

    double base_temperature = 0;
    if (!smc_read_float(connection, "TCDX", &base_temperature)) {
        smc_read_float(connection, "TCMb", &base_temperature);
    }

    double sum = 0;
    for (size_t index = 0; index < sizeof(core_keys) / sizeof(core_keys[0]); index++) {
        double value = 0;
        if (!smc_read_float(connection, core_keys[index], &value)) {
            IOServiceClose(connection);
            return NAN;
        }

        // On recent Apple Silicon, some performance-core keys report low
        // deltas. Macs Fan Control anchors these values to TCDX/TCMb. The
        // stable point here avoids its small random display jitter.
        if (strncmp(core_keys[index], "Tp", 2) == 0 && value < 11) {
            if (!(base_temperature > 0 && base_temperature < 150)) {
                IOServiceClose(connection);
                return NAN;
            }
            value = base_temperature + 2.2;
        }

        if (!(value > 0 && value < 150)) {
            IOServiceClose(connection);
            return NAN;
        }
        sum += value;
    }

    IOServiceClose(connection);
    return sum / (sizeof(core_keys) / sizeof(core_keys[0]));
}
