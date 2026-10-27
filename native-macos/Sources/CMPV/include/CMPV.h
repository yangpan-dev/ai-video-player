#ifndef PANDAPLAYER_MPV_H
#define PANDAPLAYER_MPV_H
#include <stddef.h>
#include <stdint.h>

// Small dynamic bridge to libmpv's stable public C ABI. No link-time dependency.
typedef struct lumen_player lumen_player;
typedef void (*lumen_update_callback)(void *context);
typedef void *(*lumen_gl_resolver)(void *context, const char *name);

int lumen_load_library(const char *path, char *error, size_t capacity);
lumen_player *lumen_create(int headless);
int lumen_initialize(lumen_player *player);
int lumen_option(lumen_player *player, const char *name, const char *value);
int lumen_set(lumen_player *player, const char *name, const char *value);
int lumen_command(lumen_player *player, const char *const *args);
double lumen_number(lumen_player *player, const char *name, double fallback);
char *lumen_string(lumen_player *player, const char *name);
void lumen_free_string(char *value);
// Returns event id (0 when empty). detail: EOF reason, or mpv error code.
int lumen_poll(lumen_player *player, int *detail);
const char *lumen_error(int code);
int lumen_render_create(lumen_player *player, lumen_gl_resolver resolver, void *context);
void lumen_render_callback(lumen_player *player, lumen_update_callback callback, void *context);
void lumen_render(lumen_player *player, int width, int height, int framebuffer);
// Returns 1 for a rendered frame, 0 if idle, or an mpv error.
int lumen_render_if_needed(lumen_player *player, int width, int height, int framebuffer, int force);
void lumen_render_report_swap(lumen_player *player);
void lumen_render_destroy(lumen_player *player);
void lumen_destroy(lumen_player *player);
#endif
