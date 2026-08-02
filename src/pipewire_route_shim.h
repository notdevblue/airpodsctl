#ifndef AIRPODSCTL_PIPEWIRE_ROUTE_SHIM_H
#define AIRPODSCTL_PIPEWIRE_ROUTE_SHIM_H

#include <stddef.h>

struct airpodsctl_route;

struct airpodsctl_route *airpodsctl_route_create(const char *address, size_t address_len);
void airpodsctl_route_destroy(struct airpodsctl_route *route);
int airpodsctl_route_fd(struct airpodsctl_route *route);
int airpodsctl_route_dispatch(struct airpodsctl_route *route);
int airpodsctl_route_state(const struct airpodsctl_route *route);
int airpodsctl_route_classify(
    const char *default_sink,
    const char *node_name,
    const char *node_address,
    int profile_is_a2dp,
    const char *selected_address
);

#endif
