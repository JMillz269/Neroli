// Copyright 2023 Citra Emulator Project
// Licensed under GPLv2 or any later version
// Refer to the misc/licenses/gplv2.txt file included.

#include <algorithm>
#ifdef __APPLE__
#include <dispatch/dispatch.h>
#endif

#include "video_core/rasterizer_cache/surface_params.h"
#include "video_core/rasterizer_cache/texture_codec.h"
#include "video_core/rasterizer_cache/utils.h"

namespace VideoCore {

u32 MipLevels(u32 width, u32 height, u32 max_level) {
    u32 levels = 1;
    while (width > 8 && height > 8) {
        levels++;
        width >>= 1;
        height >>= 1;
    }

    return std::min(levels, max_level + 1);
}

void EncodeTexture(const SurfaceParams& surface_info, PAddr start_addr, PAddr end_addr,
                   std::span<u8> source, std::span<u8> dest, bool convert) {
    const PixelFormat format = surface_info.pixel_format;
    const u32 func_index = static_cast<u32>(format);

    if (surface_info.is_tiled) {
        const MortonFunc SwizzleImpl =
            (convert ? SWIZZLE_TABLE_CONVERTED : SWIZZLE_TABLE)[func_index];
        if (SwizzleImpl) {
            SwizzleImpl(surface_info.width, surface_info.height, start_addr - surface_info.addr,
                        end_addr - surface_info.addr, source, dest);
            return;
        }
    } else {
        const LinearFunc LinearEncodeImpl =
            (convert ? LINEAR_ENCODE_TABLE_CONVERTED : LINEAR_ENCODE_TABLE)[func_index];
        if (LinearEncodeImpl) {
            LinearEncodeImpl(source, dest);
            return;
        }
    }

    LOG_ERROR(HW_GPU, "Unimplemented texture encode function for pixel format = {}, tiled = {}",
              func_index, surface_info.is_tiled);
    UNIMPLEMENTED();
}

namespace {

#ifdef __APPLE__
/// Textures smaller than this are decoded on the calling thread: handing out work costs about as
/// much as decoding them.
constexpr u32 PARALLEL_DECODE_MIN_BYTES = 128 * 1024;
/// Every thread gets at least this much, and no more than this many threads work on a texture
/// (the performance cores; more would land on the efficiency cores and the threads of the game).
constexpr u32 PARALLEL_DECODE_MIN_CHUNK = 64 * 1024;
constexpr u32 PARALLEL_DECODE_MAX_CHUNKS = 4;
#endif

/// Decodes a tiled texture, in parts on several threads when it is big (Apple's Grand Central
/// Dispatch). The tiles of a texture are independent: each part covers whole tiles and writes its
/// own part of the linear picture, so the parts do not touch each other's data.
void UnswizzleParallel(MortonFunc unswizzle, const SurfaceParams& info, u32 start, u32 end,
                       std::span<u8> source, std::span<u8> dest) {
#ifdef __APPLE__
    const u32 tile_size = GetFormatBpp(info.pixel_format) * 64 / 8;
    const u32 bytes = end - start;
    const u32 chunks = std::min(PARALLEL_DECODE_MAX_CHUNKS, bytes / PARALLEL_DECODE_MIN_CHUNK);
    if (bytes >= PARALLEL_DECODE_MIN_BYTES && chunks >= 2 && tile_size > 0 &&
        source.size() >= bytes && start % tile_size == 0 && end % tile_size == 0) {
        // Whole tiles per part.
        const u32 tiles = bytes / tile_size;
        const u32 tiles_per_chunk = (tiles + chunks - 1) / chunks;
        const u32 width = info.width;
        const u32 height = info.height;
        dispatch_apply(chunks, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0),
                       ^(size_t index) {
                         const u32 first = static_cast<u32>(index) * tiles_per_chunk;
                         if (first >= tiles) {
                             return;
                         }
                         const u32 last = std::min(first + tiles_per_chunk, tiles);
                         unswizzle(width, height, start + first * tile_size,
                                   start + last * tile_size, dest,
                                   source.subspan(first * tile_size, (last - first) * tile_size));
                       });
        return;
    }
#endif
    unswizzle(info.width, info.height, start, end, dest, source);
}

} // Anonymous namespace

void DecodeTexture(const SurfaceParams& surface_info, PAddr start_addr, PAddr end_addr,
                   std::span<u8> source, std::span<u8> dest, bool convert) {
    const PixelFormat format = surface_info.pixel_format;
    const u32 func_index = static_cast<u32>(format);

    if (surface_info.is_tiled) {
        const MortonFunc UnswizzleImpl =
            (convert ? UNSWIZZLE_TABLE_CONVERTED : UNSWIZZLE_TABLE)[func_index];
        if (UnswizzleImpl) {
            UnswizzleParallel(UnswizzleImpl, surface_info, start_addr - surface_info.addr,
                              end_addr - surface_info.addr, source, dest);
            return;
        }
    } else {
        const LinearFunc LinearDecodeImpl =
            (convert ? LINEAR_DECODE_TABLE_CONVERTED : LINEAR_DECODE_TABLE)[func_index];
        if (LinearDecodeImpl) {
            LinearDecodeImpl(source, dest);
            return;
        }
    }

    LOG_ERROR(HW_GPU, "Unimplemented texture decode function for pixel format = {}, tiled = {}",
              func_index, surface_info.is_tiled);
    UNIMPLEMENTED();
}

} // namespace VideoCore
