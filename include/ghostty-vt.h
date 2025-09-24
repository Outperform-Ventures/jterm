/**
 * @file ghostty-vt.h
 *
 * libghostty-vt - Virtual terminal sequence parsing library
 * 
 * This library provides functionality for parsing and handling terminal
 * escape sequences as well as maintaining terminal state such as styles,
 * cursor position, screen, scrollback, and more.
 */

#ifndef GHOSTTY_VT_H
#define GHOSTTY_VT_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

//-------------------------------------------------------------------
// Types

/**
 * Opaque handle to an OSC parser instance.
 * 
 * This handle represents an OSC (Operating System Command) parser that can
 * be used to parse the contents of OSC sequences. This isn't a full VT
 * parser; it is only the OSC parser component. This is useful if you have
 * a parser already and want to only extract and handle OSC sequences.
 */
typedef struct GhosttyOscParser *GhosttyOscParser;

/**
 * Result codes for libghostty-vt operations.
 */
typedef enum {
    /** Operation completed successfully */
    GHOSTTY_VT_SUCCESS = 0,
    /** Operation failed due to failed allocation */
    GHOSTTY_VT_OUT_OF_MEMORY = -1,
} GhosttyVtResult;

//-------------------------------------------------------------------
// Allocator Interface

/**
 * Function table for custom memory allocator operations.
 * 
 * This vtable defines the interface for a custom memory allocator. All
 * function pointers must be valid and non-NULL.
 *
 * NOTE(mitchellh): In the future, I think we can have default
 * implementations if resize/remap are null. alloc/free must always
 * be supplied.
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
} GhosttyVtAllocatorVtable;

/**
 * Custom memory allocator.
 *
 * For functions that take an allocator pointer, a NULL pointer indicates
 * that the default allocator should be used. The default allocator will 
 * be libc malloc/free if we're linking to libc. If libc isn't linked,
 * a custom allocator is used (currently Zig's SMP allocator).
 *
 * Usage example:
 * @code
 * GhosttyVtAllocator allocator = {
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
    const GhosttyVtAllocatorVtable *vtable;
} GhosttyVtAllocator;

//-------------------------------------------------------------------
// Functions

/**
 * Create a new OSC parser instance.
 * 
 * Creates a new OSC (Operating System Command) parser using the provided
 * allocator. The parser must be freed using ghostty_vt_osc_free() when
 * no longer needed.
 * 
 * @param allocator Pointer to the allocator to use for memory management, or NULL to use the default allocator
 * @param parser Pointer to store the created parser handle
 * @return GHOSTTY_VT_SUCCESS on success, or an error code on failure
 */
GhosttyVtResult ghostty_vt_osc_new(const GhosttyVtAllocator* allocator, GhosttyOscParser* parser);

/**
 * Free an OSC parser instance.
 * 
 * Releases all resources associated with the OSC parser. After this call,
 * the parser handle becomes invalid and must not be used.
 * 
 * @param parser The parser handle to free (may be NULL)
 */
void ghostty_vt_osc_free(GhosttyOscParser parser);

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_H */
