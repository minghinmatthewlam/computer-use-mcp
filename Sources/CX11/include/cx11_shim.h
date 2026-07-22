#ifndef COMPUTER_USE_MCP_CX11_SHIM_H
#define COMPUTER_USE_MCP_CX11_SHIM_H

#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/Xutil.h>
#include <X11/extensions/XTest.h>
#include <png.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

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

static pthread_mutex_t cx11_x_error_lock = PTHREAD_MUTEX_INITIALIZER;
static int cx11_x_error_code = 0;

static int cx11_capture_x_error(Display *display, XErrorEvent *event) {
    (void)display;
    cx11_x_error_code = event->error_code;
    return 0;
}

static inline int cx11_root_width(CX11DisplayRef display) {
    return display == NULL ? 0 : DisplayWidth((Display *)display, DefaultScreen((Display *)display));
}

static inline int cx11_root_height(CX11DisplayRef display) {
    return display == NULL ? 0 : DisplayHeight((Display *)display, DefaultScreen((Display *)display));
}

static inline unsigned long cx11_window_pid(Display *display, Window window) {
    Atom atom = XInternAtom(display, "_NET_WM_PID", True);
    if (atom == None) {
        return 0;
    }
    Atom actual_type = None;
    int actual_format = 0;
    unsigned long item_count = 0;
    unsigned long bytes_after = 0;
    unsigned char *data = NULL;
    int result = XGetWindowProperty(
        display,
        window,
        atom,
        0,
        1,
        False,
        XA_CARDINAL,
        &actual_type,
        &actual_format,
        &item_count,
        &bytes_after,
        &data
    );
    unsigned long pid = 0;
    if (result == Success && data != NULL && actual_format == 32 && item_count > 0) {
        pid = ((unsigned long *)data)[0];
    }
    if (data != NULL) {
        XFree(data);
    }
    return pid;
}

static Window cx11_find_window_by_pid(Display *display, Window root, unsigned long pid, int depth) {
    if (depth > 8) {
        return 0;
    }
    if (cx11_window_pid(display, root) == pid) {
        return root;
    }
    Window root_return = 0;
    Window parent_return = 0;
    Window *children = NULL;
    unsigned int child_count = 0;
    if (!XQueryTree(
        display,
        root,
        &root_return,
        &parent_return,
        &children,
        &child_count
    )) {
        return 0;
    }
    Window match = 0;
    for (unsigned int index = 0; index < child_count && match == 0; index++) {
        match = cx11_find_window_by_pid(display, children[index], pid, depth + 1);
    }
    if (children != NULL) {
        XFree(children);
    }
    return match;
}

static inline unsigned long cx11_window_for_pid(CX11DisplayRef display, unsigned long pid) {
    if (display == NULL || pid == 0) {
        return 0;
    }
    Display *xdisplay = (Display *)display;
    return cx11_find_window_by_pid(
        xdisplay,
        RootWindow(xdisplay, DefaultScreen(xdisplay)),
        pid,
        0
    );
}

static inline int cx11_activate_window(CX11DisplayRef display, unsigned long window_id) {
    if (display == NULL || window_id == 0) {
        return 0;
    }
    Display *xdisplay = (Display *)display;
    Window window = (Window)window_id;
    pthread_mutex_lock(&cx11_x_error_lock);
    cx11_x_error_code = 0;
    int (*previous_handler)(Display *, XErrorEvent *) = XSetErrorHandler(cx11_capture_x_error);
    XRaiseWindow(xdisplay, window);
    XSetInputFocus(xdisplay, window, RevertToParent, CurrentTime);
    Atom active_window = XInternAtom(xdisplay, "_NET_ACTIVE_WINDOW", False);
    Window root = RootWindow(xdisplay, DefaultScreen(xdisplay));
    if (active_window != None) {
        XClientMessageEvent event;
        memset(&event, 0, sizeof(event));
        event.type = ClientMessage;
        event.window = window;
        event.message_type = active_window;
        event.format = 32;
        event.data.l[0] = 1;
        event.data.l[1] = CurrentTime;
        XSendEvent(
            xdisplay,
            root,
            False,
            SubstructureRedirectMask | SubstructureNotifyMask,
            (XEvent *)&event
        );
    }
    XFlush(xdisplay);
    XSync(xdisplay, False);
    XSetErrorHandler(previous_handler);
    int error_code = cx11_x_error_code;
    pthread_mutex_unlock(&cx11_x_error_lock);
    if (error_code != 0) {
        return 0;
    }
    return 1;
}

static inline int cx11_focus_matches_pid(CX11DisplayRef display, unsigned long pid) {
    if (display == NULL || pid == 0) {
        return 0;
    }
    Display *xdisplay = (Display *)display;
    Window focused = None;
    int revert_to = RevertToNone;
    XGetInputFocus(xdisplay, &focused, &revert_to);
    if (focused == None || focused == PointerRoot) {
        return 0;
    }
    Window root = RootWindow(xdisplay, DefaultScreen(xdisplay));
    for (Window current = focused; current != None && current != root;) {
        if (cx11_window_pid(xdisplay, current) == pid) {
            return 1;
        }
        Window parent = None;
        Window *children = NULL;
        unsigned int child_count = 0;
        Window root_return = None;
        if (!XQueryTree(
            xdisplay,
            current,
            &root_return,
            &parent,
            &children,
            &child_count
        )) {
            break;
        }
        if (children != NULL) {
            XFree(children);
        }
        if (parent == current || parent == None) {
            break;
        }
        current = parent;
    }
    return 0;
}

static inline unsigned char cx11_channel(unsigned long pixel, unsigned long mask) {
    if (mask == 0) {
        return 0;
    }
    unsigned long value = (pixel & mask);
    unsigned long shift = 0;
    while ((mask & 1UL) == 0) {
        mask >>= 1;
        value >>= 1;
    }
    unsigned long max = mask;
    return (unsigned char)((value * 255UL + max / 2UL) / max);
}

static inline int cx11_capture_root_rgba(
    CX11DisplayRef display,
    int x,
    int y,
    unsigned int width,
    unsigned int height,
    unsigned char **pixels
) {
    if (display == NULL || pixels == NULL || width == 0 || height == 0) {
        return 0;
    }
    Display *xdisplay = (Display *)display;
    Window root = RootWindow(xdisplay, DefaultScreen(xdisplay));
    pthread_mutex_lock(&cx11_x_error_lock);
    cx11_x_error_code = 0;
    int (*previous_handler)(Display *, XErrorEvent *) = XSetErrorHandler(cx11_capture_x_error);
    XImage *image = XGetImage(xdisplay, root, x, y, width, height, AllPlanes, ZPixmap);
    XSync(xdisplay, False);
    XSetErrorHandler(previous_handler);
    int error_code = cx11_x_error_code;
    pthread_mutex_unlock(&cx11_x_error_lock);
    if (error_code != 0) {
        if (image != NULL) {
            XDestroyImage(image);
        }
        return -error_code;
    }
    if (image == NULL) {
        return 0;
    }
    size_t size = (size_t)width * (size_t)height * 4U;
    unsigned char *output = (unsigned char *)malloc(size);
    if (output == NULL) {
        XDestroyImage(image);
        return 0;
    }
    for (unsigned int row = 0; row < height; row++) {
        for (unsigned int column = 0; column < width; column++) {
            unsigned long pixel = XGetPixel(image, column, row);
            size_t offset = ((size_t)row * width + column) * 4U;
            output[offset] = cx11_channel(pixel, image->red_mask);
            output[offset + 1] = cx11_channel(pixel, image->green_mask);
            output[offset + 2] = cx11_channel(pixel, image->blue_mask);
            output[offset + 3] = 255;
        }
    }
    XDestroyImage(image);
    *pixels = output;
    return 1;
}

typedef struct {
    unsigned char *data;
    size_t size;
    size_t capacity;
} CX11PngBuffer;

static void cx11_png_write(
    png_structp png_ptr,
    png_bytep data,
    png_size_t length
) {
    CX11PngBuffer *buffer = (CX11PngBuffer *)png_get_io_ptr(png_ptr);
    size_t required = buffer->size + (size_t)length;
    if (required > buffer->capacity) {
        size_t capacity = buffer->capacity == 0 ? 4096 : buffer->capacity;
        while (capacity < required) {
            capacity *= 2;
        }
        unsigned char *resized = (unsigned char *)realloc(buffer->data, capacity);
        if (resized == NULL) {
            png_error(png_ptr, "PNG allocation failed");
            return;
        }
        buffer->data = resized;
        buffer->capacity = capacity;
    }
    memcpy(buffer->data + buffer->size, data, (size_t)length);
    buffer->size = required;
}

static void cx11_png_flush(png_structp png_ptr) {
    (void)png_ptr;
}

static inline int cx11_encode_png_rgba(
    const unsigned char *pixels,
    unsigned int width,
    unsigned int height,
    unsigned int stride,
    unsigned char **png_data,
    size_t *png_size
) {
    if (pixels == NULL || png_data == NULL || png_size == NULL || width == 0 || height == 0) {
        return 0;
    }
    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
    if (png == NULL) {
        return 0;
    }
    png_infop info = png_create_info_struct(png);
    if (info == NULL) {
        png_destroy_write_struct(&png, NULL);
        return 0;
    }
    CX11PngBuffer buffer = {0};
    if (setjmp(png_jmpbuf(png)) != 0) {
        free(buffer.data);
        png_destroy_write_struct(&png, &info);
        return 0;
    }
    png_set_write_fn(png, &buffer, cx11_png_write, cx11_png_flush);
    png_set_IHDR(
        png,
        info,
        width,
        height,
        8,
        PNG_COLOR_TYPE_RGBA,
        PNG_INTERLACE_NONE,
        PNG_COMPRESSION_TYPE_DEFAULT,
        PNG_FILTER_TYPE_DEFAULT
    );
    png_write_info(png, info);
    png_bytep *rows = (png_bytep *)malloc((size_t)height * sizeof(png_bytep));
    if (rows == NULL) {
        png_error(png, "PNG row allocation failed");
    }
    for (unsigned int row = 0; row < height; row++) {
        rows[row] = (png_bytep)(pixels + (size_t)row * stride);
    }
    png_write_image(png, rows);
    png_write_end(png, NULL);
    free(rows);
    png_destroy_write_struct(&png, &info);
    *png_data = buffer.data;
    *png_size = buffer.size;
    return 1;
}

#endif
