/* Async-signal-safe worker cancellation. GPL-3.0-or-later. */
#ifndef MD_MEASUREMENT_CANCELLATION_H
#define MD_MEASUREMENT_CANCELLATION_H
#include <stdbool.h>
int MDMeasurementInstallCancellationHandlers(void);
void MDMeasurementRequestCancellation(void);
bool MDMeasurementIsCancelled(void);
#endif
