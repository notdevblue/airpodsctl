#include "pipewire_route_shim.h"

#include <pipewire/pipewire.h>
#include <pipewire/extensions/metadata.h>
#include <spa/utils/json.h>
#include <spa/utils/keys.h>

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#define MAX_NODES 64
#define MAX_NAME 255

struct route_node {
    uint32_t id;
    char name[MAX_NAME + 1];
    char address[18];
    int profile_is_a2dp;
};

struct airpodsctl_route {
    char selected_address[18];
    struct pw_main_loop *main_loop;
    struct pw_loop *loop;
    struct pw_context *context;
    struct pw_core *core;
    struct pw_registry *registry;
    struct pw_metadata *metadata;
    uint32_t metadata_id;
    struct spa_hook core_listener;
    struct spa_hook registry_listener;
    struct spa_hook metadata_listener;
    int core_listener_added;
    int registry_listener_added;
    int metadata_listener_added;
    struct route_node nodes[MAX_NODES];
    size_t node_count;
    char default_sink[MAX_NAME + 1];
    int failed;
};

static void route_core_error(
    void *data,
    uint32_t id,
    int seq,
    int result,
    const char *message
) {
    struct airpodsctl_route *route = data;

    (void)id;
    (void)seq;
    (void)result;
    (void)message;
    route->failed = 1;
}

static int route_metadata_property(
    void *data,
    uint32_t subject,
    const char *key,
    const char *type,
    const char *value
) {
    struct airpodsctl_route *route = data;

    (void)subject;
    (void)type;
    if (key == NULL || strcmp(key, "default.audio.sink") != 0) return 0;
    route->default_sink[0] = '\0';
    if (value == NULL || strlen(value) > 1024) return 0;
    if (spa_json_str_object_find(
            value,
            strlen(value),
            "name",
            route->default_sink,
            sizeof(route->default_sink)
        ) < 0) {
        route->default_sink[0] = '\0';
    }
    return 0;
}

static const struct pw_metadata_events metadata_events = {
    PW_VERSION_METADATA_EVENTS,
    .property = route_metadata_property,
};

static void route_remove_node(struct airpodsctl_route *route, uint32_t id) {
    size_t index;

    for (index = 0; index < route->node_count; index++) {
        if (route->nodes[index].id != id) continue;
        route->nodes[index] = route->nodes[route->node_count - 1];
        route->node_count--;
        return;
    }
}

static void route_registry_global(
    void *data,
    uint32_t id,
    uint32_t permissions,
    const char *object_type,
    uint32_t version,
    const struct spa_dict *properties
) {
    struct airpodsctl_route *route = data;
    const char *media_class;
    const char *name;
    const char *address;
    const char *profile;
    const char *metadata_name;
    struct route_node *node;

    (void)permissions;
    if (object_type == NULL) return;
    if (strcmp(object_type, PW_TYPE_INTERFACE_Node) == 0) {
        media_class = properties == NULL ? NULL : spa_dict_lookup(properties, PW_KEY_MEDIA_CLASS);
        name = properties == NULL ? NULL : spa_dict_lookup(properties, PW_KEY_NODE_NAME);
        if (media_class == NULL || strcmp(media_class, "Audio/Sink") != 0 || name == NULL ||
            strlen(name) > MAX_NAME || route->node_count == MAX_NODES) {
            return;
        }

        node = &route->nodes[route->node_count++];
        memset(node, 0, sizeof(*node));
        node->id = id;
        memcpy(node->name, name, strlen(name) + 1);
        address = spa_dict_lookup(properties, SPA_KEY_API_BLUEZ5_ADDRESS);
        if (address != NULL && strlen(address) == 17) memcpy(node->address, address, 18);
        profile = spa_dict_lookup(properties, SPA_KEY_API_BLUEZ5_PROFILE);
        node->profile_is_a2dp = profile != NULL && strstr(profile, "a2dp") != NULL;
        return;
    }
    if (strcmp(object_type, PW_TYPE_INTERFACE_Metadata) != 0 || route->metadata != NULL) return;
    metadata_name = properties == NULL ? NULL : spa_dict_lookup(properties, PW_KEY_METADATA_NAME);
    if (metadata_name == NULL || strcmp(metadata_name, "default") != 0) return;

    route->metadata_id = id;
    route->metadata = pw_registry_bind(
        route->registry,
        id,
        PW_TYPE_INTERFACE_Metadata,
        version < PW_VERSION_METADATA ? version : PW_VERSION_METADATA,
        0
    );
    if (route->metadata != NULL && pw_metadata_add_listener(
            route->metadata,
            &route->metadata_listener,
            &metadata_events,
            route
        ) >= 0) {
        route->metadata_listener_added = 1;
    }
}

static void route_registry_global_remove(void *data, uint32_t id) {
    struct airpodsctl_route *route = data;

    route_remove_node(route, id);
    if (route->metadata_id != id) return;
    if (route->metadata_listener_added) spa_hook_remove(&route->metadata_listener);
    route->metadata_listener_added = 0;
    if (route->metadata != NULL) pw_proxy_destroy((struct pw_proxy *)route->metadata);
    route->metadata = NULL;
    route->metadata_id = PW_ID_ANY;
    route->default_sink[0] = '\0';
}

void airpodsctl_route_destroy(struct airpodsctl_route *route) {
    if (route == NULL) return;
    if (route->metadata_listener_added) spa_hook_remove(&route->metadata_listener);
    if (route->registry_listener_added) spa_hook_remove(&route->registry_listener);
    if (route->core_listener_added) spa_hook_remove(&route->core_listener);
    if (route->metadata != NULL) pw_proxy_destroy((struct pw_proxy *)route->metadata);
    if (route->registry != NULL) pw_proxy_destroy((struct pw_proxy *)route->registry);
    if (route->core != NULL) pw_core_disconnect(route->core);
    if (route->context != NULL) pw_context_destroy(route->context);
    if (route->loop != NULL) pw_loop_leave(route->loop);
    if (route->main_loop != NULL) pw_main_loop_destroy(route->main_loop);
    pw_deinit();
    free(route);
}

struct airpodsctl_route *airpodsctl_route_create(const char *address, size_t address_len) {
    static const struct pw_core_events core_events = {
        PW_VERSION_CORE_EVENTS,
        .error = route_core_error,
    };
    static const struct pw_registry_events registry_events = {
        PW_VERSION_REGISTRY_EVENTS,
        .global = route_registry_global,
        .global_remove = route_registry_global_remove,
    };
    struct airpodsctl_route *route;

    if (address == NULL || address_len != 17) return NULL;
    route = calloc(1, sizeof(*route));
    if (route == NULL) return NULL;
    memcpy(route->selected_address, address, address_len);
    route->metadata_id = PW_ID_ANY;

    pw_init(NULL, NULL);
    route->main_loop = pw_main_loop_new(NULL);
    if (route->main_loop == NULL) goto failure;
    route->loop = pw_main_loop_get_loop(route->main_loop);
    pw_loop_enter(route->loop);
    route->context = pw_context_new(route->loop, NULL, 0);
    if (route->context == NULL) goto failure;
    route->core = pw_context_connect(route->context, NULL, 0);
    if (route->core == NULL) goto failure;
    pw_core_add_listener(route->core, &route->core_listener, &core_events, route);
    route->core_listener_added = 1;
    route->registry = pw_core_get_registry(route->core, PW_VERSION_REGISTRY, 0);
    if (route->registry == NULL) goto failure;
    if (pw_registry_add_listener(route->registry, &route->registry_listener, &registry_events, route) < 0) {
        goto failure;
    }
    route->registry_listener_added = 1;
    pw_core_sync(route->core, PW_ID_CORE, 0);
    return route;

failure:
    airpodsctl_route_destroy(route);
    return NULL;
}

int airpodsctl_route_fd(struct airpodsctl_route *route) {
    return route == NULL ? -1 : pw_loop_get_fd(route->loop);
}

int airpodsctl_route_dispatch(struct airpodsctl_route *route) {
    if (route == NULL || route->failed) return -1;
    return pw_loop_iterate(route->loop, 0);
}

int airpodsctl_route_classify(
    const char *default_sink,
    const char *node_name,
    const char *node_address,
    int profile_is_a2dp,
    const char *selected_address
) {
    if (default_sink == NULL || default_sink[0] == '\0' || node_name == NULL ||
        strcmp(default_sink, node_name) != 0) {
        return 0;
    }
    if (profile_is_a2dp && node_address != NULL && selected_address != NULL &&
        strcasecmp(node_address, selected_address) == 0) {
        return 1;
    }
    return 2;
}

int airpodsctl_route_state(const struct airpodsctl_route *route) {
    size_t index;

    if (route == NULL || route->failed || route->default_sink[0] == '\0') return 0;
    for (index = 0; index < route->node_count; index++) {
        const struct route_node *node = &route->nodes[index];

        const int state = airpodsctl_route_classify(
            route->default_sink,
            node->name,
            node->address,
            node->profile_is_a2dp,
            route->selected_address
        );

        if (state != 0) return state;
    }
    return 0;
}
