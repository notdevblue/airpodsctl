#include "fake_mpris.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <systemd/sd-bus.h>

struct fake_mpris {
    sd_bus *bus;
    sd_bus_slot *slot;
    pthread_t thread;
    int thread_started;
    pthread_mutex_t mutex;
    int mutex_initialized;
    atomic_int playing;
    atomic_int delayed_pause;
    atomic_int pause_pending;
    atomic_int stop;
};

static int fake_pause(sd_bus_message *message, void *data, sd_bus_error *error) {
    struct fake_mpris *player = data;

    (void)error;
    if (atomic_load(&player->delayed_pause)) {
        atomic_store(&player->pause_pending, 1);
    } else {
        atomic_store(&player->playing, 0);
    }
    return sd_bus_reply_method_return(message, "");
}

static int fake_play(sd_bus_message *message, void *data, sd_bus_error *error) {
    struct fake_mpris *player = data;

    (void)error;
    atomic_store(&player->playing, 1);
    return sd_bus_reply_method_return(message, "");
}

static int fake_get_status(
    sd_bus *bus,
    const char *path,
    const char *interface,
    const char *property,
    sd_bus_message *reply,
    void *data,
    sd_bus_error *error
) {
    struct fake_mpris *player = data;
    const int playing = atomic_load(&player->playing);
    int result;

    (void)bus;
    (void)path;
    (void)interface;
    (void)property;
    (void)error;
    result = sd_bus_message_append(reply, "s", playing ? "Playing" : "Paused");
    if (result >= 0 && playing && atomic_exchange(&player->pause_pending, 0)) {
        atomic_store(&player->playing, 0);
        (void)sd_bus_emit_properties_changed(
            player->bus,
            "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player",
            "PlaybackStatus",
            NULL
        );
    }
    return result;
}

static int fake_get_capability(
    sd_bus *bus,
    const char *path,
    const char *interface,
    const char *property,
    sd_bus_message *reply,
    void *data,
    sd_bus_error *error
) {
    (void)bus;
    (void)path;
    (void)interface;
    (void)property;
    (void)data;
    (void)error;
    return sd_bus_message_append(reply, "b", 1);
}

static const sd_bus_vtable fake_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("Pause", "", "", fake_pause, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("Play", "", "", fake_play, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_PROPERTY("PlaybackStatus", "s", fake_get_status, 0, SD_BUS_VTABLE_PROPERTY_EMITS_CHANGE),
    SD_BUS_PROPERTY("CanPause", "b", fake_get_capability, 0, 0),
    SD_BUS_PROPERTY("CanPlay", "b", fake_get_capability, 0, 0),
    SD_BUS_VTABLE_END,
};

static void *fake_run(void *data) {
    struct fake_mpris *player = data;

    while (!atomic_load(&player->stop)) {
        pthread_mutex_lock(&player->mutex);
        while (sd_bus_process(player->bus, NULL) > 0) {}
        sd_bus_wait(player->bus, 10 * 1000);
        pthread_mutex_unlock(&player->mutex);
    }
    return NULL;
}

int fake_mpris_set_playing(struct fake_mpris *player, int playing) {
    int result;

    if (player == NULL) return -1;
    pthread_mutex_lock(&player->mutex);
    atomic_store(&player->playing, playing != 0);
    result = sd_bus_emit_properties_changed(
        player->bus,
        "/org/mpris/MediaPlayer2",
        "org.mpris.MediaPlayer2.Player",
        "PlaybackStatus",
        NULL
    );
    pthread_mutex_unlock(&player->mutex);
    return result;
}

void fake_mpris_destroy(struct fake_mpris *player) {
    if (player == NULL) return;
    if (player->thread_started) {
        atomic_store(&player->stop, 1);
        pthread_join(player->thread, NULL);
    }
    player->slot = sd_bus_slot_unref(player->slot);
    player->bus = sd_bus_unref(player->bus);
    if (player->mutex_initialized) pthread_mutex_destroy(&player->mutex);
    free(player);
}

struct fake_mpris *fake_mpris_create(const char *name, int playing, int delayed_pause) {
    struct fake_mpris *player = calloc(1, sizeof(*player));

    if (player == NULL) return NULL;
    if (pthread_mutex_init(&player->mutex, NULL) != 0) {
        free(player);
        return NULL;
    }
    player->mutex_initialized = 1;
    atomic_store(&player->playing, playing != 0);
    atomic_store(&player->delayed_pause, delayed_pause != 0);
    if (sd_bus_open_user(&player->bus) < 0 ||
        sd_bus_add_object_vtable(
            player->bus,
            &player->slot,
            "/org/mpris/MediaPlayer2",
            "org.mpris.MediaPlayer2.Player",
            fake_vtable,
            player
        ) < 0 ||
        sd_bus_request_name(player->bus, name, 0) < 0 ||
        pthread_create(&player->thread, NULL, fake_run, player) != 0) {
        fake_mpris_destroy(player);
        return NULL;
    }
    player->thread_started = 1;
    return player;
}

int fake_mpris_is_playing(const struct fake_mpris *player) {
    return player != NULL && atomic_load(&player->playing);
}
