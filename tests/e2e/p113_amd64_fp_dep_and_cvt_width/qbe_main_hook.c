/* P113 test-only QBE build: vendor/qbe/main.c with `simpljmp` (run right
 * after register allocation) routed through p113_simpljmp in
 * qbe_slot_hook.c. Never part of out/qbe. */
#define simpljmp p113_simpljmp
#include "main.c"
