#ifndef COMPUTER_USE_MCP_CATSPi_SHIM_H
#define COMPUTER_USE_MCP_CATSPi_SHIM_H

#include <atspi/atspi.h>
#include <glib.h>

typedef struct {
    int x;
    int y;
    int width;
    int height;
} CAtSpiRect;

static inline int catspi_init(void) {
    return atspi_init();
}

static inline AtspiAccessible *catspi_desktop(void) {
    return atspi_get_desktop(0);
}

static inline AtspiAccessible *catspi_ref(AtspiAccessible *object) {
    return object == NULL ? NULL : g_object_ref(object);
}

static inline void catspi_unref(AtspiAccessible *object) {
    if (object != NULL) {
        g_object_unref(object);
    }
}

static inline void catspi_free_string(char *value) {
    if (value != NULL) {
        g_free(value);
    }
}

static inline AtspiAccessible *catspi_application_for_pid(guint pid) {
    AtspiAccessible *desktop = catspi_desktop();
    if (desktop == NULL) {
        return NULL;
    }

    GError *error = NULL;
    gint count = atspi_accessible_get_child_count(desktop, &error);
    if (error != NULL) {
        g_error_free(error);
        g_object_unref(desktop);
        return NULL;
    }

    for (gint index = 0; index < count; index++) {
        error = NULL;
        AtspiAccessible *child = atspi_accessible_get_child_at_index(desktop, index, &error);
        if (error != NULL) {
            g_error_free(error);
            continue;
        }
        if (child == NULL) {
            continue;
        }
        error = NULL;
        guint child_pid = atspi_accessible_get_process_id(child, &error);
        if (error == NULL && child_pid == pid) {
            g_object_unref(desktop);
            return child;
        }
        if (error != NULL) {
            g_error_free(error);
        }
        g_object_unref(child);
    }
    g_object_unref(desktop);
    return NULL;
}

static inline guint catspi_process_id(AtspiAccessible *object) {
    GError *error = NULL;
    guint pid = atspi_accessible_get_process_id(object, &error);
    if (error != NULL) {
        g_error_free(error);
        return 0;
    }
    return pid;
}

static inline char *catspi_name(AtspiAccessible *object) {
    GError *error = NULL;
    char *value = atspi_accessible_get_name(object, &error);
    if (error != NULL) {
        g_error_free(error);
    }
    return value;
}

static inline char *catspi_description(AtspiAccessible *object) {
    GError *error = NULL;
    char *value = atspi_accessible_get_description(object, &error);
    if (error != NULL) {
        g_error_free(error);
    }
    return value;
}

static inline char *catspi_role_name(AtspiAccessible *object) {
    GError *error = NULL;
    char *value = atspi_accessible_get_role_name(object, &error);
    if (error != NULL) {
        g_error_free(error);
    }
    return value;
}

static inline int catspi_child_count(AtspiAccessible *object) {
    GError *error = NULL;
    gint count = atspi_accessible_get_child_count(object, &error);
    if (error != NULL) {
        g_error_free(error);
        return 0;
    }
    return count;
}

static inline AtspiAccessible *catspi_child_at_index(AtspiAccessible *object, int index) {
    GError *error = NULL;
    AtspiAccessible *child = atspi_accessible_get_child_at_index(object, index, &error);
    if (error != NULL) {
        g_error_free(error);
        return NULL;
    }
    return child;
}

static inline AtspiAccessible *catspi_parent(AtspiAccessible *object) {
    GError *error = NULL;
    AtspiAccessible *parent = atspi_accessible_get_parent(object, &error);
    if (error != NULL) {
        g_error_free(error);
        return NULL;
    }
    return parent;
}

static inline int catspi_state(AtspiAccessible *object, int state) {
    AtspiStateSet *states = atspi_accessible_get_state_set(object);
    if (states == NULL) {
        return 0;
    }
    int result = atspi_state_set_contains(states, (AtspiStateType)state);
    g_object_unref(states);
    return result;
}

static inline int catspi_extents(AtspiAccessible *object, CAtSpiRect *out) {
    AtspiComponent *component = atspi_accessible_get_component_iface(object);
    if (component == NULL || out == NULL) {
        if (component != NULL) {
            g_object_unref(component);
        }
        return 0;
    }
    GError *error = NULL;
    AtspiRect *rect = atspi_component_get_extents(component, ATSPI_COORD_TYPE_SCREEN, &error);
    if (error != NULL || rect == NULL) {
        if (error != NULL) {
            g_error_free(error);
        }
        g_object_unref(component);
        return 0;
    }
    out->x = rect->x;
    out->y = rect->y;
    out->width = rect->width;
    out->height = rect->height;
    g_free(rect);
    g_object_unref(component);
    return 1;
}

static inline int catspi_do_action(AtspiAccessible *object, int index) {
    AtspiAction *action = atspi_accessible_get_action_iface(object);
    if (action == NULL) {
        return 0;
    }
    GError *error = NULL;
    gboolean result = atspi_action_do_action(action, index, &error);
    if (error != NULL) {
        g_error_free(error);
    }
    g_object_unref(action);
    return result;
}

static inline char *catspi_text(AtspiAccessible *object) {
    AtspiText *text = atspi_accessible_get_text_iface(object);
    if (text == NULL) {
        return NULL;
    }
    GError *error = NULL;
    gint count = atspi_text_get_character_count(text, &error);
    if (error != NULL || count < 1) {
        if (error != NULL) {
            g_error_free(error);
        }
        g_object_unref(text);
        return NULL;
    }
    error = NULL;
    char *value = atspi_text_get_text(text, 0, count, &error);
    if (error != NULL) {
        g_error_free(error);
    }
    g_object_unref(text);
    return value;
}

static inline int catspi_action_count(AtspiAccessible *object) {
    AtspiAction *action = atspi_accessible_get_action_iface(object);
    if (action == NULL) {
        return 0;
    }
    GError *error = NULL;
    gint count = atspi_action_get_n_actions(action, &error);
    if (error != NULL) {
        g_error_free(error);
        g_object_unref(action);
        return 0;
    }
    g_object_unref(action);
    return count;
}

static inline char *catspi_action_name(AtspiAccessible *object, int index) {
    AtspiAction *action = atspi_accessible_get_action_iface(object);
    if (action == NULL) {
        return NULL;
    }
    GError *error = NULL;
    char *name = atspi_action_get_name(action, index, &error);
    if (error != NULL) {
        g_error_free(error);
    }
    g_object_unref(action);
    return name;
}

#endif
