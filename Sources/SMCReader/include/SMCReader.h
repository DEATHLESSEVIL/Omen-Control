#ifndef OMEN_SMC_READER_H
#define OMEN_SMC_READER_H
#include <stddef.h>
// Read-only client: never writes SMC or EC registers.
int omen_smc_read(const char *key, double *value);
// Only thermal GET commands; creates and releases its own RM objects.
int omen_nvidia_temperature(double *value, char *message, size_t capacity);
#endif
