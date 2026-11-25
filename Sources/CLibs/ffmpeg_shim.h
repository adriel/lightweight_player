#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/mastering_display_metadata.h>
static inline int64_t lp_av_nopts(void) { return AV_NOPTS_VALUE; }
static inline int lp_averror_eof(void) { return AVERROR_EOF; }
static inline int lp_averror_eagain(void) { return AVERROR(EAGAIN); }
#include <libavutil/pixdesc.h>
#include <libavutil/display.h>
/// Display-matrix rotation of a stream (degrees, counter-clockwise; 0 if none).
static inline double lp_stream_rotation(const AVCodecParameters *par) {
    const AVPacketSideData *sd = av_packet_side_data_get(par->coded_side_data, par->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    if (!sd || sd->size < 9 * 4) return 0;
    double r = av_display_rotation_get((const int32_t *)sd->data);
    return r != r ? 0 : r;
}
