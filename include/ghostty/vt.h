/**
 * @file vt.h
 *
 * libghostty-vt - Virtual terminal emulator library
 * 
 * This library provides functionality for parsing and handling terminal
 * escape sequences as well as maintaining terminal state such as styles,
 * cursor position, screen, scrollback, and more.
 *
 * WARNING: This is an incomplete, work-in-progress API. It is not yet
 * stable and is definitely going to change. 
 */

/**
 * @mainpage libghostty-vt - Virtual Terminal Emulator Library
 *
 * libghostty-vt is a C library which implements a modern terminal emulator,
 * extracted from the [Ghostty](https://ghostty.org) terminal emulator.
 *
 * libghostty-vt contains the logic for handling the core parts of a terminal
 * emulator: parsing terminal escape sequences, maintaining terminal state,
 * encoding input events, etc. It can handle scrollback, line wrapping, 
 * reflow on resize, and more.
 *
 * @warning This library is currently in development and the API is not yet stable.
 * Breaking changes are expected in future versions. Use with caution in production code.
 *
 * @section groups_sec API Reference
 *
 * The API is organized into the following groups:
 * - @ref key "Key Encoding" - Encode key events into terminal sequences
 * - @ref osc "OSC Parser" - Parse OSC (Operating System Command) sequences
 * - @ref allocator "Memory Management" - Memory management and custom allocators
 *
 * @section examples_sec Examples
 *
 * Complete working examples:
 * - @ref c-vt/src/main.c - OSC parser example
 * - @ref c-vt-key-encode/src/main.c - Key encoding example
 *
 */

/** @example c-vt/src/main.c
 * This example demonstrates how to use the OSC parser to parse an OSC sequence,
 * extract command information, and retrieve command-specific data like window titles.
 */

/** @example c-vt-key-encode/src/main.c
 * This example demonstrates how to use the key encoder to convert key events
 * into terminal escape sequences using the Kitty keyboard protocol.
 */

#ifndef GHOSTTY_VT_H
#define GHOSTTY_VT_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

//-------------------------------------------------------------------
// Types

/**
 * Opaque handle to an OSC parser instance.
 * 
 * This handle represents an OSC (Operating System Command) parser that can
 * be used to parse the contents of OSC sequences. This isn't a full VT
 * parser; it is only the OSC parser component. This is useful if you have
 * a parser already and want to only extract and handle OSC sequences.
 *
 * @ingroup osc
 */
typedef struct GhosttyOscParser *GhosttyOscParser;

/**
 * Opaque handle to a single OSC command.
 * 
 * This handle represents a parsed OSC (Operating System Command) command.
 * The command can be queried for its type and associated data using
 * `ghostty_osc_command_type` and `ghostty_osc_command_data`.
 *
 * @ingroup osc
 */
typedef struct GhosttyOscCommand *GhosttyOscCommand;

/**
 * Result codes for libghostty-vt operations.
 */
typedef enum {
    /** Operation completed successfully */
    GHOSTTY_SUCCESS = 0,
    /** Operation failed due to failed allocation */
    GHOSTTY_OUT_OF_MEMORY = -1,
} GhosttyResult;

/**
 * OSC command types.
 *
 * @ingroup osc
 */
typedef enum {
  GHOSTTY_OSC_COMMAND_INVALID = 0,
  GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_TITLE = 1,
  GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_ICON = 2,
  GHOSTTY_OSC_COMMAND_PROMPT_START = 3,
  GHOSTTY_OSC_COMMAND_PROMPT_END = 4,
  GHOSTTY_OSC_COMMAND_END_OF_INPUT = 5,
  GHOSTTY_OSC_COMMAND_END_OF_COMMAND = 6,
  GHOSTTY_OSC_COMMAND_CLIPBOARD_CONTENTS = 7,
  GHOSTTY_OSC_COMMAND_REPORT_PWD = 8,
  GHOSTTY_OSC_COMMAND_MOUSE_SHAPE = 9,
  GHOSTTY_OSC_COMMAND_COLOR_OPERATION = 10,
  GHOSTTY_OSC_COMMAND_KITTY_COLOR_PROTOCOL = 11,
  GHOSTTY_OSC_COMMAND_SHOW_DESKTOP_NOTIFICATION = 12,
  GHOSTTY_OSC_COMMAND_HYPERLINK_START = 13,
  GHOSTTY_OSC_COMMAND_HYPERLINK_END = 14,
  GHOSTTY_OSC_COMMAND_CONEMU_SLEEP = 15,
  GHOSTTY_OSC_COMMAND_CONEMU_SHOW_MESSAGE_BOX = 16,
  GHOSTTY_OSC_COMMAND_CONEMU_CHANGE_TAB_TITLE = 17,
  GHOSTTY_OSC_COMMAND_CONEMU_PROGRESS_REPORT = 18,
  GHOSTTY_OSC_COMMAND_CONEMU_WAIT_INPUT = 19,
  GHOSTTY_OSC_COMMAND_CONEMU_GUIMACRO = 20,
} GhosttyOscCommandType;

/**
 * OSC command data types.
 * 
 * These values specify what type of data to extract from an OSC command
 * using `ghostty_osc_command_data`.
 *
 * @ingroup osc
 */
typedef enum {
  /** Invalid data type. Never results in any data extraction. */
  GHOSTTY_OSC_DATA_INVALID = 0,
  
  /** 
   * Window title string data.
   *
   * Valid for: GHOSTTY_OSC_COMMAND_CHANGE_WINDOW_TITLE
   *
   * Output type: const char ** (pointer to null-terminated string)
   *
   * Lifetime: Valid until the next call to any ghostty_osc_* function with 
   * the same parser instance. Memory is owned by the parser.
   */
  GHOSTTY_OSC_DATA_CHANGE_WINDOW_TITLE_STR = 1,
} GhosttyOscCommandData;

//-------------------------------------------------------------------
// Allocator Interface

/** @defgroup allocator Memory Management
 *
 * libghostty-vt does require memory allocation for various operations,
 * but is resilient to allocation failures and will gracefully handle
 * out-of-memory situations by returning error codes.
 *
 * The exact memory management semantics are documented in the relevant
 * functions and data structures.
 *
 * libghostty-vt uses explicit memory allocation via an allocator
 * interface provided by GhosttyAllocator. The interface is based on the
 * [Zig](https://ziglang.org) allocator interface, since this has been
 * shown to be a flexible and powerful interface in practice and enables
 * a wide variety of allocation strategies.
 *
 * **For the common case, you can pass NULL as the allocator for any
 * function that accepts one,** and libghostty will use a default allocator.
 * The default allocator will be libc malloc/free if libc is linked. 
 * Otherwise, a custom allocator is used (currently Zig's SMP allocator)
 * that doesn't require any external dependencies.
 *
 * ## Basic Usage
 *
 * For simple use cases, you can ignore this interface entirely by passing NULL
 * as the allocator parameter to functions that accept one. This will use the
 * default allocator (typically libc malloc/free, if libc is linked, but
 * we provide our own default allocator if libc isn't linked).
 *
 * To use a custom allocator:
 * 1. Implement the GhosttyAllocatorVtable function pointers
 * 2. Create a GhosttyAllocator struct with your vtable and context
 * 3. Pass the allocator to functions that accept one
 *
 * @{
 */

/**
 * Function table for custom memory allocator operations.
 * 
 * This vtable defines the interface for a custom memory allocator. All
 * function pointers must be valid and non-NULL.
 *
 * @ingroup allocator
 *
 * If you're not going to use a custom allocator, you can ignore all of
 * this. All functions that take an allocator pointer allow NULL to use a
 * default allocator.
 *
 * The interface is based on the Zig allocator interface. I'll say up front
 * that it is easy to look at this interface and think "wow, this is really
 * overcomplicated". The reason for this complexity is well thought out by
 * the Zig folks, and it enables a diverse set of allocation strategies
 * as shown by the Zig ecosystem. As a consolation, please note that many
 * of the arguments are only needed for advanced use cases and can be
 * safely ignored in simple implementations. For example, if you look at 
 * the Zig implementation of the libc allocator in `lib/std/heap.zig`
 * (search for CAllocator), you'll see it is very simple.
 *
 * We chose to align with the Zig allocator interface because:
 *
 *   1. It is a proven interface that serves a wide variety of use cases
 *      in the real world via the Zig ecosystem. It's shown to work.
 *
 *   2. Our core implementation itself is Zig, and this lets us very
 *      cheaply and easily convert between C and Zig allocators.
 *
 * NOTE(mitchellh): In the future, we can have default implementations of
 * resize/remap and allow those to be null.
 */
typedef struct {
    /**
     * Return a pointer to `len` bytes with specified `alignment`, or return
     * `NULL` indicating the allocation failed.
     *
     * @param ctx The allocator context
     * @param len Number of bytes to allocate
     * @param alignment Required alignment for the allocation. Guaranteed to
     *   be a power of two between 1 and 16 inclusive.
     * @param ret_addr First return address of the allocation call stack (0 if not provided)
     * @return Pointer to allocated memory, or NULL if allocation failed
     */
    void* (*alloc)(void *ctx, size_t len, uint8_t alignment, uintptr_t ret_addr);
    
    /**
     * Attempt to expand or shrink memory in place.
     *
     * `memory_len` must equal the length requested from the most recent
     * successful call to `alloc`, `resize`, or `remap`. `alignment` must
     * equal the same value that was passed as the `alignment` parameter to
     * the original `alloc` call.
     *
     * `new_len` must be greater than zero.
     *
     * @param ctx The allocator context
     * @param memory Pointer to the memory block to resize
     * @param memory_len Current size of the memory block
     * @param alignment Alignment (must match original allocation)
     * @param new_len New requested size
     * @param ret_addr First return address of the allocation call stack (0 if not provided)
     * @return true if resize was successful in-place, false if relocation would be required
     */
    bool (*resize)(void *ctx, void *memory, size_t memory_len, uint8_t alignment, size_t new_len, uintptr_t ret_addr);
    
    /**
     * Attempt to expand or shrink memory, allowing relocation.
     *
     * `memory_len` must equal the length requested from the most recent
     * successful call to `alloc`, `resize`, or `remap`. `alignment` must
     * equal the same value that was passed as the `alignment` parameter to
     * the original `alloc` call.
     *
     * A non-`NULL` return value indicates the resize was successful. The
     * allocation may have same address, or may have been relocated. In either
     * case, the allocation now has size of `new_len`. A `NULL` return value
     * indicates that the resize would be equivalent to allocating new memory,
     * copying the bytes from the old memory, and then freeing the old memory.
     * In such case, it is more efficient for the caller to perform the copy.
     *
     * `new_len` must be greater than zero.
     *
     * @param ctx The allocator context
     * @param memory Pointer to the memory block to remap
     * @param memory_len Current size of the memory block
     * @param alignment Alignment (must match original allocation)
     * @param new_len New requested size
     * @param ret_addr First return address of the allocation call stack (0 if not provided)
     * @return Pointer to resized memory (may be relocated), or NULL if manual copy is needed
     */
    void* (*remap)(void *ctx, void *memory, size_t memory_len, uint8_t alignment, size_t new_len, uintptr_t ret_addr);
    
    /**
     * Free and invalidate a region of memory.
     *
     * `memory_len` must equal the length requested from the most recent
     * successful call to `alloc`, `resize`, or `remap`. `alignment` must
     * equal the same value that was passed as the `alignment` parameter to
     * the original `alloc` call.
     *
     * @param ctx The allocator context
     * @param memory Pointer to the memory block to free
     * @param memory_len Size of the memory block
     * @param alignment Alignment (must match original allocation)
     * @param ret_addr First return address of the allocation call stack (0 if not provided)
     */
    void (*free)(void *ctx, void *memory, size_t memory_len, uint8_t alignment, uintptr_t ret_addr);
} GhosttyAllocatorVtable;

/**
 * Custom memory allocator.
 *
 * For functions that take an allocator pointer, a NULL pointer indicates
 * that the default allocator should be used. The default allocator will 
 * be libc malloc/free if we're linking to libc. If libc isn't linked,
 * a custom allocator is used (currently Zig's SMP allocator).
 *
 * @ingroup allocator
 *
 * Usage example:
 * @code
 * GhosttyAllocator allocator = {
 *     .vtable = &my_allocator_vtable,
 *     .ctx = my_allocator_state
 * };
 * @endcode
 */
typedef struct {
    /**
     * Opaque context pointer passed to all vtable functions.
     * This allows the allocator implementation to maintain state
     * or reference external resources needed for memory management.
     */
    void *ctx;

    /**
     * Pointer to the allocator's vtable containing function pointers
     * for memory operations (alloc, resize, remap, free).
     */
    const GhosttyAllocatorVtable *vtable;
} GhosttyAllocator;

/** @} */ // end of allocator group

//-------------------------------------------------------------------
// Key Encoding 

/** @defgroup key Key Encoding
 *
 * Utilities for encoding key events into terminal escape sequences,
 * supporting both legacy encoding as well as Kitty Keyboard Protocol.
 *
 * ## Basic Usage
 *
 * 1. Create an encoder instance with ghostty_key_encoder_new()
 * 2. Configure encoder options with ghostty_key_encoder_setopt().
 * 3. For each key event:
 *    - Create a key event with ghostty_key_event_new()
 *    - Set event properties (action, key, modifiers, etc.)
 *    - Encode with ghostty_key_encoder_encode()
 *    - Free the event with ghostty_key_event_free()
 *    - Note: You can also reuse the same key event multiple times by
 *      changing its properties.
 * 4. Free the encoder with ghostty_key_encoder_free() when done
 *
 * ## Example
 *
 * @code{.c}
 * #include <assert.h>
 * #include <stdio.h>
 * #include <ghostty/vt.h>
 * 
 * int main() {
 *   // Create encoder
 *   GhosttyKeyEncoder encoder;
 *   GhosttyResult result = ghostty_key_encoder_new(NULL, &encoder);
 *   assert(result == GHOSTTY_SUCCESS);
 * 
 *   // Enable Kitty keyboard protocol with all features
 *   ghostty_key_encoder_setopt(encoder, GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS, 
 *                              &(uint8_t){GHOSTTY_KITTY_KEY_ALL});
 * 
 *   // Create and configure key event for Ctrl+C press
 *   GhosttyKeyEvent event;
 *   result = ghostty_key_event_new(NULL, &event);
 *   assert(result == GHOSTTY_SUCCESS);
 *   ghostty_key_event_set_action(event, GHOSTTY_KEY_ACTION_PRESS);
 *   ghostty_key_event_set_key(event, GHOSTTY_KEY_C);
 *   ghostty_key_event_set_mods(event, GHOSTTY_MODS_CTRL);
 * 
 *   // Encode the key event
 *   char buf[128];
 *   size_t written = 0;
 *   result = ghostty_key_encoder_encode(encoder, event, buf, sizeof(buf), &written);
 *   assert(result == GHOSTTY_SUCCESS);
 * 
 *   // Use the encoded sequence (e.g., write to terminal)
 *   fwrite(buf, 1, written, stdout);
 * 
 *   // Cleanup
 *   ghostty_key_event_free(event);
 *   ghostty_key_encoder_free(encoder);
 *   return 0;
 * }
 * @endcode
 *
 * For a complete working example, see example/c-vt-key-encode in the
 * repository.
 *
 * @{
 */

/**
 * Opaque handle to a key event.
 * 
 * This handle represents a keyboard input event containing information about
 * the physical key pressed, modifiers, and generated text. The event can be
 * configured using the `ghostty_key_event_set_*` functions.
 *
 * @ingroup key
 */
typedef struct GhosttyKeyEvent *GhosttyKeyEvent;

/**
 * Keyboard input event types.
 *
 * @ingroup key
 */
typedef enum {
    /** Key was released */
    GHOSTTY_KEY_ACTION_RELEASE = 0,
    /** Key was pressed */
    GHOSTTY_KEY_ACTION_PRESS = 1,
    /** Key is being repeated (held down) */
    GHOSTTY_KEY_ACTION_REPEAT = 2,
} GhosttyKeyAction;

/**
 * Keyboard modifier keys bitmask.
 *
 * A bitmask representing all keyboard modifiers. This tracks which modifier keys 
 * are pressed and, where supported by the platform, which side (left or right) 
 * of each modifier is active.
 *
 * Use the GHOSTTY_MODS_* constants to test and set individual modifiers.
 *
 * Modifier side bits are only meaningful when the corresponding modifier bit is set.
 * Not all platforms support distinguishing between left and right modifier 
 * keys and Ghostty is built to expect that some platforms may not provide this
 * information.
 *
 * @ingroup key
 */
typedef uint16_t GhosttyMods;

/** Shift key is pressed */
#define GHOSTTY_MODS_SHIFT (1 << 0)
/** Control key is pressed */
#define GHOSTTY_MODS_CTRL (1 << 1)
/** Alt/Option key is pressed */
#define GHOSTTY_MODS_ALT (1 << 2)
/** Super/Command/Windows key is pressed */
#define GHOSTTY_MODS_SUPER (1 << 3)
/** Caps Lock is active */
#define GHOSTTY_MODS_CAPS_LOCK (1 << 4)
/** Num Lock is active */
#define GHOSTTY_MODS_NUM_LOCK (1 << 5)

/**
 * Right shift is pressed (0 = left, 1 = right).
 * Only meaningful when GHOSTTY_MODS_SHIFT is set.
 */
#define GHOSTTY_MODS_SHIFT_SIDE (1 << 6)
/**
 * Right ctrl is pressed (0 = left, 1 = right).
 * Only meaningful when GHOSTTY_MODS_CTRL is set.
 */
#define GHOSTTY_MODS_CTRL_SIDE (1 << 7)
/**
 * Right alt is pressed (0 = left, 1 = right).
 * Only meaningful when GHOSTTY_MODS_ALT is set.
 */
#define GHOSTTY_MODS_ALT_SIDE (1 << 8)
/**
 * Right super is pressed (0 = left, 1 = right).
 * Only meaningful when GHOSTTY_MODS_SUPER is set.
 */
#define GHOSTTY_MODS_SUPER_SIDE (1 << 9)

/**
 * Physical key codes.
 *
 * The set of key codes that Ghostty is aware of. These represent physical keys 
 * on the keyboard and are layout-independent. For example, the "a" key on a US 
 * keyboard is the same as the "ф" key on a Russian keyboard, but both will 
 * report the same key_a value.
 *
 * Layout-dependent strings are provided separately as UTF-8 text and are produced 
 * by the platform. These values are based on the W3C UI Events KeyboardEvent code 
 * standard. See: https://www.w3.org/TR/uievents-code
 *
 * @ingroup key
 */
typedef enum {
    GHOSTTY_KEY_UNIDENTIFIED = 0,

    // Writing System Keys (W3C § 3.1.1)
    GHOSTTY_KEY_BACKQUOTE,
    GHOSTTY_KEY_BACKSLASH,
    GHOSTTY_KEY_BRACKET_LEFT,
    GHOSTTY_KEY_BRACKET_RIGHT,
    GHOSTTY_KEY_COMMA,
    GHOSTTY_KEY_DIGIT_0,
    GHOSTTY_KEY_DIGIT_1,
    GHOSTTY_KEY_DIGIT_2,
    GHOSTTY_KEY_DIGIT_3,
    GHOSTTY_KEY_DIGIT_4,
    GHOSTTY_KEY_DIGIT_5,
    GHOSTTY_KEY_DIGIT_6,
    GHOSTTY_KEY_DIGIT_7,
    GHOSTTY_KEY_DIGIT_8,
    GHOSTTY_KEY_DIGIT_9,
    GHOSTTY_KEY_EQUAL,
    GHOSTTY_KEY_INTL_BACKSLASH,
    GHOSTTY_KEY_INTL_RO,
    GHOSTTY_KEY_INTL_YEN,
    GHOSTTY_KEY_A,
    GHOSTTY_KEY_B,
    GHOSTTY_KEY_C,
    GHOSTTY_KEY_D,
    GHOSTTY_KEY_E,
    GHOSTTY_KEY_F,
    GHOSTTY_KEY_G,
    GHOSTTY_KEY_H,
    GHOSTTY_KEY_I,
    GHOSTTY_KEY_J,
    GHOSTTY_KEY_K,
    GHOSTTY_KEY_L,
    GHOSTTY_KEY_M,
    GHOSTTY_KEY_N,
    GHOSTTY_KEY_O,
    GHOSTTY_KEY_P,
    GHOSTTY_KEY_Q,
    GHOSTTY_KEY_R,
    GHOSTTY_KEY_S,
    GHOSTTY_KEY_T,
    GHOSTTY_KEY_U,
    GHOSTTY_KEY_V,
    GHOSTTY_KEY_W,
    GHOSTTY_KEY_X,
    GHOSTTY_KEY_Y,
    GHOSTTY_KEY_Z,
    GHOSTTY_KEY_MINUS,
    GHOSTTY_KEY_PERIOD,
    GHOSTTY_KEY_QUOTE,
    GHOSTTY_KEY_SEMICOLON,
    GHOSTTY_KEY_SLASH,

    // Functional Keys (W3C § 3.1.2)
    GHOSTTY_KEY_ALT_LEFT,
    GHOSTTY_KEY_ALT_RIGHT,
    GHOSTTY_KEY_BACKSPACE,
    GHOSTTY_KEY_CAPS_LOCK,
    GHOSTTY_KEY_CONTEXT_MENU,
    GHOSTTY_KEY_CONTROL_LEFT,
    GHOSTTY_KEY_CONTROL_RIGHT,
    GHOSTTY_KEY_ENTER,
    GHOSTTY_KEY_META_LEFT,
    GHOSTTY_KEY_META_RIGHT,
    GHOSTTY_KEY_SHIFT_LEFT,
    GHOSTTY_KEY_SHIFT_RIGHT,
    GHOSTTY_KEY_SPACE,
    GHOSTTY_KEY_TAB,
    GHOSTTY_KEY_CONVERT,
    GHOSTTY_KEY_KANA_MODE,
    GHOSTTY_KEY_NON_CONVERT,

    // Control Pad Section (W3C § 3.2)
    GHOSTTY_KEY_DELETE,
    GHOSTTY_KEY_END,
    GHOSTTY_KEY_HELP,
    GHOSTTY_KEY_HOME,
    GHOSTTY_KEY_INSERT,
    GHOSTTY_KEY_PAGE_DOWN,
    GHOSTTY_KEY_PAGE_UP,

    // Arrow Pad Section (W3C § 3.3)
    GHOSTTY_KEY_ARROW_DOWN,
    GHOSTTY_KEY_ARROW_LEFT,
    GHOSTTY_KEY_ARROW_RIGHT,
    GHOSTTY_KEY_ARROW_UP,

    // Numpad Section (W3C § 3.4)
    GHOSTTY_KEY_NUM_LOCK,
    GHOSTTY_KEY_NUMPAD_0,
    GHOSTTY_KEY_NUMPAD_1,
    GHOSTTY_KEY_NUMPAD_2,
    GHOSTTY_KEY_NUMPAD_3,
    GHOSTTY_KEY_NUMPAD_4,
    GHOSTTY_KEY_NUMPAD_5,
    GHOSTTY_KEY_NUMPAD_6,
    GHOSTTY_KEY_NUMPAD_7,
    GHOSTTY_KEY_NUMPAD_8,
    GHOSTTY_KEY_NUMPAD_9,
    GHOSTTY_KEY_NUMPAD_ADD,
    GHOSTTY_KEY_NUMPAD_BACKSPACE,
    GHOSTTY_KEY_NUMPAD_CLEAR,
    GHOSTTY_KEY_NUMPAD_CLEAR_ENTRY,
    GHOSTTY_KEY_NUMPAD_COMMA,
    GHOSTTY_KEY_NUMPAD_DECIMAL,
    GHOSTTY_KEY_NUMPAD_DIVIDE,
    GHOSTTY_KEY_NUMPAD_ENTER,
    GHOSTTY_KEY_NUMPAD_EQUAL,
    GHOSTTY_KEY_NUMPAD_MEMORY_ADD,
    GHOSTTY_KEY_NUMPAD_MEMORY_CLEAR,
    GHOSTTY_KEY_NUMPAD_MEMORY_RECALL,
    GHOSTTY_KEY_NUMPAD_MEMORY_STORE,
    GHOSTTY_KEY_NUMPAD_MEMORY_SUBTRACT,
    GHOSTTY_KEY_NUMPAD_MULTIPLY,
    GHOSTTY_KEY_NUMPAD_PAREN_LEFT,
    GHOSTTY_KEY_NUMPAD_PAREN_RIGHT,
    GHOSTTY_KEY_NUMPAD_SUBTRACT,
    GHOSTTY_KEY_NUMPAD_SEPARATOR,
    GHOSTTY_KEY_NUMPAD_UP,
    GHOSTTY_KEY_NUMPAD_DOWN,
    GHOSTTY_KEY_NUMPAD_RIGHT,
    GHOSTTY_KEY_NUMPAD_LEFT,
    GHOSTTY_KEY_NUMPAD_BEGIN,
    GHOSTTY_KEY_NUMPAD_HOME,
    GHOSTTY_KEY_NUMPAD_END,
    GHOSTTY_KEY_NUMPAD_INSERT,
    GHOSTTY_KEY_NUMPAD_DELETE,
    GHOSTTY_KEY_NUMPAD_PAGE_UP,
    GHOSTTY_KEY_NUMPAD_PAGE_DOWN,

    // Function Section (W3C § 3.5)
    GHOSTTY_KEY_ESCAPE,
    GHOSTTY_KEY_F1,
    GHOSTTY_KEY_F2,
    GHOSTTY_KEY_F3,
    GHOSTTY_KEY_F4,
    GHOSTTY_KEY_F5,
    GHOSTTY_KEY_F6,
    GHOSTTY_KEY_F7,
    GHOSTTY_KEY_F8,
    GHOSTTY_KEY_F9,
    GHOSTTY_KEY_F10,
    GHOSTTY_KEY_F11,
    GHOSTTY_KEY_F12,
    GHOSTTY_KEY_F13,
    GHOSTTY_KEY_F14,
    GHOSTTY_KEY_F15,
    GHOSTTY_KEY_F16,
    GHOSTTY_KEY_F17,
    GHOSTTY_KEY_F18,
    GHOSTTY_KEY_F19,
    GHOSTTY_KEY_F20,
    GHOSTTY_KEY_F21,
    GHOSTTY_KEY_F22,
    GHOSTTY_KEY_F23,
    GHOSTTY_KEY_F24,
    GHOSTTY_KEY_F25,
    GHOSTTY_KEY_FN,
    GHOSTTY_KEY_FN_LOCK,
    GHOSTTY_KEY_PRINT_SCREEN,
    GHOSTTY_KEY_SCROLL_LOCK,
    GHOSTTY_KEY_PAUSE,

    // Media Keys (W3C § 3.6)
    GHOSTTY_KEY_BROWSER_BACK,
    GHOSTTY_KEY_BROWSER_FAVORITES,
    GHOSTTY_KEY_BROWSER_FORWARD,
    GHOSTTY_KEY_BROWSER_HOME,
    GHOSTTY_KEY_BROWSER_REFRESH,
    GHOSTTY_KEY_BROWSER_SEARCH,
    GHOSTTY_KEY_BROWSER_STOP,
    GHOSTTY_KEY_EJECT,
    GHOSTTY_KEY_LAUNCH_APP_1,
    GHOSTTY_KEY_LAUNCH_APP_2,
    GHOSTTY_KEY_LAUNCH_MAIL,
    GHOSTTY_KEY_MEDIA_PLAY_PAUSE,
    GHOSTTY_KEY_MEDIA_SELECT,
    GHOSTTY_KEY_MEDIA_STOP,
    GHOSTTY_KEY_MEDIA_TRACK_NEXT,
    GHOSTTY_KEY_MEDIA_TRACK_PREVIOUS,
    GHOSTTY_KEY_POWER,
    GHOSTTY_KEY_SLEEP,
    GHOSTTY_KEY_AUDIO_VOLUME_DOWN,
    GHOSTTY_KEY_AUDIO_VOLUME_MUTE,
    GHOSTTY_KEY_AUDIO_VOLUME_UP,
    GHOSTTY_KEY_WAKE_UP,

    // Legacy, Non-standard, and Special Keys (W3C § 3.7)
    GHOSTTY_KEY_COPY,
    GHOSTTY_KEY_CUT,
    GHOSTTY_KEY_PASTE,
} GhosttyKey;

/**
 * Kitty keyboard protocol flags.
 *
 * Bitflags representing the various modes of the Kitty keyboard protocol.
 * These can be combined using bitwise OR operations. Valid values all
 * start with `GHOSTTY_KITTY_KEY_`.
 *
 * @ingroup key
 */
typedef uint8_t GhosttyKittyKeyFlags;

/** Kitty keyboard protocol disabled (all flags off) */
#define GHOSTTY_KITTY_KEY_DISABLED 0

/** Disambiguate escape codes */
#define GHOSTTY_KITTY_KEY_DISAMBIGUATE (1 << 0)

/** Report key press and release events */
#define GHOSTTY_KITTY_KEY_REPORT_EVENTS (1 << 1)

/** Report alternate key codes */
#define GHOSTTY_KITTY_KEY_REPORT_ALTERNATES (1 << 2)

/** Report all key events including those normally handled by the terminal */
#define GHOSTTY_KITTY_KEY_REPORT_ALL (1 << 3)

/** Report associated text with key events */
#define GHOSTTY_KITTY_KEY_REPORT_ASSOCIATED (1 << 4)

/** All Kitty keyboard protocol flags enabled */
#define GHOSTTY_KITTY_KEY_ALL (GHOSTTY_KITTY_KEY_DISAMBIGUATE | GHOSTTY_KITTY_KEY_REPORT_EVENTS | GHOSTTY_KITTY_KEY_REPORT_ALTERNATES | GHOSTTY_KITTY_KEY_REPORT_ALL | GHOSTTY_KITTY_KEY_REPORT_ASSOCIATED)

/**
 * macOS option key behavior.
 *
 * Determines whether the "option" key on macOS is treated as "alt" or not.
 * See the Ghostty `macos-option-as-alt` configuration option for more details.
 *
 * @ingroup key
 */
typedef enum {
    /** Option key is not treated as alt */
    GHOSTTY_OPTION_AS_ALT_FALSE = 0,
    /** Option key is treated as alt */
    GHOSTTY_OPTION_AS_ALT_TRUE = 1,
    /** Only left option key is treated as alt */
    GHOSTTY_OPTION_AS_ALT_LEFT = 2,
    /** Only right option key is treated as alt */
    GHOSTTY_OPTION_AS_ALT_RIGHT = 3,
} GhosttyOptionAsAlt;

/**
 * Create a new key event instance.
 * 
 * Creates a new key event with default values. The event must be freed using
 * ghostty_key_event_free() when no longer needed.
 * 
 * @param allocator Pointer to the allocator to use for memory management, or NULL to use the default allocator
 * @param event Pointer to store the created key event handle
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 * 
 * @ingroup key
 */
GhosttyResult ghostty_key_event_new(const GhosttyAllocator *allocator, GhosttyKeyEvent *event);

/**
 * Free a key event instance.
 * 
 * Releases all resources associated with the key event. After this call,
 * the event handle becomes invalid and must not be used.
 * 
 * @param event The key event handle to free (may be NULL)
 * 
 * @ingroup key
 */
void ghostty_key_event_free(GhosttyKeyEvent event);

/**
 * Set the key action (press, release, repeat).
 *
 * @param event The key event handle, must not be NULL
 * @param action The action to set
 *
 * @ingroup key
 */
void ghostty_key_event_set_action(GhosttyKeyEvent event, GhosttyKeyAction action);

/**
 * Get the key action (press, release, repeat).
 *
 * @param event The key event handle, must not be NULL
 * @return The key action
 *
 * @ingroup key
 */
GhosttyKeyAction ghostty_key_event_get_action(GhosttyKeyEvent event);

/**
 * Set the physical key code.
 *
 * @param event The key event handle, must not be NULL
 * @param key The physical key code to set
 *
 * @ingroup key
 */
void ghostty_key_event_set_key(GhosttyKeyEvent event, GhosttyKey key);

/**
 * Get the physical key code.
 *
 * @param event The key event handle, must not be NULL
 * @return The physical key code
 *
 * @ingroup key
 */
GhosttyKey ghostty_key_event_get_key(GhosttyKeyEvent event);

/**
 * Set the modifier keys bitmask.
 *
 * @param event The key event handle, must not be NULL
 * @param mods The modifier keys bitmask to set
 *
 * @ingroup key
 */
void ghostty_key_event_set_mods(GhosttyKeyEvent event, GhosttyMods mods);

/**
 * Get the modifier keys bitmask.
 *
 * @param event The key event handle, must not be NULL
 * @return The modifier keys bitmask
 *
 * @ingroup key
 */
GhosttyMods ghostty_key_event_get_mods(GhosttyKeyEvent event);

/**
 * Set the consumed modifiers bitmask.
 *
 * @param event The key event handle, must not be NULL
 * @param consumed_mods The consumed modifiers bitmask to set
 *
 * @ingroup key
 */
void ghostty_key_event_set_consumed_mods(GhosttyKeyEvent event, GhosttyMods consumed_mods);

/**
 * Get the consumed modifiers bitmask.
 *
 * @param event The key event handle, must not be NULL
 * @return The consumed modifiers bitmask
 *
 * @ingroup key
 */
GhosttyMods ghostty_key_event_get_consumed_mods(GhosttyKeyEvent event);

/**
 * Set whether the key event is part of a composition sequence.
 *
 * @param event The key event handle, must not be NULL
 * @param composing Whether the key event is part of a composition sequence
 *
 * @ingroup key
 */
void ghostty_key_event_set_composing(GhosttyKeyEvent event, bool composing);

/**
 * Get whether the key event is part of a composition sequence.
 *
 * @param event The key event handle, must not be NULL
 * @return Whether the key event is part of a composition sequence
 *
 * @ingroup key
 */
bool ghostty_key_event_get_composing(GhosttyKeyEvent event);

/**
 * Set the UTF-8 text generated by the key event.
 *
 * The key event does NOT take ownership of the text pointer. The caller
 * must ensure the string remains valid for the lifetime needed by the event.
 *
 * @param event The key event handle, must not be NULL
 * @param utf8 The UTF-8 text to set (or NULL for empty)
 * @param len Length of the UTF-8 text in bytes
 *
 * @ingroup key
 */
void ghostty_key_event_set_utf8(GhosttyKeyEvent event, const char *utf8, size_t len);

/**
 * Get the UTF-8 text generated by the key event.
 *
 * The returned pointer is valid until the event is freed or the UTF-8 text is modified.
 *
 * @param event The key event handle, must not be NULL
 * @param len Pointer to store the length of the UTF-8 text in bytes (may be NULL)
 * @return The UTF-8 text (or NULL for empty)
 *
 * @ingroup key
 */
const char *ghostty_key_event_get_utf8(GhosttyKeyEvent event, size_t *len);

/**
 * Set the unshifted Unicode codepoint.
 *
 * @param event The key event handle, must not be NULL
 * @param codepoint The unshifted Unicode codepoint to set
 *
 * @ingroup key
 */
void ghostty_key_event_set_unshifted_codepoint(GhosttyKeyEvent event, uint32_t codepoint);

/**
 * Get the unshifted Unicode codepoint.
 *
 * @param event The key event handle, must not be NULL
 * @return The unshifted Unicode codepoint
 *
 * @ingroup key
 */
uint32_t ghostty_key_event_get_unshifted_codepoint(GhosttyKeyEvent event);

/**
 * Opaque handle to a key encoder instance.
 *
 * This handle represents a key encoder that converts key events into terminal
 * escape sequences. The encoder supports both legacy encoding and the Kitty
 * Keyboard Protocol, depending on the options set.
 *
 * @ingroup key
 */
typedef struct GhosttyKeyEncoder *GhosttyKeyEncoder;

/**
 * Key encoder option identifiers.
 *
 * These values are used with ghostty_key_encoder_setopt() to configure
 * the behavior of the key encoder.
 *
 * @ingroup key
 */
typedef enum {
    /** Terminal DEC mode 1: cursor key application mode (value: bool) */
    GHOSTTY_KEY_ENCODER_OPT_CURSOR_KEY_APPLICATION = 0,
    
    /** Terminal DEC mode 66: keypad key application mode (value: bool) */
    GHOSTTY_KEY_ENCODER_OPT_KEYPAD_KEY_APPLICATION = 1,
    
    /** Terminal DEC mode 1035: ignore keypad with numlock (value: bool) */
    GHOSTTY_KEY_ENCODER_OPT_IGNORE_KEYPAD_WITH_NUMLOCK = 2,
    
    /** Terminal DEC mode 1036: alt sends escape prefix (value: bool) */
    GHOSTTY_KEY_ENCODER_OPT_ALT_ESC_PREFIX = 3,
    
    /** xterm modifyOtherKeys mode 2 (value: bool) */
    GHOSTTY_KEY_ENCODER_OPT_MODIFY_OTHER_KEYS_STATE_2 = 4,
    
    /** Kitty keyboard protocol flags (value: GhosttyKittyKeyFlags bitmask) */
    GHOSTTY_KEY_ENCODER_OPT_KITTY_FLAGS = 5,
    
    /** macOS option-as-alt setting (value: GhosttyOptionAsAlt) */
    GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT = 6,
} GhosttyKeyEncoderOption;

/**
 * Create a new key encoder instance.
 *
 * Creates a new key encoder with default options. The encoder can be configured
 * using ghostty_key_encoder_setopt() and must be freed using
 * ghostty_key_encoder_free() when no longer needed.
 *
 * @param allocator Pointer to the allocator to use for memory management, or NULL to use the default allocator
 * @param encoder Pointer to store the created encoder handle
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup key
 */
GhosttyResult ghostty_key_encoder_new(const GhosttyAllocator *allocator, GhosttyKeyEncoder *encoder);

/**
 * Free a key encoder instance.
 *
 * Releases all resources associated with the key encoder. After this call,
 * the encoder handle becomes invalid and must not be used.
 *
 * @param encoder The encoder handle to free (may be NULL)
 *
 * @ingroup key
 */
void ghostty_key_encoder_free(GhosttyKeyEncoder encoder);

/**
 * Set an option on the key encoder.
 *
 * Configures the behavior of the key encoder. Options control various aspects
 * of encoding such as terminal modes (cursor key application mode, keypad mode),
 * protocol selection (Kitty keyboard protocol flags), and platform-specific
 * behaviors (macOS option-as-alt).
 *
 * A null pointer value does nothing. It does not reset the value to the
 * default. The setopt call will do nothing.
 *
 * @param encoder The encoder handle, must not be NULL
 * @param option The option to set
 * @param value Pointer to the value to set (type depends on the option)
 *
 * @ingroup key
 */
void ghostty_key_encoder_setopt(GhosttyKeyEncoder encoder, GhosttyKeyEncoderOption option, const void *value);

/**
 * Encode a key event into a terminal escape sequence.
 *
 * Converts a key event into the appropriate terminal escape sequence based on
 * the encoder's current options. The sequence is written to the provided buffer.
 *
 * Not all key events produce output. For example, unmodified modifier keys
 * typically don't generate escape sequences. Check the out_len parameter to
 * determine if any data was written.
 *
 * If the output buffer is too small, this function returns GHOSTTY_OUT_OF_MEMORY
 * and out_len will contain the required buffer size. The caller can then
 * allocate a larger buffer and call the function again.
 *
 * @param encoder The encoder handle, must not be NULL
 * @param event The key event to encode, must not be NULL
 * @param out_buf Buffer to write the encoded sequence to
 * @param out_buf_size Size of the output buffer in bytes
 * @param out_len Pointer to store the number of bytes written (may be NULL)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY if buffer too small, or other error code
 *
 * ## Example: Calculate required buffer size
 *
 * @code{.c}
 * // Query the required size with a NULL buffer (always returns OUT_OF_MEMORY)
 * size_t required = 0;
 * GhosttyResult result = ghostty_key_encoder_encode(encoder, event, NULL, 0, &required);
 * assert(result == GHOSTTY_OUT_OF_MEMORY);
 * 
 * // Allocate buffer of required size
 * char *buf = malloc(required);
 * 
 * // Encode with properly sized buffer
 * size_t written = 0;
 * result = ghostty_key_encoder_encode(encoder, event, buf, required, &written);
 * assert(result == GHOSTTY_SUCCESS);
 * 
 * // Use the encoded sequence...
 * 
 * free(buf);
 * @endcode
 *
 * ## Example: Direct encoding with static buffer
 *
 * @code{.c}
 * // Most escape sequences are short, so a static buffer often suffices
 * char buf[128];
 * size_t written = 0;
 * GhosttyResult result = ghostty_key_encoder_encode(encoder, event, buf, sizeof(buf), &written);
 * 
 * if (result == GHOSTTY_SUCCESS) {
 *   // Write the encoded sequence to the terminal
 *   write(pty_fd, buf, written);
 * } else if (result == GHOSTTY_OUT_OF_MEMORY) {
 *   // Buffer too small, written contains required size
 *   char *dynamic_buf = malloc(written);
 *   result = ghostty_key_encoder_encode(encoder, event, dynamic_buf, written, &written);
 *   assert(result == GHOSTTY_SUCCESS);
 *   write(pty_fd, dynamic_buf, written);
 *   free(dynamic_buf);
 * }
 * @endcode
 *
 * @ingroup key
 */
GhosttyResult ghostty_key_encoder_encode(GhosttyKeyEncoder encoder, GhosttyKeyEvent event, char *out_buf, size_t out_buf_size, size_t *out_len);

/** @} */ // end of key group

//-------------------------------------------------------------------
// OSC Parser

/** @defgroup osc OSC Parser
 *
 * OSC (Operating System Command) sequence parser and command handling.
 *
 * The parser operates in a streaming fashion, processing input byte-by-byte
 * to handle OSC sequences that may arrive in fragments across multiple reads.
 * This interface makes it easy to integrate into most environments and avoids
 * over-allocating buffers.
 *
 * ## Basic Usage
 *
 * 1. Create a parser instance with ghostty_osc_new()
 * 2. Feed bytes to the parser using ghostty_osc_next() 
 * 3. Finalize parsing with ghostty_osc_end() to get the command
 * 4. Query command type and extract data using ghostty_osc_command_type()
 *    and ghostty_osc_command_data()
 * 5. Free the parser with ghostty_osc_free() when done
 *
 * @{
 */

/**
 * Create a new OSC parser instance.
 * 
 * Creates a new OSC (Operating System Command) parser using the provided
 * allocator. The parser must be freed using ghostty_vt_osc_free() when
 * no longer needed.
 * 
 * @param allocator Pointer to the allocator to use for memory management, or NULL to use the default allocator
 * @param parser Pointer to store the created parser handle
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 */
GhosttyResult ghostty_osc_new(const GhosttyAllocator *allocator, GhosttyOscParser *parser);

/**
 * Free an OSC parser instance.
 * 
 * Releases all resources associated with the OSC parser. After this call,
 * the parser handle becomes invalid and must not be used.
 * 
 * @param parser The parser handle to free (may be NULL)
 */
void ghostty_osc_free(GhosttyOscParser parser);

/**
 * Reset an OSC parser instance to its initial state.
 * 
 * Resets the parser state, clearing any partially parsed OSC sequences
 * and returning the parser to its initial state. This is useful for
 * reusing a parser instance or recovering from parse errors.
 * 
 * @param parser The parser handle to reset, must not be null.
 */
void ghostty_osc_reset(GhosttyOscParser parser);

/**
 * Parse the next byte in an OSC sequence.
 * 
 * Processes a single byte as part of an OSC sequence. The parser maintains
 * internal state to track the progress through the sequence. Call this
 * function for each byte in the sequence data.
 *
 * When finished pumping the parser with bytes, call ghostty_osc_end
 * to get the final result.
 * 
 * @param parser The parser handle, must not be null.
 * @param byte The next byte to parse
 */
void ghostty_osc_next(GhosttyOscParser parser, uint8_t byte);

/**
 * Finalize OSC parsing and retrieve the parsed command.
 * 
 * Call this function after feeding all bytes of an OSC sequence to the parser
 * using ghostty_osc_next() with the exception of the terminating character
 * (ESC or ST). This function finalizes the parsing process and returns the 
 * parsed OSC command.
 *
 * The return value is never NULL. Invalid commands will return a command
 * with type GHOSTTY_OSC_COMMAND_INVALID.
 * 
 * The terminator parameter specifies the byte that terminated the OSC sequence
 * (typically 0x07 for BEL or 0x5C for ST after ESC). This information is
 * preserved in the parsed command so that responses can use the same terminator
 * format for better compatibility with the calling program. For commands that
 * do not require a response, this parameter is ignored and the resulting
 * command will not retain the terminator information.
 * 
 * The returned command handle is valid until the next call to any 
 * `ghostty_osc_*` function with the same parser instance with the exception
 * of command introspection functions such as `ghostty_osc_command_type`.
 * 
 * @param parser The parser handle, must not be null.
 * @param terminator The terminating byte of the OSC sequence (0x07 for BEL, 0x5C for ST)
 * @return Handle to the parsed OSC command
 */
GhosttyOscCommand ghostty_osc_end(GhosttyOscParser parser, uint8_t terminator);

/**
 * Get the type of an OSC command.
 * 
 * Returns the type identifier for the given OSC command. This can be used
 * to determine what kind of command was parsed and what data might be
 * available from it.
 * 
 * @param command The OSC command handle to query (may be NULL)
 * @return The command type, or GHOSTTY_OSC_COMMAND_INVALID if command is NULL
 */
GhosttyOscCommandType ghostty_osc_command_type(GhosttyOscCommand command);

/**
 * Extract data from an OSC command.
 * 
 * Extracts typed data from the given OSC command based on the specified
 * data type. The output pointer must be of the appropriate type for the
 * requested data kind. Valid command types, output types, and memory
 * safety information are documented in the `GhosttyOscCommandData` enum.
 *
 * @param command The OSC command handle to query (may be NULL)
 * @param data The type of data to extract
 * @param out Pointer to store the extracted data (type depends on data parameter)
 * @return true if data extraction was successful, false otherwise
 */
bool ghostty_osc_command_data(GhosttyOscCommand command, GhosttyOscCommandData data, void *out);

/** @} */ // end of osc group

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_H */
