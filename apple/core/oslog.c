// The unified log for the Rust core (src/logging.rs). os_log's format has to
// be a literal, so this is the one place it's written: the format string's
// own text goes public, the filled-in message private.
#include <os/log.h>
#include <stdbool.h>
#include <stdint.h>

os_log_t resonance_log_create(const char *subsystem, const char *category) {
    return os_log_create(subsystem, category);
}

bool resonance_log_enabled(os_log_t log, uint8_t type) {
    return os_log_type_enabled(log, (os_log_type_t)type);
}

void resonance_log(os_log_t log, uint8_t type, const char *public_part, const char *private_part) {
    if (private_part) {
        os_log_with_type(log, (os_log_type_t)type, "%{public}s %{private}s", public_part, private_part);
    } else {
        os_log_with_type(log, (os_log_type_t)type, "%{public}s", public_part);
    }
}
