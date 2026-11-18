#import <MediaExtension/MediaExtension.h>
NS_ASSUME_NONNULL_BEGIN
/// Swift hides MEByteSource's synchronous read; this shim exposes it.
static inline BOOL MEByteSourceReadSync(MEByteSource *src, int64_t offset, size_t length, void *dest, size_t *outRead, NSError * _Nullable * _Nullable err) {
    return [src readDataOfLength:length fromOffset:offset toDestination:dest bytesRead:outRead error:err];
}
NS_ASSUME_NONNULL_END
