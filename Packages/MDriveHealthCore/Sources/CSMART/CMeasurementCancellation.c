/* No Foundation/Swift/locks in a signal handler. GPL-3.0-or-later. */
#include "CMeasurementCancellation.h"
#include <signal.h>
#include <stdatomic.h>
#include <errno.h>

_Static_assert(ATOMIC_INT_LOCK_FREE == 2, "Signal cancellation requires lock-free atomics");
static atomic_int cancelled = ATOMIC_VAR_INIT(0);
static void cancel_signal(int signal_number) {
    (void)signal_number;
    atomic_store_explicit(&cancelled, 1, memory_order_relaxed);
}
int MDMeasurementInstallCancellationHandlers(void) {
    atomic_store_explicit(&cancelled, 0, memory_order_relaxed);
    struct sigaction action = {0};
    sigemptyset(&action.sa_mask);
    action.sa_handler = cancel_signal;
    const int signals[] = {SIGTERM, SIGINT, SIGHUP};
    for (unsigned i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) {
        if (sigaction(signals[i], &action, 0) != 0) return errno;
    }
    action.sa_handler = SIG_IGN;
    if (sigaction(SIGPIPE, &action, 0) != 0) return errno;
    return 0;
}
void MDMeasurementRequestCancellation(void) { atomic_store_explicit(&cancelled, 1, memory_order_relaxed); }
bool MDMeasurementIsCancelled(void) { return atomic_load_explicit(&cancelled, memory_order_relaxed) != 0; }
