#ifndef EQBAR_CATOMICS_H
#define EQBAR_CATOMICS_H

#include <stdint.h>

// Minimal acquire/release primitives used to hand parameter snapshots to the
// real-time audio thread without locks or allocations.

static inline int64_t eqb_load_i64(const int64_t *p) {
  return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

static inline void eqb_store_i64(int64_t *p, int64_t v) {
  __atomic_store_n(p, v, __ATOMIC_RELEASE);
}

static inline void *eqb_load_ptr(void *const *p) {
  return __atomic_load_n(p, __ATOMIC_ACQUIRE);
}

static inline void *eqb_exchange_ptr(void **p, void *v) {
  return __atomic_exchange_n(p, v, __ATOMIC_ACQ_REL);
}

#endif
