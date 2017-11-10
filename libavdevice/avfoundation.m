/*
 * AVFoundation input device
 * Copyright (c) 2014 Thilo Borgmann <thilo.borgmann@mail.de>
 *
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

/**
 * @file
 * AVFoundation input device
 * @author Thilo Borgmann <thilo.borgmann@mail.de>
 */

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AppKit/AppKit.h>

#include <pthread.h>

#include "libavutil/pixdesc.h"
#include "libavutil/opt.h"
#include "libavutil/avstring.h"
#include "libavformat/internal.h"
#include "libavutil/internal.h"
#include "libavutil/parseutils.h"
#include "libavutil/time.h"
#include "libavutil/imgutils.h"
#include "avdevice.h"

#define QUEUE_SIZE 20

static const int avf_time_base = 1000000;

static const AVRational avf_time_base_q = {
    .num = 1,
    .den = avf_time_base
};

struct AVFPixelFormatSpec {
    enum AVPixelFormat ff_id;
    OSType avf_id;
};

static const struct AVFPixelFormatSpec avf_pixel_formats[] = {
    { AV_PIX_FMT_MONOBLACK,    kCVPixelFormatType_1Monochrome },
    { AV_PIX_FMT_RGB555BE,     kCVPixelFormatType_16BE555 },
    { AV_PIX_FMT_RGB555LE,     kCVPixelFormatType_16LE555 },
    { AV_PIX_FMT_RGB565BE,     kCVPixelFormatType_16BE565 },
    { AV_PIX_FMT_RGB565LE,     kCVPixelFormatType_16LE565 },
    { AV_PIX_FMT_RGB24,        kCVPixelFormatType_24RGB },
    { AV_PIX_FMT_BGR24,        kCVPixelFormatType_24BGR },
    { AV_PIX_FMT_0RGB,         kCVPixelFormatType_32ARGB },
    { AV_PIX_FMT_BGR0,         kCVPixelFormatType_32BGRA },
    { AV_PIX_FMT_0BGR,         kCVPixelFormatType_32ABGR },
    { AV_PIX_FMT_RGB0,         kCVPixelFormatType_32RGBA },
    { AV_PIX_FMT_BGR48BE,      kCVPixelFormatType_48RGB },
    { AV_PIX_FMT_UYVY422,      kCVPixelFormatType_422YpCbCr8 },
    { AV_PIX_FMT_YUVA444P,     kCVPixelFormatType_4444YpCbCrA8R },
    { AV_PIX_FMT_YUVA444P16LE, kCVPixelFormatType_4444AYpCbCr16 },
    { AV_PIX_FMT_YUV444P,      kCVPixelFormatType_444YpCbCr8 },
    { AV_PIX_FMT_YUV422P16,    kCVPixelFormatType_422YpCbCr16 },
    { AV_PIX_FMT_YUV422P10,    kCVPixelFormatType_422YpCbCr10 },
    { AV_PIX_FMT_YUV444P10,    kCVPixelFormatType_444YpCbCr10 },
    { AV_PIX_FMT_YUV420P,      kCVPixelFormatType_420YpCbCr8Planar },
    { AV_PIX_FMT_NV12,         kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange },
    { AV_PIX_FMT_YUYV422,      kCVPixelFormatType_422YpCbCr8_yuvs },
#if !TARGET_OS_IPHONE && __MAC_OS_X_VERSION_MIN_REQUIRED >= 1080
    { AV_PIX_FMT_GRAY8,        kCVPixelFormatType_OneComponent8 },
#endif
    { AV_PIX_FMT_NONE, 0 }
};

enum {
    QUEUE_IS_EMPTY,
    QUEUE_HAS_BUFFERS,
};

typedef struct
{
    AVClass*        class;

    int             frames_captured;
    int             audio_frames_captured;
    int64_t         first_pts;
    int64_t         first_audio_pts;
    id              avf_delegate;
    id              avf_audio_delegate;
    int             list_audio_formats;

    AVCaptureDeviceFormat *audio_format;

    AVRational      framerate;
    
    int      framerate_actual;

    int             width, height;

    int             capture_cursor;
    int             capture_mouse_clicks;

    int             list_devices;
    int             video_device_index;
    int             video_stream_index;
    int             audio_device_index;
    int             audio_stream_index;

    char            *video_filename;
    char            *audio_filename;
    
    bool            started_recording;
    bool            dumpBuffer;
    
    bool            switch_packet;

    int             video_log;
    int             audio_log;

    unsigned long last_audio_pkt_time;
    unsigned long last_video_pkt_time;
    
    unsigned long pkt_index;
    long pkt_count;
    unsigned long first_packet_time;
    
    int             num_video_devices;

    int             audio_channels;
    int             audio_bits_per_sample;
    int             audio_float;
    int             audio_be;
    int             audio_signed_integer;
    int             audio_packed;

    int             audio_packet_size;
    
    int32_t         *audio_buffer;
    int             audio_buffer_size;

    enum AVPixelFormat pixel_format;

    AVCaptureSession         *capture_session;
    AVCaptureVideoDataOutput *video_output;
    AVCaptureAudioDataOutput *audio_output;

    NSConditionLock *lock;
    NSMutableArray *video_queue;
    NSMutableArray *audio_queue;
    
    NSMutableArray *video_time_queue;
    NSMutableArray *audio_time_queue;
    
    bool audioInterLog;
    bool audioNonInterLog;
    
    AVStream* audioStream;
    AVStream* videoStream;

    int audio_packet_count;
} AVFContext;

/** FrameReciever class - delegate for AVCaptureSession
 */
@interface AVFFrameReceiver : NSObject
{
    AVFContext* _context;
    AVFContext* ctx;

}

- (id)initWithContext:(AVFContext*)context;

- (void)  captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)videoFrame
         fromConnection:(AVCaptureConnection *)connection;

- (void)captureOutput:(AVCaptureOutput *)captureOutput didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection;
@end

@implementation AVFFrameReceiver

- (id)initWithContext:(AVFContext*)context
{
    if (self = [super init]) {
        _context = context;
        ctx = context;
    }
    return self;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    av_log(_context, AV_LOG_WARNING, "captureOutput dropped video sample buffer\n");
}

- (void)  captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)videoFrame
         fromConnection:(AVCaptureConnection *)connection
{
//    NSDate *methodStart = [NSDate date];
    
    NSMutableArray *queue = _context->video_queue;
    NSMutableArray *timeQueue = _context->video_time_queue;
    NSConditionLock *lock = _context->lock;

    CMItemCount count;
    CMSampleTimingInfo timing_info;
    
    unsigned long pkt_time = 0;
//    pkt_time = av_rescale_q(av_gettime(), AV_TIME_BASE_Q, avf_time_base_q);
    
    if (!CMSampleBufferDataIsReady(videoFrame)) {
        av_log(_context, AV_LOG_WARNING, "videoFrame data is not ready\n");
        return;
    }

    if (CMSampleBufferGetOutputSampleTimingInfoArray(videoFrame, 1, &timing_info, &count) == noErr) {
        if (timing_info.presentationTimeStamp.value == 0) {
            av_log(_context, AV_LOG_WARNING, "timing_info is zero\n");
            return;
        }
        AVRational timebase_q = av_make_q(1, timing_info.presentationTimeStamp.timescale);
        pkt_time = av_rescale_q(timing_info.presentationTimeStamp.value, timebase_q, avf_time_base_q);
    } else {
        av_log(_context, AV_LOG_WARNING, "vsample time info error\n");
        return;
    }
    
    if (ctx->first_packet_time == 0) {
        ctx->first_packet_time = pkt_time;
        av_log(_context, AV_LOG_INFO, "first video packet time %ld\n", pkt_time);
        ctx->first_pts = pkt_time;
    }
    
//    if (current_s != t_d) then
//        if (count > 0 && count != 15) then
//            puts "#{t_d}: #{count}"
//            end
//            current_s = t_d
//            count = 1;
//        else
//            count = count + 1
//            end
    int numberToDrop = 0;
    int numberToDuplicate = 0;
    int framerate = ctx->framerate.num;
//    if (ctx->framerate_actual != 0) {
//        framerate = ctx->framerate_actual;
//    }
    unsigned long time_s = (pkt_time - ctx->first_packet_time + 1000000/framerate/2)/1000000;
    //av_log(_context, AV_LOG_WARNING, "time_s: %ld pkt_index: %ld first_pkt %ld framerate: %ld\n", time_s, ctx->pkt_index, ctx->first_packet_time, ctx->framerate.num);

//    if (time_s != ctx->pkt_index) {
//        if (ctx->pkt_count != framerate) {
//            int diff = ctx->pkt_count - framerate;
//            if (diff > 0) {
//                ctx->pkt_count = 1 + diff - 1;
//                numberToDrop = 1;
//                av_log(_context, AV_LOG_WARNING, "dropping 1 packet %d \n", diff);
//            } else {
//                ctx->pkt_count = 1 + diff + 1;
//                numberToDuplicate = 1;
//                av_log(_context, AV_LOG_WARNING, "duplicating 1 packet %d \n", diff);
//            }
//        } else {
//            ctx->pkt_count = 1;
//        }
//        ctx->pkt_index = time_s;
//    } else {
//        ctx->pkt_count++;
////        av_log(_context, AV_LOG_WARNING, "count %ld\n", ctx->pkt_count);
//    }
    
    [lock lock];
    
    if ([queue count] == QUEUE_SIZE) {
        av_log(_context, AV_LOG_WARNING, "video queue is full, the oldest frame has been dropped\n");
        ctx->pkt_count--;
        [queue removeLastObject];
        [timeQueue removeLastObject];
    }
    
    if (numberToDuplicate) {
        [queue insertObject:(id)videoFrame atIndex:0];
        [timeQueue insertObject:[NSNumber numberWithUnsignedLong:pkt_time-1-ctx->first_pts] atIndex: 0];
    }
    if (!numberToDrop) {
        [queue insertObject:(id)videoFrame atIndex:0];
        [timeQueue insertObject:[NSNumber numberWithUnsignedLong:pkt_time-ctx->first_pts] atIndex: 0];
    }

    [lock unlockWithCondition:QUEUE_HAS_BUFFERS];

    ++_context->frames_captured;
//    NSDate *methodFinish = [NSDate date];
//    NSTimeInterval executionTime = [methodFinish timeIntervalSinceDate:methodStart];
//    av_log(_context, AV_LOG_INFO, "executionTime = %f\n", executionTime);
}

@end

/** AudioReciever class - delegate for AVCaptureSession
 */
@interface AVFAudioReceiver : NSObject
{
    AVFContext* _context;
}

- (id)initWithContext:(AVFContext*)context;

- (void)  captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)audioFrame
         fromConnection:(AVCaptureConnection *)connection;

- (void)captureOutput:(AVCaptureOutput *)captureOutput didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection;


@end

@implementation AVFAudioReceiver

- (id)initWithContext:(AVFContext*)context
{
    if (self = [super init]) {
        _context = context;
    }
    return self;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    av_log(_context, AV_LOG_WARNING, "captureOutput dropped audio sample buffer\n");
}

- (void)  captureOutput:(AVCaptureOutput *)captureOutput
  didOutputSampleBuffer:(CMSampleBufferRef)audioFrame
         fromConnection:(AVCaptureConnection *)connection
{
    NSMutableArray *queue = _context->audio_queue;
    NSConditionLock *lock = _context->lock;
    NSMutableArray *timeQueue = _context->audio_time_queue;
    
    CMItemCount count;
    CMSampleTimingInfo timing_info;
    unsigned long pkt_time = 0;
//    pkt_time = av_rescale_q(av_gettime(), AV_TIME_BASE_Q, avf_time_base_q)+AV_TIME_BASE_Q.den/3;

    if (CMSampleBufferGetOutputSampleTimingInfoArray(audioFrame, 1, &timing_info, &count) == noErr) {
        AVRational timebase_q = av_make_q(1, timing_info.presentationTimeStamp.timescale);
        pkt_time = av_rescale_q(timing_info.presentationTimeStamp.value, timebase_q, avf_time_base_q);
    } else {
        av_log(_context, AV_LOG_WARNING, "asample time info error\n");
    }

    [lock lock];

    if ([queue count] == QUEUE_SIZE*7) {
        av_log(_context, AV_LOG_WARNING, "audio queue is full, the oldest frame has been dropped\n");
        [queue removeLastObject];
        [timeQueue removeLastObject];
    }

    [queue insertObject:(id)audioFrame atIndex:0];
    [timeQueue insertObject:[NSNumber numberWithUnsignedLong:pkt_time] atIndex:0];

    [lock unlockWithCondition:QUEUE_HAS_BUFFERS];

    ++_context->audio_frames_captured;
}

@end

static void destroy_context(AVFContext* ctx)
{
    [ctx->capture_session stopRunning];

    [ctx->capture_session release];
    [ctx->video_output    release];
    [ctx->audio_output    release];
    [ctx->avf_delegate    release];
    [ctx->avf_audio_delegate release];

    ctx->capture_session = NULL;
    ctx->video_output    = NULL;
    ctx->audio_output    = NULL;
    ctx->avf_delegate    = NULL;
    ctx->avf_audio_delegate = NULL;

    av_freep(&ctx->audio_buffer);

    [ctx->audio_queue release];
    [ctx->video_queue release];
    [ctx->video_time_queue release];
    [ctx->audio_time_queue release];
    [ctx->lock release];

    ctx->audio_queue = NULL;
    ctx->video_queue = NULL;
    ctx->lock = NULL;
}

static void parse_device_name(AVFormatContext *s)
{
    AVFContext *ctx = (AVFContext*)s->priv_data;
    char *tmp = av_strdup(s->filename);
    char *save;

    if (tmp[0] != ':') {
        ctx->video_filename = av_strtok(tmp,  ":", &save);
        ctx->audio_filename = av_strtok(NULL, ":", &save);
    } else {
        ctx->audio_filename = av_strtok(tmp,  ":", &save);
    }
}

static enum AVCodecID get_audio_codec_id(AVCaptureDeviceFormat *audio_format)
{
    AudioStreamBasicDescription *audio_format_desc =
    (AudioStreamBasicDescription*)CMAudioFormatDescriptionGetStreamBasicDescription(audio_format.formatDescription);
    int audio_linear          = audio_format_desc->mFormatID ==
    kAudioFormatLinearPCM;
    int audio_bits_per_sample = audio_format_desc->mBitsPerChannel;
    int audio_float           = audio_format_desc->mFormatFlags &
    kAudioFormatFlagIsFloat;
    int audio_be              = audio_format_desc->mFormatFlags &
    kAudioFormatFlagIsBigEndian;
    int audio_signed_integer  = audio_format_desc->mFormatFlags &
    kAudioFormatFlagIsSignedInteger;
    int audio_packed          = audio_format_desc->mFormatFlags &
    kAudioFormatFlagIsPacked;
    
    enum AVCodecID ret = AV_CODEC_ID_NONE;
    
    if (audio_linear &&
        audio_float &&
        audio_bits_per_sample == 32 &&
        audio_packed) {
        ret = audio_be ? AV_CODEC_ID_PCM_F32BE : AV_CODEC_ID_PCM_F32LE;
    } else if (audio_linear &&
               audio_signed_integer &&
               audio_bits_per_sample == 16 &&
               audio_packed) {
        ret = audio_be ? AV_CODEC_ID_PCM_S16BE : AV_CODEC_ID_PCM_S16LE;
    } else if (audio_linear &&
               audio_signed_integer &&
               audio_bits_per_sample == 24 &&
               audio_packed) {
        ret = audio_be ? AV_CODEC_ID_PCM_S24BE : AV_CODEC_ID_PCM_S24LE;
    } else if (audio_linear &&
               audio_signed_integer &&
               audio_bits_per_sample == 32 &&
               audio_packed) {
        ret = audio_be ? AV_CODEC_ID_PCM_S32BE : AV_CODEC_ID_PCM_S32LE;
    } else if (audio_linear &&
                audio_signed_integer &&
                audio_bits_per_sample == 32 &&
                audio_packed) {
        ret = audio_be ? AV_CODEC_ID_PCM_S32BE : AV_CODEC_ID_PCM_S32LE;
    }
    
    return ret;
}

/**
 * Configure the video device.
 *
 * Configure the video device using a run-time approach to access properties
 * since formats, activeFormat are available since  iOS >= 7.0 or OSX >= 10.7
 * and activeVideoMaxFrameDuration is available since i0S >= 7.0 and OSX >= 10.9.
 *
 * The NSUndefinedKeyException must be handled by the caller of this function.
 *
 */
static int configure_video_device(AVFormatContext *s, AVCaptureDevice *video_device)
{
    AVFContext *ctx = (AVFContext*)s->priv_data;

    double framerate = ctx->framerate.num;
    if (ctx->framerate_actual != -1) {
        framerate = ctx->framerate_actual;
    }
    NSObject *range = nil;
    NSObject *format = nil;
    NSObject *selected_range = nil;
    NSObject *selected_format = nil;
    
    bool oldCam = false;

    for (format in [video_device valueForKey:@"formats"]) {
        CMFormatDescriptionRef formatDescription;
        CMVideoDimensions dimensions;

        formatDescription = (CMFormatDescriptionRef) [format performSelector:@selector(formatDescription)];
        dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);

        if ((ctx->width == 0 && ctx->height == 0) ||
            (dimensions.width == ctx->width && dimensions.height == ctx->height)) {

            selected_format = format;

            for (range in [format valueForKey:@"videoSupportedFrameRateRanges"]) {
                double max_framerate;
                double min_framerate;

                [[range valueForKey:@"maxFrameRate"] getValue:&max_framerate];
                [[range valueForKey:@"minFrameRate"] getValue:&min_framerate];
                
                if (max_framerate - min_framerate < 0.5) {
                    oldCam = true;
                }
                

                if (framerate <= (max_framerate + 0.01) && (min_framerate-0.01) <= framerate) {
                    ctx->width      = dimensions.width;
                    ctx->height     = dimensions.height;

                    selected_range = range;
                    break;
                }
            }
        }
    }

    if (!selected_format) {
        av_log(s, AV_LOG_ERROR, "Selected video size (%dx%d) is not supported by the device\n",
            ctx->width, ctx->height);
        goto unsupported_format;
    }

    if (!selected_range) {
        av_log(s, AV_LOG_ERROR, "Selected framerate (%f) is not supported by the device\n",
            framerate);
        goto unsupported_format;
    }

    if ([video_device lockForConfiguration:NULL] == YES) {
        CMTime time = CMTimeMake(1, framerate);
        NSValue *min_frame_duration = [NSValue valueWithCMTime:time];
        if (oldCam) {
            min_frame_duration = [selected_range valueForKey:@"minFrameDuration"];
        }

        [video_device setValue:selected_format forKey:@"activeFormat"];
        [video_device setValue:min_frame_duration forKey:@"activeVideoMinFrameDuration"];
        [video_device setValue:min_frame_duration forKey:@"activeVideoMaxFrameDuration"];
    } else {
        av_log(s, AV_LOG_ERROR, "Could not lock device for configuration");
        return AVERROR(EINVAL);
    }

    return 0;

unsupported_format:

    av_log(s, AV_LOG_ERROR, "Supported modes:\n");
    for (format in [video_device valueForKey:@"formats"]) {
        CMFormatDescriptionRef formatDescription;
        CMVideoDimensions dimensions;

        formatDescription = (CMFormatDescriptionRef) [format performSelector:@selector(formatDescription)];
        dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);

        for (range in [format valueForKey:@"videoSupportedFrameRateRanges"]) {
            double min_framerate;
            double max_framerate;

            [[range valueForKey:@"minFrameRate"] getValue:&min_framerate];
            [[range valueForKey:@"maxFrameRate"] getValue:&max_framerate];
            av_log(s, AV_LOG_ERROR, "  %dx%d@[%f %f]fps\n",
                dimensions.width, dimensions.height,
                min_framerate, max_framerate);
        }
    }
    return AVERROR(EINVAL);
}

static int add_video_device(AVFormatContext *s, AVCaptureDevice *video_device)
{
    AVFContext *ctx = (AVFContext*)s->priv_data;
    int ret;
    NSError *error  = nil;
    AVCaptureInput* capture_input = nil;
    struct AVFPixelFormatSpec pxl_fmt_spec;
    NSNumber *pixel_format;
    NSDictionary *capture_dict;
    dispatch_queue_t queue;

    if (ctx->video_device_index < ctx->num_video_devices) {
        capture_input = (AVCaptureInput*) [[[AVCaptureDeviceInput alloc] initWithDevice:video_device error:&error] autorelease];
    } else {
        capture_input = (AVCaptureInput*) video_device;
    }

    if (!capture_input) {
        av_log(s, AV_LOG_ERROR, "Failed to create AV capture input device: %s\n",
               [[error localizedDescription] UTF8String]);
        return 1;
    }

    if ([ctx->capture_session canAddInput:capture_input]) {
        [ctx->capture_session addInput:capture_input];
    } else {
        av_log(s, AV_LOG_ERROR, "can't add video input to capture session\n");
        return 1;
    }

    // Attaching output
    ctx->video_output = [[AVCaptureVideoDataOutput alloc] init];

    if (!ctx->video_output) {
        av_log(s, AV_LOG_ERROR, "Failed to init AV video output\n");
        return 1;
    }

    // Configure device framerate and video size
    @try {
        if ((ret = configure_video_device(s, video_device)) < 0) {
            return ret;
        }
    } @catch (NSException *exception) {
        if (![[exception name] isEqualToString:NSUndefinedKeyException]) {
          av_log (s, AV_LOG_ERROR, "An error occurred: %s", [exception.reason UTF8String]);
          return AVERROR_EXTERNAL;
        }
    }

    // select pixel format
    pxl_fmt_spec.ff_id = AV_PIX_FMT_NONE;

    for (int i = 0; avf_pixel_formats[i].ff_id != AV_PIX_FMT_NONE; i++) {
        if (ctx->pixel_format == avf_pixel_formats[i].ff_id) {
            pxl_fmt_spec = avf_pixel_formats[i];
            break;
        }
    }

    // check if selected pixel format is supported by AVFoundation
    if (pxl_fmt_spec.ff_id == AV_PIX_FMT_NONE) {
        av_log(s, AV_LOG_ERROR, "Selected pixel format (%s) is not supported by AVFoundation.\n",
               av_get_pix_fmt_name(pxl_fmt_spec.ff_id));
        return 1;
    }

    // check if the pixel format is available for this device
    if ([[ctx->video_output availableVideoCVPixelFormatTypes] indexOfObject:[NSNumber numberWithInt:pxl_fmt_spec.avf_id]] == NSNotFound) {
        av_log(s, AV_LOG_ERROR, "Selected pixel format (%s) is not supported by the input device.\n",
               av_get_pix_fmt_name(pxl_fmt_spec.ff_id));

        pxl_fmt_spec.ff_id = AV_PIX_FMT_NONE;

        av_log(s, AV_LOG_ERROR, "Supported pixel formats:\n");
        for (NSNumber *pxl_fmt in [ctx->video_output availableVideoCVPixelFormatTypes]) {
            struct AVFPixelFormatSpec pxl_fmt_dummy;
            pxl_fmt_dummy.ff_id = AV_PIX_FMT_NONE;
            for (int i = 0; avf_pixel_formats[i].ff_id != AV_PIX_FMT_NONE; i++) {
                if ([pxl_fmt intValue] == avf_pixel_formats[i].avf_id) {
                    pxl_fmt_dummy = avf_pixel_formats[i];
                    break;
                }
            }

            if (pxl_fmt_dummy.ff_id != AV_PIX_FMT_NONE) {
                av_log(s, AV_LOG_ERROR, "  %s\n", av_get_pix_fmt_name(pxl_fmt_dummy.ff_id));

                // select first supported pixel format instead of user selected (or default) pixel format
                if (pxl_fmt_spec.ff_id == AV_PIX_FMT_NONE) {
                    pxl_fmt_spec = pxl_fmt_dummy;
                }
            }
        }

        // fail if there is no appropriate pixel format or print a warning about overriding the pixel format
        if (pxl_fmt_spec.ff_id == AV_PIX_FMT_NONE) {
            return 1;
        } else {
            av_log(s, AV_LOG_WARNING, "Overriding selected pixel format to use %s instead.\n",
                   av_get_pix_fmt_name(pxl_fmt_spec.ff_id));
        }
    }

    ctx->pixel_format          = pxl_fmt_spec.ff_id;
    pixel_format = [NSNumber numberWithUnsignedInt:pxl_fmt_spec.avf_id];
    capture_dict = [NSDictionary dictionaryWithObject:pixel_format
                                               forKey:(id)kCVPixelBufferPixelFormatTypeKey];

    [ctx->video_output setVideoSettings:capture_dict];
    [ctx->video_output setAlwaysDiscardsLateVideoFrames:YES];

    ctx->avf_delegate = [[AVFFrameReceiver alloc] initWithContext:ctx];

    queue = dispatch_queue_create("avf_queue", NULL);
//    queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);

    [ctx->video_output setSampleBufferDelegate:ctx->avf_delegate queue:queue];
    dispatch_release(queue);

    if ([ctx->capture_session canAddOutput:ctx->video_output]) {
        [ctx->capture_session addOutput:ctx->video_output];
    } else {
        av_log(s, AV_LOG_ERROR, "can't add video output to capture session\n");
        return 1;
    }

    return 0;
}

static int add_audio_device(AVFormatContext *s, AVCaptureDevice *audio_device)
{
    AVFContext *ctx = (AVFContext*)s->priv_data;
    NSError *error  = nil;
    AVCaptureDeviceInput* audio_dev_input = [[[AVCaptureDeviceInput alloc] initWithDevice:audio_device error:&error] autorelease];
    dispatch_queue_t queue;

    if (!audio_dev_input) {
        av_log(s, AV_LOG_ERROR, "Failed to create AV capture input device: %s\n",
               [[error localizedDescription] UTF8String]);
        return 1;
    }

    if ([ctx->capture_session canAddInput:audio_dev_input]) {
        [ctx->capture_session addInput:audio_dev_input];
    } else {
        av_log(s, AV_LOG_ERROR, "can't add audio input to capture session\n");
        return 1;
    }

    // Attaching output
    ctx->audio_output = [[AVCaptureAudioDataOutput alloc] init];

    if (!ctx->audio_output) {
        av_log(s, AV_LOG_ERROR, "Failed to init AV audio output\n");
        return 1;
    }

    ctx->avf_audio_delegate = [[AVFAudioReceiver alloc] initWithContext:ctx];

    queue = dispatch_queue_create("avf_audio_queue", NULL);
//    queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0);

    [ctx->audio_output setSampleBufferDelegate:ctx->avf_audio_delegate queue:queue];
    dispatch_release(queue);
    
    if (ctx->audio_format) {
        if ([audio_device lockForConfiguration:NULL] == YES) {
            audio_device.activeFormat = ctx->audio_format;
        } else {
            av_log(s, AV_LOG_ERROR, "Could not lock audio device for configuration");
            return AVERROR(EINVAL);
        }
    }


    if ([ctx->capture_session canAddOutput:ctx->audio_output]) {
        [ctx->capture_session addOutput:ctx->audio_output];
    } else {
        av_log(s, AV_LOG_ERROR, "adding audio output to capture session failed\n");
        return 1;
    }

    return 0;
}

static int get_video_config(AVFormatContext *s)
{
    AVFContext *ctx = (AVFContext*)s->priv_data;
    CMSampleBufferRef sample_buffer;
    CVImageBufferRef image_buffer;
    CGSize image_buffer_size;
    AVStream* stream = avformat_new_stream(s, NULL);

    if (!stream) {
        return 1;
    }
    ctx->videoStream = stream;
    // Take stream info from the first frame.
//    while (ctx->frames_captured < 1) {
//        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, YES);
//    }

//    [ctx->lock lock];

    ctx->video_stream_index = stream->index;

    avpriv_set_pts_info(stream, 64, 1, avf_time_base);

    //sample_buffer     = (CMSampleBufferRef)[ctx->video_queue lastObject];
    //image_buffer      = CMSampleBufferGetImageBuffer(sample_buffer);
    //image_buffer_size = CVImageBufferGetEncodedSize(image_buffer);

    stream->codec->codec_id   = AV_CODEC_ID_RAWVIDEO;
    stream->codec->codec_type = AVMEDIA_TYPE_VIDEO;
    stream->codec->width      = ctx->width;
    stream->codec->height     = ctx->height;
    stream->codec->pix_fmt    = ctx->pixel_format;

//    [ctx->lock unlockWithCondition:QUEUE_HAS_BUFFERS];

//    [ctx->video_queue removeLastObject];

    return 0;
}

static int get_audio_config(AVFormatContext *s)
{
    AVFContext *ctx = (AVFContext*)s->priv_data;
    CMSampleBufferRef sample_buffer;
    CMFormatDescriptionRef format_desc;
    AVStream* stream = avformat_new_stream(s, NULL);

    if (!stream) {
        return 1;
    }
    ctx->audioStream = stream;

    // Take stream info from the first frame.
//    while (ctx->audio_frames_captured < 1) {
//        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.1, YES);
//    }

    //[ctx->lock lock];

    ctx->audio_stream_index = stream->index;

    avpriv_set_pts_info(stream, 64, 1, avf_time_base);

//    sample_buffer = (CMSampleBufferRef)[ctx->audio_queue lastObject];
    format_desc = CMSampleBufferGetFormatDescription(sample_buffer);
    if (!ctx->audio_format) {
        av_log(s, AV_LOG_ERROR, "audio format is null\n");
    }
    const AudioStreamBasicDescription *basic_desc = CMAudioFormatDescriptionGetStreamBasicDescription(ctx->audio_format.formatDescription);

    if (!basic_desc) {
        av_log(s, AV_LOG_ERROR, "audio format not available\n");
        return 1;
    }

    stream->codec->codec_type     = AVMEDIA_TYPE_AUDIO;
    stream->codec->sample_rate    = basic_desc->mSampleRate;
    stream->codec->channels       = basic_desc->mChannelsPerFrame;
    stream->codec->channel_layout = av_get_default_channel_layout(stream->codec->channels);

    ctx->audio_channels        = basic_desc->mChannelsPerFrame;
    ctx->audio_bits_per_sample = basic_desc->mBitsPerChannel;
    ctx->audio_float           = basic_desc->mFormatFlags & kAudioFormatFlagIsFloat;
    ctx->audio_be              = basic_desc->mFormatFlags & kAudioFormatFlagIsBigEndian;
    ctx->audio_signed_integer  = basic_desc->mFormatFlags & kAudioFormatFlagIsSignedInteger;
    ctx->audio_packed          = basic_desc->mFormatFlags & kAudioFormatFlagIsPacked;
    if (!ctx->audio_packed) {
        av_log(s, AV_LOG_WARNING, "audio is not packed!!!\n");
    }
    if (basic_desc->mFormatID == kAudioFormatLinearPCM &&
        ctx->audio_float &&
        ctx->audio_bits_per_sample == 32
        &&ctx->audio_packed
        ) {
        av_log(s, AV_LOG_WARNING, "audio is 32!!!\n");
        stream->codec->codec_id = ctx->audio_be ? AV_CODEC_ID_PCM_F32BE : AV_CODEC_ID_PCM_F32LE;
    } else if (basic_desc->mFormatID == kAudioFormatLinearPCM &&
        ctx->audio_signed_integer &&
        ctx->audio_bits_per_sample == 16
               &&ctx->audio_packed
               ) {
        av_log(s, AV_LOG_WARNING, "audio is 16!!!\n");
        stream->codec->codec_id = ctx->audio_be ? AV_CODEC_ID_PCM_S16BE : AV_CODEC_ID_PCM_S16LE;
    } else if (basic_desc->mFormatID == kAudioFormatLinearPCM &&
        ctx->audio_signed_integer &&
        ctx->audio_bits_per_sample == 24
               &&ctx->audio_packed
               ) {
        av_log(s, AV_LOG_WARNING, "audio is 24!!!\n");
        stream->codec->codec_id = ctx->audio_be ? AV_CODEC_ID_PCM_S24BE : AV_CODEC_ID_PCM_S24LE;
    } else if (basic_desc->mFormatID == kAudioFormatLinearPCM &&
        ctx->audio_signed_integer &&
        ctx->audio_bits_per_sample == 32
               &&ctx->audio_packed
               ) {
        av_log(s, AV_LOG_WARNING, "audio is 32!!!\n");

        stream->codec->codec_id = ctx->audio_be ? AV_CODEC_ID_PCM_S32BE : AV_CODEC_ID_PCM_S32LE;
    } else {
        av_log(s, AV_LOG_ERROR, "audio format is not supported %d, %d, %d, %d \n", basic_desc->mFormatID, ctx->audio_bits_per_sample, ctx->audio_signed_integer, ctx->audio_packed);
        return 1;
    }

//    if (ctx->audio_non_interleaved || true) {
//        CMBlockBufferRef block_buffer = CMSampleBufferGetDataBuffer(sample_buffer);
//        ctx->audio_buffer_size        = CMBlockBufferGetDataLength(block_buffer);
//        ctx->audio_buffer             = av_malloc(ctx->audio_buffer_size);
//        if (!ctx->audio_buffer) {
//            av_log(s, AV_LOG_ERROR, "error allocating audio buffer\n");
//            return 1;
//        }
//    }

    //[ctx->lock unlockWithCondition:QUEUE_HAS_BUFFERS];

    return 0;
}

static int avf_read_header(AVFormatContext *s)
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    int capture_screen      = 0;
    uint32_t num_screens    = 0;
    AVFContext *ctx         = (AVFContext*)s->priv_data;
    AVCaptureDevice *video_device = nil;
    AVCaptureDevice *audio_device = nil;
    // Find capture device
    NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo];
    ctx->num_video_devices = [devices count];

    ctx->first_pts          = av_gettime();
    ctx->first_audio_pts    = -1;

    ctx->lock = [[NSConditionLock alloc] initWithCondition:QUEUE_IS_EMPTY];
    ctx->video_queue = [[NSMutableArray alloc] initWithCapacity:QUEUE_SIZE];
    ctx->audio_queue = [[NSMutableArray alloc] initWithCapacity:QUEUE_SIZE*7];

    ctx->video_time_queue = [[NSMutableArray alloc] initWithCapacity:QUEUE_SIZE];
    ctx->audio_time_queue = [[NSMutableArray alloc] initWithCapacity:QUEUE_SIZE*7];

#if !TARGET_OS_IPHONE && __MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
    CGGetActiveDisplayList(0, NULL, &num_screens);
#endif

    // List devices if requested
    if (ctx->list_devices) {
        int index = 0;
        av_log(ctx, AV_LOG_INFO, "AVFoundation video devices:\n");
        for (AVCaptureDevice *device in devices) {
            const char *name = [[device localizedName] UTF8String];
            index            = [devices indexOfObject:device];
            av_log(ctx, AV_LOG_INFO, "[%d] %s\n", index, name);
            index++;
        }
#if !TARGET_OS_IPHONE && __MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
        if (num_screens > 0) {
            CGDirectDisplayID screens[num_screens];
            CGGetActiveDisplayList(num_screens, screens, &num_screens);
            for (int i = 0; i < num_screens; i++) {
                av_log(ctx, AV_LOG_INFO, "[%d] Capture screen %d\n", index + i, i);
            }
        }
#endif

        av_log(ctx, AV_LOG_INFO, "AVFoundation audio devices:\n");
        devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
        for (AVCaptureDevice *device in devices) {
            const char *name = [[device localizedName] UTF8String];
            int index  = [devices indexOfObject:device];
            av_log(ctx, AV_LOG_INFO, "[%d] %s\n", index, name);
        }
         goto fail;
    }

    av_log(ctx, AV_LOG_INFO, "video_device_index: %d num_video_devices: %d num_screens: %d\n", ctx->video_device_index, ctx->num_video_devices, num_screens);
    // parse input filename for video and audio device
    parse_device_name(s);

    // check for device index given in filename
    if (ctx->video_device_index == -1 && ctx->video_filename) {
        sscanf(ctx->video_filename, "%d", &ctx->video_device_index);
    }
    if (ctx->audio_device_index == -1 && ctx->audio_filename) {
        sscanf(ctx->audio_filename, "%d", &ctx->audio_device_index);
    }

    if (ctx->video_device_index >= 0) {
        if (ctx->video_device_index < ctx->num_video_devices) {
            video_device = [devices objectAtIndex:ctx->video_device_index];
        } else if (ctx->video_device_index < ctx->num_video_devices + num_screens) {
#if !TARGET_OS_IPHONE && __MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
            CGDirectDisplayID screens[num_screens];
            CGGetActiveDisplayList(num_screens, screens, &num_screens);
            AVCaptureScreenInput* capture_screen_input = [[[AVCaptureScreenInput alloc] initWithDisplayID:screens[ctx->video_device_index - ctx->num_video_devices]] autorelease];

            if (ctx->framerate.num > 0) {
                capture_screen_input.minFrameDuration = CMTimeMake(ctx->framerate.den, ctx->framerate.num);
            }

#if !TARGET_OS_IPHONE && __MAC_OS_X_VERSION_MIN_REQUIRED >= 1080
            if (ctx->capture_cursor) {
                capture_screen_input.capturesCursor = YES;
            } else {
                capture_screen_input.capturesCursor = NO;
            }
#endif

            if (ctx->capture_mouse_clicks) {
                capture_screen_input.capturesMouseClicks = YES;
            } else {
                capture_screen_input.capturesMouseClicks = NO;
            }

            video_device = (AVCaptureDevice*) capture_screen_input;
            int screen_idx = ctx->video_device_index - ctx->num_video_devices;
            CGDisplayModeRef mode = CGDisplayCopyDisplayMode(screens[screen_idx]);
            
            float backingScaleFactor = [[NSScreen screens][screen_idx] backingScaleFactor];

            ctx->width  = CGDisplayModeGetWidth(mode)*backingScaleFactor;
            ctx->height = CGDisplayModeGetHeight(mode)*backingScaleFactor;

            capture_screen = 1;
#endif
         } else {
            av_log(ctx, AV_LOG_ERROR, "Invalid device index\n");
            goto fail;
        }
    } else if (ctx->video_filename &&
               strncmp(ctx->video_filename, "none", 4)) {
        if (!strncmp(ctx->video_filename, "default", 7)) {
            video_device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        } else {
        // looking for video inputs
        for (AVCaptureDevice *device in devices) {
            if (!strncmp(ctx->video_filename, [[device localizedName] UTF8String], strlen(ctx->video_filename))) {
                video_device = device;
                break;
            }
        }

#if !TARGET_OS_IPHONE && __MAC_OS_X_VERSION_MIN_REQUIRED >= 1070
        // looking for screen inputs
        if (!video_device) {
            int idx;
            if(sscanf(ctx->video_filename, "Capture screen %d", &idx) && idx < num_screens) {
                CGDirectDisplayID screens[num_screens];
                CGGetActiveDisplayList(num_screens, screens, &num_screens);
                AVCaptureScreenInput* capture_screen_input = [[[AVCaptureScreenInput alloc] initWithDisplayID:screens[idx]] autorelease];
                video_device = (AVCaptureDevice*) capture_screen_input;
                ctx->video_device_index = ctx->num_video_devices + idx;
                capture_screen = 1;

                if (ctx->framerate.num > 0) {
                    capture_screen_input.minFrameDuration = CMTimeMake(ctx->framerate.den, ctx->framerate.num);
                }

#if !TARGET_OS_IPHONE && __MAC_OS_X_VERSION_MIN_REQUIRED >= 1080
                if (ctx->capture_cursor) {
                    capture_screen_input.capturesCursor = YES;
                } else {
                    capture_screen_input.capturesCursor = NO;
                }
#endif

                if (ctx->capture_mouse_clicks) {
                    capture_screen_input.capturesMouseClicks = YES;
                } else {
                    capture_screen_input.capturesMouseClicks = NO;
                }
            }
        }
#endif
        }

        if (!video_device) {
            av_log(ctx, AV_LOG_ERROR, "Video device not found\n");
            goto fail;
        }
    }

    // get audio device
    if (ctx->audio_device_index >= 0) {
        NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];

        if (ctx->audio_device_index >= [devices count]) {
            av_log(ctx, AV_LOG_ERROR, "Invalid audio device index\n");
            goto fail;
        }

        audio_device = [devices objectAtIndex:ctx->audio_device_index];
    } else if (ctx->audio_filename &&
               strncmp(ctx->audio_filename, "none", 4)) {
        if (!strncmp(ctx->audio_filename, "default", 7)) {
            audio_device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        } else {
        NSArray *devices = [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];

        for (AVCaptureDevice *device in devices) {
            if (!strncmp(ctx->audio_filename, [[device localizedName] UTF8String], strlen(ctx->audio_filename))) {
                audio_device = device;
                break;
            }
        }
        }

        if (!audio_device) {
            av_log(ctx, AV_LOG_ERROR, "Audio device not found\n");
             goto fail;
        }
    }

    int idx = 0;
    av_log(ctx, AV_LOG_INFO, "Selecting audio format\n");

    for (AVCaptureDeviceFormat *format in audio_device.formats) {
        
        if (get_audio_codec_id(format) == AV_CODEC_ID_PCM_F32BE || get_audio_codec_id(format) == AV_CODEC_ID_PCM_F32LE) {
            ctx->audio_format       = format;
            //                ctx->audio_format_index = idx;
            av_log(ctx, AV_LOG_INFO, "Selected preferred audio format %d\n", idx);
            
            break;
        }
        idx++;
    }
    idx = -1;
    if (!ctx->audio_format) {
        av_log(ctx, AV_LOG_INFO, "Cannot find preferred audio format finding alternative %d\n", idx);
        idx++;

        bool skipFirst = true;
        for (AVCaptureDeviceFormat *format in audio_device.formats) {
            if (get_audio_codec_id(format) == AV_CODEC_ID_PCM_S16BE || get_audio_codec_id(format) == AV_CODEC_ID_PCM_S16LE) {
                ctx->audio_format       = format;
                //                ctx->audio_format_index = idx;
                av_log(ctx, AV_LOG_INFO, "Selected alternative audio format %d\n", idx);
                
                break;
            }

        }
        
    }

    idx = 0;
    
    if (!ctx->audio_format) {
        av_log(ctx, AV_LOG_INFO, "Cannot find preferred audio format finding alternative 2 %d\n", idx);

        for (AVCaptureDeviceFormat *format in audio_device.formats) {
            if (get_audio_codec_id(format) != AV_CODEC_ID_NONE) {
                av_log(ctx, AV_LOG_INFO, "Selected alternative 2 audio format %d\n", idx);
                ctx->audio_format       = format;
                //                ctx->audio_format_index = idx;
            }
            idx++;

        }
        
    }
    
    if (ctx->audio_format) {
        AudioStreamBasicDescription *audio_format_desc =
        (AudioStreamBasicDescription*)CMAudioFormatDescriptionGetStreamBasicDescription(ctx->audio_format.formatDescription);
        av_log(ctx, AV_LOG_INFO, "Format %d:\n", idx++);
        av_log(ctx, AV_LOG_INFO, "\tsample rate     = %f\n",
               audio_format_desc->mSampleRate);
        av_log(ctx, AV_LOG_INFO, "\tchannels        = %d\n",
               audio_format_desc->mChannelsPerFrame);
        av_log(ctx, AV_LOG_INFO, "\tbits per sample = %d\n",
               audio_format_desc->mBitsPerChannel);
        av_log(ctx, AV_LOG_INFO, "\tfloat           = %d\n",
               (bool)(audio_format_desc->mFormatFlags & kAudioFormatFlagIsFloat));
        av_log(ctx, AV_LOG_INFO, "\tbig endian      = %d\n",
               (bool)(audio_format_desc->mFormatFlags & kAudioFormatFlagIsBigEndian));
        av_log(ctx, AV_LOG_INFO, "\tsigned integer  = %d\n",
               (bool)(audio_format_desc->mFormatFlags & kAudioFormatFlagIsSignedInteger));
        av_log(ctx, AV_LOG_INFO, "\tpacked          = %d\n",
               (bool)(audio_format_desc->mFormatFlags & kAudioFormatFlagIsPacked));
        av_log(ctx, AV_LOG_INFO, "\tnon interleaved = %d\n",
               (bool)(audio_format_desc->mFormatFlags & kAudioFormatFlagIsNonInterleaved));
        av_log(ctx, AV_LOG_INFO, "\tmask value = %d\n",
               audio_format_desc->mFormatFlags);

    }
    
    /*!
     @enum           Standard AudioFormatFlags Values for AudioStreamBasicDescription
     @abstract       These are the standard AudioFormatFlags for use in the mFormatFlags field of the
     AudioStreamBasicDescription structure.
     @discussion     Typically, when an ASBD is being used, the fields describe the complete layout
     of the sample data in the buffers that are represented by this description -
     where typically those buffers are represented by an AudioBuffer that is
     contained in an AudioBufferList.
     
     However, when an ASBD has the kAudioFormatFlagIsNonInterleaved flag, the
     AudioBufferList has a different structure and semantic. In this case, the ASBD
     fields will describe the format of ONE of the AudioBuffers that are contained in
     the list, AND each AudioBuffer in the list is determined to have a single (mono)
     channel of audio data. Then, the ASBD's mChannelsPerFrame will indicate the
     total number of AudioBuffers that are contained within the AudioBufferList -
     where each buffer contains one channel. This is used primarily with the
     AudioUnit (and AudioConverter) representation of this list - and won't be found
     in the AudioHardware usage of this structure.
     @constant       kAudioFormatFlagIsFloat
     Set for floating point, clear for integer.
     @constant       kAudioFormatFlagIsBigEndian
     Set for big endian, clear for little endian.
     @constant       kAudioFormatFlagIsSignedInteger
     Set for signed integer, clear for unsigned integer. This is only valid if
     kAudioFormatFlagIsFloat is clear.
     @constant       kAudioFormatFlagIsPacked
     Set if the sample bits occupy the entire available bits for the channel,
     clear if they are high or low aligned within the channel. Note that even if
     this flag is clear, it is implied that this flag is set if the
     AudioStreamBasicDescription is filled out such that the fields have the
     following relationship:
     ((mBitsPerSample / 8) * mChannelsPerFrame) == mBytesPerFrame
     @constant       kAudioFormatFlagIsAlignedHigh
     Set if the sample bits are placed into the high bits of the channel, clear
     for low bit placement. This is only valid if kAudioFormatFlagIsPacked is
     clear.
     @constant       kAudioFormatFlagIsNonInterleaved
     Set if the samples for each channel are located contiguously and the
     channels are layed out end to end, clear if the samples for each frame are
     layed out contiguously and the frames layed out end to end.
     @constant       kAudioFormatFlagIsNonMixable
     Set to indicate when a format is non-mixable. Note that this flag is only
     used when interacting with the HAL's stream format information. It is not a
     valid flag for any other uses.
     @constant       kAudioFormatFlagsAreAllClear
     Set if all the flags would be clear in order to preserve 0 as the wild card
     value.
     @constant       kLinearPCMFormatFlagIsFloat
     Synonym for kAudioFormatFlagIsFloat.
     @constant       kLinearPCMFormatFlagIsBigEndian
     Synonym for kAudioFormatFlagIsBigEndian.
     @constant       kLinearPCMFormatFlagIsSignedInteger
     Synonym for kAudioFormatFlagIsSignedInteger.
     @constant       kLinearPCMFormatFlagIsPacked
     Synonym for kAudioFormatFlagIsPacked.
     @constant       kLinearPCMFormatFlagIsAlignedHigh
     Synonym for kAudioFormatFlagIsAlignedHigh.
     @constant       kLinearPCMFormatFlagIsNonInterleaved
     Synonym for kAudioFormatFlagIsNonInterleaved.
     @constant       kLinearPCMFormatFlagIsNonMixable
     Synonym for kAudioFormatFlagIsNonMixable.
     @constant       kLinearPCMFormatFlagsAreAllClear
     Synonym for kAudioFormatFlagsAreAllClear.
     @constant       kLinearPCMFormatFlagsSampleFractionShift
     The linear PCM flags contain a 6-bit bitfield indicating that an integer
     format is to be interpreted as fixed point. The value indicates the number
     of bits are used to represent the fractional portion of each sample value.
     This constant indicates the bit position (counting from the right) of the
     bitfield in mFormatFlags.
     @constant       kLinearPCMFormatFlagsSampleFractionMask
     number_fractional_bits = (mFormatFlags &
     kLinearPCMFormatFlagsSampleFractionMask) >>
     kLinearPCMFormatFlagsSampleFractionShift
     @constant       kAppleLosslessFormatFlag_16BitSourceData
     This flag is set for Apple Lossless data that was sourced from 16 bit native
     endian signed integer data.
     @constant       kAppleLosslessFormatFlag_20BitSourceData
     This flag is set for Apple Lossless data that was sourced from 20 bit native
     endian signed integer data aligned high in 24 bits.
     @constant       kAppleLosslessFormatFlag_24BitSourceData
     This flag is set for Apple Lossless data that was sourced from 24 bit native
     endian signed integer data.
     @constant       kAppleLosslessFormatFlag_32BitSourceData
     This flag is set for Apple Lossless data that was sourced from 32 bit native
     endian signed integer data.
     */

    // list all audio formats if requested
    if (ctx->list_audio_formats) {
//        av_log(ctx, AV_LOG_ERROR, "Test\n");
        int idx = 0;
        for (AVCaptureDeviceFormat *format in audio_device.formats) {
            if (get_audio_codec_id(format) != AV_CODEC_ID_NONE) {
                AudioStreamBasicDescription *audio_format_desc =
                (AudioStreamBasicDescription*)CMAudioFormatDescriptionGetStreamBasicDescription(format.formatDescription);
                av_log(ctx, AV_LOG_INFO, "Format %d:\n", idx++);
                av_log(ctx, AV_LOG_INFO, "\tsample rate     = %f\n",
                       audio_format_desc->mSampleRate);
                av_log(ctx, AV_LOG_INFO, "\tchannels        = %d\n",
                       audio_format_desc->mChannelsPerFrame);
                av_log(ctx, AV_LOG_INFO, "\tbits per sample = %d\n",
                       audio_format_desc->mBitsPerChannel);
                av_log(ctx, AV_LOG_INFO, "\tfloat           = %d\n",
                       (bool)(audio_format_desc->mFormatFlags & kAudioFormatFlagIsFloat));
                av_log(ctx, AV_LOG_INFO, "\tbig endian      = %d\n",
                       (bool)(audio_format_desc->mFormatFlags & kAudioFormatFlagIsBigEndian));
                av_log(ctx, AV_LOG_INFO, "\tsigned integer  = %d\n",
                       (bool)(audio_format_desc->mFormatFlags & kAudioFormatFlagIsSignedInteger));
                av_log(ctx, AV_LOG_INFO, "\tpacked          = %d\n",
                       (bool)(audio_format_desc->mFormatFlags & kAudioFormatFlagIsPacked));
                av_log(ctx, AV_LOG_INFO, "\tnon interleaved = %d\n",
                       (bool)(audio_format_desc->mFormatFlags & kAudioFormatFlagIsNonInterleaved));
                av_log(ctx, AV_LOG_INFO, "\tmask value = %d\n",
                       audio_format_desc->mFormatFlags);

            } else {
                av_log(ctx, AV_LOG_INFO, "Format %d: (unsupported)\n", idx++);
            }
            
        }
        
        goto fail;
    }

    
    ctx->started_recording = false;
    ctx->audioNonInterLog = false;
    ctx->audioInterLog = false;
    ctx->dumpBuffer = false;
    ctx->audio_log = 0;
    ctx->video_log = 0;
    ctx->last_video_pkt_time = 0;
    ctx->last_audio_pkt_time = 0;
    ctx->pkt_index = 0;
    ctx->pkt_count = 0;
    ctx->first_packet_time = 0;
    ctx->audioStream = NULL;
    ctx->videoStream = NULL;
    ctx->audio_packet_size = 0;
    ctx->audio_packet_count = 0;
    // Video nor Audio capture device not found, looking for AVMediaTypeVideo/Audio
    if (!video_device && !audio_device) {
        av_log(s, AV_LOG_ERROR, "No AV capture device found\n");
        goto fail;
    }

    if (video_device) {
        if (ctx->video_device_index < ctx->num_video_devices) {
            av_log(s, AV_LOG_INFO, "'%s' opened\n", [[video_device localizedName] UTF8String]);
        } else {
            av_log(s, AV_LOG_INFO, "'%s' opened\n", [[video_device description] UTF8String]);
        }
    }
    if (audio_device) {
        av_log(s, AV_LOG_INFO, "audio device '%s' opened\n", [[audio_device localizedName] UTF8String]);
    }

    // Initialize capture session
    ctx->capture_session = [[AVCaptureSession alloc] init];

    if (video_device && add_video_device(s, video_device)) {
        goto fail;
    }
    if (audio_device && add_audio_device(s, audio_device)) {
    }
    
    av_log(s, AV_LOG_INFO, "read header unlocking audio config\n");
    
    
    

    av_log(s, AV_LOG_INFO, "read header starting capture session\n");

    [ctx->capture_session startRunning];
    av_log(s, AV_LOG_INFO, "read header unlocking video config\n");

    if (audio_device) {
        [audio_device unlockForConfiguration];
        [audio_device lockForConfiguration:nil];
    }
    
    /* Unlock device configuration only after the session is started so it
     * does not reset the capture formats */
    if (!capture_screen) {
        [video_device unlockForConfiguration];
        [video_device lockForConfiguration:nil];
    }
    av_log(s, AV_LOG_INFO, "read header get video config\n");

    
    if (video_device && get_video_config(s)) {
        goto fail;
    }
    av_log(s, AV_LOG_INFO, "read header get audio config\n");

    // set audio stream
    if (audio_device && get_audio_config(s)) {
        goto fail;
    }
    
    av_log(s, AV_LOG_INFO, "read header finshed\n");


    [pool release];
    return 0;

fail:
    [pool release];
    destroy_context(ctx);
    return AVERROR(EIO);
}

static int avf_read_packet(AVFormatContext *s, AVPacket *pkt)
{
    AVFContext* ctx = (AVFContext*)s->priv_data;
//    av_log(s, AV_LOG_DEBUG, "ssssssss");
//    bool gotVideo = false;
//    bool gotAudio = false;
    
    do {
        int got_buffer = 0;
        CMSampleBufferRef asample_buffer  = nil;
        CMSampleBufferRef vsample_buffer =  nil;
        
        unsigned long timestamp = 0;
        
        [ctx->lock lockWhenCondition:QUEUE_HAS_BUFFERS];
        bool shouldProcessVideo = false;
        bool shouldProcessAudio = false;
        
        int audioCount = [ctx->audio_queue count];
        int videoCount = [ctx->video_queue count];
        if (audioCount > videoCount*7) {
            shouldProcessAudio = true;
        } else {
            shouldProcessVideo = true;
        }
        if (shouldProcessVideo) {
            vsample_buffer = (CMSampleBufferRef)[ctx->video_queue lastObject];
        }
        if (vsample_buffer) {
            if (!ctx->started_recording) {
                ctx->started_recording = true;
                av_log(s, AV_LOG_INFO, "started recording audio queuesize: %d", [ctx->audio_queue count]);
//                if ([ctx->audio_queue count] > 0) {
//                    ctx->first_audio_pts = [(NSNumber *)ctx->audio_time_queue[0] unsignedLongValue];
//                    av_log(s, AV_LOG_INFO, "audio packet start time: %ld", ctx->first_audio_pts);
//                } else {
//                    ctx->first_audio_pts = -1234999;
//                    av_log(s, AV_LOG_INFO, "audio queue empty setting pts later");
//                }
                 ctx->first_audio_pts = -2;

                [ctx->audio_queue removeAllObjects];
                [ctx->audio_time_queue removeAllObjects];
            }
            vsample_buffer = (CMSampleBufferRef)CFRetain(vsample_buffer);
            timestamp = [(NSNumber *)[ctx->video_time_queue lastObject] unsignedLongValue];
            
            [ctx->video_time_queue removeLastObject];
            [ctx->video_queue removeLastObject];
//            if (ctx->dumpBuffer) {
            
//            } else {
//                gotVideo = true;
                got_buffer |= 1;
//            }
//            ctx->dumpBuffer = !ctx->dumpBuffer;
            
        } else {
            asample_buffer = (CMSampleBufferRef)[ctx->audio_queue lastObject];
            if (asample_buffer) {
                timestamp = [(NSNumber *)[ctx->audio_time_queue lastObject] unsignedLongValue];
                asample_buffer = (CMSampleBufferRef)CFRetain(asample_buffer);
                if (ctx->first_audio_pts == -2) {
                    ctx->first_audio_pts = timestamp;
                    av_log(s, AV_LOG_INFO, "audio packet first packet time: %ld\n", ctx->first_audio_pts);
                }
                timestamp = timestamp - ctx->first_audio_pts;
                if (timestamp < 0) {
                    av_log(s, AV_LOG_INFO, "audio packet time less then zero: %ld\n", timestamp);
                }
                [ctx->audio_queue removeLastObject];
                [ctx->audio_time_queue removeLastObject];

                if (!ctx->started_recording) {
                    av_log(s, AV_LOG_INFO, "dropped audio packet at beginning\n");
                }
                
//                if (ctx->dumpBuffer) {
                
//                } else {
                    got_buffer |= 1;
//                    gotAudio = true;
//                }
//                ctx->dumpBuffer = !ctx->dumpBuffer;

            }
        }
        
        av_log(s, AV_LOG_DEBUG, "audio queue size: %d video queue size: %d\n", [ctx->audio_queue count], [ctx->video_queue count]);
        
        if (!got_buffer || ([ctx->video_queue count] == 0 && [ctx->audio_queue count] == 0)) {
            [ctx->lock unlockWithCondition:QUEUE_IS_EMPTY];
            av_log(s, AV_LOG_DEBUG, "queue is empty read packet\n");
        } else {
            [ctx->lock unlock];
        }

        // av_log(s, AV_LOG_INFO, "\nNew Code!\n");
        
        if (!ctx->started_recording) {
            continue;
        }


//        if (gotAudio && gotVideo) {
//            av_log(s, AV_LOG_DEBUG, "vsample_buffer asample_buffer both non nil!!!!\n");
//        }
        
        if (vsample_buffer != nil) {
            void *data; // data = CVPixelBufferGetBaseAddress
            CVImageBufferRef image_buffer;

            image_buffer = CMSampleBufferGetImageBuffer(vsample_buffer);
            if (av_new_packet(pkt, (int)CVPixelBufferGetDataSize(image_buffer)) < 0) {
                CVPixelBufferUnlockBaseAddress(image_buffer, 0);
                CFRelease(vsample_buffer);
                return AVERROR(EIO);
            }
            pkt->dts = pkt->pts = timestamp;

            pkt->stream_index  = ctx->video_stream_index;
            pkt->flags        |= AV_PKT_FLAG_KEY;

            // CVPixelBufferLockBaseAddress(image_buffer, 0);
            int status = CVPixelBufferLockBaseAddress(image_buffer, 0);
            if (status != kCVReturnSuccess) {
                av_log(s, AV_LOG_ERROR, "Could not lock base address: %d\n", status);
                return AVERROR_EXTERNAL;
            }
            
            int src_linesize[4];
            const uint8_t *src_data[4];
            int width  = CVPixelBufferGetWidth(image_buffer);
            int height = CVPixelBufferGetHeight(image_buffer);

            if (CVPixelBufferIsPlanar(image_buffer)) {
                /**
                 * Changes from "Support interleaved audio dynamically" commit
                int8_t *dst = pkt->data;
                int count = CVPixelBufferGetPlaneCount(image_buffer);
                for (int i = 0; i < count;i++) {
                    data = CVPixelBufferGetBaseAddressOfPlane(image_buffer, i);
                    size_t data_size = CVPixelBufferGetBytesPerRowOfPlane(image_buffer, i) * CVPixelBufferGetHeightOfPlane(image_buffer, i);
                    memcpy(dst, data, data_size);
                    dst += data_size;
                }
                **/
                size_t plane_count = CVPixelBufferGetPlaneCount(image_buffer);
                for (int i = 0; i < plane_count; i++) {
                    src_linesize[i] = CVPixelBufferGetBytesPerRowOfPlane(image_buffer, i);
                    src_data[i] = CVPixelBufferGetBaseAddressOfPlane(image_buffer, i);
                }
            } else {
                /**
                data = CVPixelBufferGetBaseAddress(image_buffer);
                memcpy(pkt->data, data, pkt->size);
                **/
                src_linesize[0] = CVPixelBufferGetBytesPerRow(image_buffer);
                src_data[0] = CVPixelBufferGetBaseAddress(image_buffer);
            }

            status = av_image_copy_to_buffer(pkt->data, pkt->size, src_data, src_linesize, ctx->pixel_format, width, height, 1);

            CVPixelBufferUnlockBaseAddress(image_buffer, 0);
            CFRelease(vsample_buffer);
            vsample_buffer = NULL;

            if (status < 0)
                return status;
        }

        else if (asample_buffer != nil) {
            ctx->audio_packet_count++;
            CMBlockBufferRef block_buffer = CMSampleBufferGetDataBuffer(asample_buffer);
            int block_buffer_size         = CMBlockBufferGetDataLength(block_buffer);

            if (!block_buffer || !block_buffer_size) {
                CFRelease(asample_buffer);
                return AVERROR(EIO);
            }
            
            CMFormatDescriptionRef format_desc = CMSampleBufferGetFormatDescription(asample_buffer);
            const AudioStreamBasicDescription *audio_format_desc = CMAudioFormatDescriptionGetStreamBasicDescription(format_desc);
            int audio_non_interleaved = audio_format_desc->mFormatFlags & kAudioFormatFlagIsNonInterleaved;
            
            if (audio_non_interleaved && !ctx->audio_buffer) {
                ctx -> audio_buffer = av_malloc(block_buffer_size);
                ctx ->audio_buffer_size = block_buffer_size;
                if (!ctx->audio_buffer) {
                    av_log(ctx, AV_LOG_ERROR, "error allocation audio buffer\n");
                    CFRelease(asample_buffer);
                    return AVERROR(EIO);
                }
            }

            if (audio_non_interleaved && block_buffer_size > ctx->audio_buffer_size) {
                CFRelease(asample_buffer);
                return AVERROR_BUFFER_TOO_SMALL;
            }

            if (av_new_packet(pkt, block_buffer_size) < 0) {
                CFRelease(asample_buffer);
                return AVERROR(EIO);
            }
            pkt->dts = pkt->pts = timestamp;

            pkt->stream_index  = ctx->audio_stream_index;
            pkt->flags        |= AV_PKT_FLAG_KEY;

            if (audio_non_interleaved) {
                int sample, c, shift, num_samples;
                bool shouldDumpAgain = false;
                OSStatus ret = CMBlockBufferCopyDataBytes(block_buffer, 0, pkt->size, ctx->audio_buffer);
                if (ret != kCMBlockBufferNoErr) {
                    CFRelease(asample_buffer);
                    return AVERROR(EIO);
                }
                
                if (!ctx->audioNonInterLog) {
                    ctx->audioNonInterLog = true;
                    av_log(s, AV_LOG_INFO, "audio_non_interleaved recieved, pkt.size %d\n", pkt->size);
                    if (ctx->audioStream) {
                        // av_pkt_dump_log2(NULL, AV_LOG_INFO, pkt, 1, ctx->audioStream);
                        shouldDumpAgain = true;
                    }
                }

                num_samples = pkt->size / (ctx->audio_channels * (ctx->audio_bits_per_sample >> 3));

                // transform decoded frame into output format
                #define INTERLEAVE_OUTPUT(bps)                                         \
                {                                                                      \
                    int##bps##_t **src;                                                \
                    int##bps##_t *dest;                                                \
                    src = av_malloc(ctx->audio_channels * sizeof(int##bps##_t*));      \
                    if (!src) return AVERROR(EIO);                                     \
                    for (c = 0; c < ctx->audio_channels; c++) {                        \
                        src[c] = ((int##bps##_t*)ctx->audio_buffer) + c * num_samples; \
                    }                                                                  \
                    dest  = (int##bps##_t*)pkt->data;                                  \
                    shift = bps - ctx->audio_bits_per_sample;                          \
                    for (sample = 0; sample < num_samples; sample++)                   \
                        for (c = 0; c < ctx->audio_channels; c++)                      \
                            *dest++ = src[c][sample] << shift;                         \
                    av_freep(&src);                                                    \
                }

                if (ctx->audio_bits_per_sample <= 16) {
                    INTERLEAVE_OUTPUT(16)
                } else {
                    INTERLEAVE_OUTPUT(32)
                }
                if (ctx->audio_packet_size != pkt->size) {
                    av_log(s, AV_LOG_INFO, "pkt size changed from %d to %d\n", ctx->audio_packet_size, pkt->size);
                    ctx->audio_packet_size = pkt->size;
                }
                //Test only to simulate an corrupted audio packet
                //if (ctx->audio_packet_count == 2000) {
                //    pkt->size = pkt->size - 2;
                //}
                if (shouldDumpAgain) {
                    //av_pkt_dump_log2(NULL, AV_LOG_INFO, pkt, 1, ctx->audioStream);
                }
            } else {
                OSStatus ret = CMBlockBufferCopyDataBytes(block_buffer, 0, pkt->size, pkt->data);
                if (!ctx->audioInterLog) {
                    ctx->audioInterLog = true;
                    av_log(s, AV_LOG_INFO, "audio_interleaved recieved pkt.size %d\n", pkt->size);
                    if (ctx->audioStream) {
                        //av_pkt_dump_log2(NULL, AV_LOG_INFO, pkt, 1, ctx->audioStream);
                    }
                }
                if (ctx->audio_packet_size != pkt->size) {
                    av_log(s, AV_LOG_INFO, "pkt size changed from %d to %d\n", ctx->audio_packet_size, pkt->size);
                    ctx->audio_packet_size = pkt->size;
                }
                //Test only
                //if (ctx->audio_packet_count == 2000) {
                //    pkt->size = pkt->size - 2;
                //}

                if (ret != kCMBlockBufferNoErr) {
                    return AVERROR(EIO);
                }
            }

            CFRelease(asample_buffer);
            asample_buffer = NULL;
        }
    } while (!pkt->data);

    return 0;
}

static int avf_close(AVFormatContext *s)
{
    AVFContext* ctx = (AVFContext*)s->priv_data;
    destroy_context(ctx);
    return 0;
}

static const AVOption options[] = {
    { "list_devices", "list available devices", offsetof(AVFContext, list_devices), AV_OPT_TYPE_INT, {.i64=0}, 0, 1, AV_OPT_FLAG_DECODING_PARAM, "list_devices" },
    { "true", "", 0, AV_OPT_TYPE_CONST, {.i64=1}, 0, 0, AV_OPT_FLAG_DECODING_PARAM, "list_devices" },
    { "false", "", 0, AV_OPT_TYPE_CONST, {.i64=0}, 0, 0, AV_OPT_FLAG_DECODING_PARAM, "list_devices" },
    { "list_audio_formats", "list available audio formats", offsetof(AVFContext, list_audio_formats), AV_OPT_TYPE_INT, {.i64=0}, 0, 1, AV_OPT_FLAG_DECODING_PARAM, "list_audio_formats" },
    { "true", "", 0, AV_OPT_TYPE_CONST, {.i64=1}, 0, 0, AV_OPT_FLAG_DECODING_PARAM, "list_audio_formats" },
    { "false", "", 0, AV_OPT_TYPE_CONST, {.i64=0}, 0, 0, AV_OPT_FLAG_DECODING_PARAM, "list_audio_formats" },
    { "video_device_index", "select video device by index for devices with same name (starts at 0)", offsetof(AVFContext, video_device_index), AV_OPT_TYPE_INT, {.i64 = -1}, -1, INT_MAX, AV_OPT_FLAG_DECODING_PARAM },
    { "audio_device_index", "select audio device by index for devices with same name (starts at 0)", offsetof(AVFContext, audio_device_index), AV_OPT_TYPE_INT, {.i64 = -1}, -1, INT_MAX, AV_OPT_FLAG_DECODING_PARAM },
    { "pixel_format", "set pixel format", offsetof(AVFContext, pixel_format), AV_OPT_TYPE_PIXEL_FMT, {.i64 = AV_PIX_FMT_YUV420P}, 0, INT_MAX, AV_OPT_FLAG_DECODING_PARAM},
    { "framerate", "set frame rate", offsetof(AVFContext, framerate), AV_OPT_TYPE_VIDEO_RATE, {.str = "ntsc"}, 0, 0, AV_OPT_FLAG_DECODING_PARAM },
    { "framerate_actual", "set frame rate for actual capture", offsetof(AVFContext, framerate_actual), AV_OPT_TYPE_INT, {.i64 = -1}, -1, INT_MAX, AV_OPT_FLAG_DECODING_PARAM },
    { "video_size", "set video size", offsetof(AVFContext, width), AV_OPT_TYPE_IMAGE_SIZE, {.str = NULL}, 0, 0, AV_OPT_FLAG_DECODING_PARAM },
    { "capture_cursor", "capture the screen cursor", offsetof(AVFContext, capture_cursor), AV_OPT_TYPE_INT, {.i64=0}, 0, 1, AV_OPT_FLAG_DECODING_PARAM },
    { "capture_mouse_clicks", "capture the screen mouse clicks", offsetof(AVFContext, capture_mouse_clicks), AV_OPT_TYPE_INT, {.i64=0}, 0, 1, AV_OPT_FLAG_DECODING_PARAM },

    { NULL },
};

static const AVClass avf_class = {
    .class_name = "AVFoundation input device",
    .item_name  = av_default_item_name,
    .option     = options,
    .version    = LIBAVUTIL_VERSION_INT,
    .category   = AV_CLASS_CATEGORY_DEVICE_VIDEO_INPUT,
};

AVInputFormat ff_avfoundation_demuxer = {
    .name           = "avfoundation",
    .long_name      = NULL_IF_CONFIG_SMALL("AVFoundation input device"),
    .priv_data_size = sizeof(AVFContext),
    .read_header    = avf_read_header,
    .read_packet    = avf_read_packet,
    .read_close     = avf_close,
    .flags          = AVFMT_NOFILE,
    .priv_class     = &avf_class,
};
