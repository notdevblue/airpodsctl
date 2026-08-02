#ifndef AIRPODSCTL_FAKE_MPRIS_H
#define AIRPODSCTL_FAKE_MPRIS_H

struct fake_mpris;

struct fake_mpris *fake_mpris_create(const char *name, int playing);
void fake_mpris_destroy(struct fake_mpris *player);
int fake_mpris_is_playing(const struct fake_mpris *player);
int fake_mpris_set_playing(struct fake_mpris *player, int playing);

#endif
