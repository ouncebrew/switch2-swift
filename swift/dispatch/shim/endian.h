/* newlib has no endian.h. The console is little-endian AArch64. */
#ifndef DISPATCH_SHIM_ENDIAN_H
#define DISPATCH_SHIM_ENDIAN_H

#include <stdint.h>

#define __BYTE_ORDER 1234
#define __LITTLE_ENDIAN 1234
#define __BIG_ENDIAN 4321
#define BYTE_ORDER __BYTE_ORDER
#define LITTLE_ENDIAN __LITTLE_ENDIAN
#define BIG_ENDIAN __BIG_ENDIAN

static inline uint16_t htobe16(uint16_t value) { return __builtin_bswap16(value); }
static inline uint32_t htobe32(uint32_t value) { return __builtin_bswap32(value); }
static inline uint64_t htobe64(uint64_t value) { return __builtin_bswap64(value); }

static inline uint16_t betoh16(uint16_t value) { return __builtin_bswap16(value); }
static inline uint32_t betoh32(uint32_t value) { return __builtin_bswap32(value); }
static inline uint64_t betoh64(uint64_t value) { return __builtin_bswap64(value); }

static inline uint16_t htole16(uint16_t value) { return value; }
static inline uint32_t htole32(uint32_t value) { return value; }
static inline uint64_t htole64(uint64_t value) { return value; }

static inline uint16_t letoh16(uint16_t value) { return value; }
static inline uint32_t letoh32(uint32_t value) { return value; }
static inline uint64_t letoh64(uint64_t value) { return value; }

static inline uint16_t be16toh(uint16_t value) { return __builtin_bswap16(value); }
static inline uint32_t be32toh(uint32_t value) { return __builtin_bswap32(value); }
static inline uint64_t be64toh(uint64_t value) { return __builtin_bswap64(value); }

static inline uint16_t le16toh(uint16_t value) { return value; }
static inline uint32_t le32toh(uint32_t value) { return value; }
static inline uint64_t le64toh(uint64_t value) { return value; }

#endif
