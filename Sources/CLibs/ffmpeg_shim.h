#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/mastering_display_metadata.h>
static inline int64_t lp_av_nopts(void) { return AV_NOPTS_VALUE; }
static inline int lp_averror_eof(void) { return AVERROR_EOF; }
static inline int lp_averror_eagain(void) { return AVERROR(EAGAIN); }
#include <libavutil/pixdesc.h>
