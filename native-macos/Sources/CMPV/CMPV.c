#include "CMPV.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ABI declarations from mpv client/render API v2 (see THIRD_PARTY.md).
typedef struct mpv_handle mpv_handle;
typedef struct mpv_render_context mpv_render_context;
typedef struct { int event_id, error; uint64_t reply_userdata; void *data; } mpv_event;
typedef struct { int reason, error; } end_file_prefix;
typedef struct { int type; void *data; } render_param;
typedef struct { lumen_gl_resolver get_proc_address; void *get_proc_address_ctx; } gl_init;
typedef struct { int fbo, w, h, internal_format; } gl_fbo;

struct lumen_player { mpv_handle *handle; mpv_render_context *render; };
static void *library;
static mpv_handle *(*p_create)(void);
static int (*p_initialize)(mpv_handle *);
static void (*p_terminate_destroy)(mpv_handle *);
static int (*p_set_option_string)(mpv_handle *, const char *, const char *);
static int (*p_set_property_string)(mpv_handle *, const char *, const char *);
static int (*p_get_property)(mpv_handle *, const char *, int, void *);
static char *(*p_get_property_string)(mpv_handle *, const char *);
static int (*p_command)(mpv_handle *, const char *const *);
static mpv_event *(*p_wait_event)(mpv_handle *, double);
static const char *(*p_error_string)(int);
static void (*p_free)(void *);
static int (*p_render_context_create)(mpv_render_context **, mpv_handle *, render_param *);
static void (*p_render_context_set_update_callback)(mpv_render_context *, lumen_update_callback, void *);
static uint64_t (*p_render_context_update)(mpv_render_context *);
static int (*p_render_context_render)(mpv_render_context *, render_param *);
static void (*p_render_context_free)(mpv_render_context *);

int lumen_load_library(const char *path, char *error, size_t capacity) {
    if (library) return 0;
    library = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!library) { snprintf(error, capacity, "%s", dlerror()); return -1; }
    #define LOAD(name) do { *(void **)(&p_##name) = dlsym(library, "mpv_" #name); \
        if (!p_##name) { snprintf(error, capacity, "Missing mpv_%s", #name); \
        dlclose(library); library = NULL; return -1; } } while (0)
    LOAD(create); LOAD(initialize); LOAD(terminate_destroy); LOAD(set_option_string);
    LOAD(set_property_string); LOAD(get_property); LOAD(get_property_string); LOAD(command);
    LOAD(wait_event); LOAD(error_string); LOAD(free); LOAD(render_context_create);
    LOAD(render_context_set_update_callback); LOAD(render_context_update);
    LOAD(render_context_render); LOAD(render_context_free);
    #undef LOAD
    return 0;
}

lumen_player *lumen_create(int headless) {
    if (!library) return NULL;
    lumen_player *p = calloc(1, sizeof(*p));
    if (!p) return NULL;
    p->handle = p_create();
    if (!p->handle) { free(p); return NULL; }
    lumen_option(p, "config", "no");
    lumen_option(p, "terminal", "no");
    lumen_option(p, "osc", "no");
    lumen_option(p, "input-default-bindings", "no");
    lumen_option(p, "input-vo-keyboard", "no");
    lumen_option(p, "idle", "yes");
    lumen_option(p, "keep-open", "yes");
    lumen_option(p, "vo", headless ? "null" : "libmpv");
    if (headless) lumen_option(p, "ao", "null");
    lumen_option(p, "hwdec", "auto-safe");
    lumen_option(p, "sub-auto", "fuzzy");
    lumen_option(p, "screenshot-format", "png");
    return p;
}
int lumen_initialize(lumen_player *p) { return p_initialize(p->handle); }
int lumen_option(lumen_player *p, const char *n, const char *v) { return p_set_option_string(p->handle,n,v); }
int lumen_set(lumen_player *p, const char *n, const char *v) { return p_set_property_string(p->handle,n,v); }
int lumen_command(lumen_player *p, const char *const *a) { return p_command(p->handle,a); }
double lumen_number(lumen_player *p, const char *n, double fallback) {
    double v; return p_get_property(p->handle,n,5,&v) < 0 ? fallback : v; // MPV_FORMAT_DOUBLE
}
char *lumen_string(lumen_player *p, const char *n) { return p_get_property_string(p->handle,n); }
void lumen_free_string(char *s) { if (s) p_free(s); }
int lumen_poll(lumen_player *p, int *detail) {
    mpv_event *e = p_wait_event(p->handle,0);
    *detail = e->error;
    if (e->event_id == 7 && e->data) {
        end_file_prefix *end = e->data;
        *detail = end->reason == 4 ? end->error : end->reason;
    }
    return e->event_id;
}
const char *lumen_error(int code) { return p_error_string ? p_error_string(code) : "libmpv unavailable"; }
int lumen_render_create(lumen_player *p, lumen_gl_resolver resolver, void *context) {
    gl_init init = { resolver, context };
    render_param params[] = {{1, "opengl"}, {2, &init}, {0,NULL}};
    return p_render_context_create(&p->render,p->handle,params);
}
void lumen_render_callback(lumen_player *p, lumen_update_callback callback, void *context) {
    if (p->render) p_render_context_set_update_callback(p->render,callback,context);
}
void lumen_render(lumen_player *p, int w, int h, int fbo) {
    if (!p->render || w <= 0 || h <= 0) return;
    p_render_context_update(p->render);
    gl_fbo target = {fbo,w,h,0}; int flip = 1;
    render_param params[] = {{3,&target},{4,&flip},{0,NULL}};
    p_render_context_render(p->render,params);
}
void lumen_render_destroy(lumen_player *p) {
    if (p && p->render) {
        p_render_context_set_update_callback(p->render,NULL,NULL);
        p_render_context_free(p->render); p->render = NULL;
    }
}
void lumen_destroy(lumen_player *p) {
    if (!p) return;
    lumen_render_destroy(p); p_terminate_destroy(p->handle); free(p);
}
