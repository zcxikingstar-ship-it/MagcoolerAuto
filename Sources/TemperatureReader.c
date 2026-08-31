#include "TemperatureReader.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hidsystem/IOHIDServiceClient.h>
#include <math.h>
#include <stdint.h>
#include <string.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef double IOHIDFloat;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef match);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timeout);
extern IOHIDFloat IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

typedef struct {
    double sum;
    int count;
} TemperatureGroup;

static CFDictionaryRef create_temperature_matching(void) {
    int32_t page = 0xff00;
    int32_t usage = 5;
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    CFNumberRef values[] = {
        CFNumberCreate(NULL, kCFNumberSInt32Type, &page),
        CFNumberCreate(NULL, kCFNumberSInt32Type, &usage)
    };
    if (!values[0] || !values[1]) {
        if (values[0]) CFRelease(values[0]);
        if (values[1]) CFRelease(values[1]);
        return NULL;
    }
    CFDictionaryRef result = CFDictionaryCreate(
        NULL, keys, (const void **)values, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks
    );
    CFRelease(values[0]);
    CFRelease(values[1]);
    return result;
}

static void add_value(TemperatureGroup *group, double value) {
    group->sum += value;
    group->count += 1;
}

static double average(TemperatureGroup group) {
    return group.count > 0 ? group.sum / group.count : NAN;
}

double mc_cpu_average_temperature(void) {
    CFDictionaryRef matching = create_temperature_matching();
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!matching || !client) {
        if (matching) CFRelease(matching);
        if (client) CFRelease(client);
        return NAN;
    }

    IOHIDEventSystemClientSetMatching(client, matching);
    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    TemperatureGroup accelerator = {0};
    TemperatureGroup die = {0};
    TemperatureGroup soc = {0};

    if (services) {
        CFIndex count = CFArrayGetCount(services);
        for (CFIndex index = 0; index < count; index++) {
            IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, index);
            if (!service) continue;

            CFStringRef product = (CFStringRef)IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
            char name[256] = {0};
            if (product) {
                CFStringGetCString(product, name, sizeof(name), kCFStringEncodingUTF8);
            }

            IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, 15, 0, 0);
            double value = event ? IOHIDEventGetFloatValue(event, 15 << 16) : NAN;
            if (event) CFRelease(event);
            if (product) CFRelease(product);
            if (!(value > 0 && value < 150)) continue;

            if (strncmp(name, "eACC", 4) == 0 || strncmp(name, "pACC", 4) == 0) {
                add_value(&accelerator, value);
            } else if (strncmp(name, "PMU tdie", 8) == 0) {
                add_value(&die, value);
            } else if (strncmp(name, "SOC MTR Temp Sensor", 19) == 0) {
                add_value(&soc, value);
            }
        }
        CFRelease(services);
    }

    CFRelease(client);
    CFRelease(matching);
    if (accelerator.count > 0) return average(accelerator);
    if (die.count > 0) return average(die);
    if (soc.count > 0) return average(soc);
    return NAN;
}
