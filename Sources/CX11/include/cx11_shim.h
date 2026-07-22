#ifndef COMPUTER_USE_MCP_CX11_SHIM_H
#define COMPUTER_USE_MCP_CX11_SHIM_H

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <X11/extensions/XTest.h>
#include <stdlib.h>

typedef void *CX11DisplayRef;

static inline CX11DisplayRef cx11_open_display(void) {
    return (CX11DisplayRef)XOpenDisplay(NULL);
}

static inline void cx11_close_display(CX11DisplayRef display) {
    if (display != NULL) {
        XCloseDisplay((Display *)display);
    }
}

static inline int cx11_default_screen(CX11DisplayRef display) {
    return DefaultScreen((Display *)display);
}

static inline unsigned long cx11_default_root_window(CX11DisplayRef display) {
    return RootWindow((Display *)display, DefaultScreen((Display *)display));
}

static inline int cx11_sync(CX11DisplayRef display) {
    return XSync((Display *)display, False);
}

static inline int cx11_flush(CX11DisplayRef display) {
    return XFlush((Display *)display);
}

static inline KeySym cx11_keysym_for_name(const char *name) {
    return XStringToKeysym(name);
}

static inline KeyCode cx11_keycode_for_keysym(CX11DisplayRef display, KeySym keysym) {
    return XKeysymToKeycode((Display *)display, keysym);
}

static inline int cx11_display_keycodes(
    CX11DisplayRef display,
    int *min,
    int *max
) {
    XDisplayKeycodes((Display *)display, min, max);
    return 1;
}

static inline KeySym *cx11_keyboard_mapping(
    CX11DisplayRef display,
    int first_keycode,
    int keycode_count,
    int *keysyms_per_keycode
) {
    return XGetKeyboardMapping((Display *)display, first_keycode, keycode_count, keysyms_per_keycode);
}

static inline void cx11_free(void *ptr) {
    if (ptr != NULL) {
        XFree(ptr);
    }
}

static inline int cx11_change_keyboard_mapping(
    CX11DisplayRef display,
    int first_keycode,
    int keysyms_per_keycode,
    const KeySym *keysyms,
    int num_codes
) {
    XChangeKeyboardMapping((Display *)display, first_keycode, keysyms_per_keycode, (KeySym *)keysyms, num_codes);
    return 1;
}

static inline int cx11_xtest_available(CX11DisplayRef display) {
    int event_base = 0;
    int error_base = 0;
    int major = 0;
    int minor = 0;
    return XTestQueryExtension((Display *)display, &event_base, &error_base, &major, &minor);
}

static inline int cx11_fake_motion_event(CX11DisplayRef display, int screen, int x, int y) {
    return XTestFakeMotionEvent((Display *)display, screen, x, y, 0);
}

static inline int cx11_fake_button_event(CX11DisplayRef display, unsigned int button, int press) {
    return XTestFakeButtonEvent((Display *)display, button, press, 0);
}

static inline int cx11_fake_key_event(CX11DisplayRef display, unsigned int keycode, int press) {
    return XTestFakeKeyEvent((Display *)display, keycode, press, 0);
}

#endif
