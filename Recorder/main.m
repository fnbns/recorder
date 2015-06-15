//
//  main.m
//  AwesomeRecorder
//
//  Created by Alexandru Serban on 15/06/15.
//  Copyright (c) 2015 home. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#define kNumberRecordBuffers 3

#pragma mark user data struct
/* recording callback */
typedef struct AwesomeRecorder{
    AudioFileID recordFile;
    SInt64 recordPacket;
    Boolean running;
} AwesomeRecorder;

#pragma mark utility functions

/* error checking */
static void CheckError(OSStatus error, const char *operation)
{
    if(error == noErr) return;
    
    char errorString[20];

    /* check for 4-char-error-codes */
    *(UInt32 *)(errorString +1) = CFSwapInt32HostToBig(error);
    if(isprint(errorString[1]) && isprint(errorString[2]) && isprint(errorString[3]) && isprint(errorString[4]))
    {
        errorString[0] = errorString[5] = '\'';
        errorString[6] = '\0';
    } else
        sprintf(errorString, "%d", (int) error);
    
    fprintf(stderr, "Error: %s (%s)\n", operation, errorString);
    
    exit(1);
}


/* get device sample rate */

OSStatus GetDefaultInputDeviceSampleRate(Float64 *outSampleRate)
{
    OSStatus error;
    AudioDeviceID deviceID = 0;
    
    AudioObjectPropertyAddress propertyAddress;
    UInt32 propertySize;
    propertyAddress.mSelector = kAudioHardwarePropertyDefaultInputDevice;
    propertyAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propertyAddress.mElement = 0;
    propertySize = sizeof(AudioDeviceID);
    error = AudioHardwareServiceGetPropertyData(kAudioObjectSystemObject,
                                                &propertyAddress,
                                                0,
                                                NULL,
                                                &propertySize,
                                                &deviceID);
    
    if(error)
        return error;
    
    propertyAddress.mSelector = kAudioDevicePropertyNominalSampleRate;
    propertyAddress.mScope = kAudioObjectPropertyScopeGlobal;
    propertyAddress.mElement = 0;
    propertySize = sizeof(Float64);
    error = AudioHardwareServiceGetPropertyData(deviceID,
                                                &propertyAddress,
                                                0,
                                                NULL,
                                                &propertySize,
                                                outSampleRate);
    
    return error;
}


/* get magic cookie from a file engoded usually as AAC */

static void CopyEncoderCookieToFile(AudioQueueRef queue, AudioFileID theFile)
{
    OSStatus error;
    UInt32 propertySize;

    error = AudioQueueGetPropertySize(queue,
                                      kAudioConverterCompressionMagicCookie,
                                      &propertySize);
    
    if (error == noErr && propertySize > 0)
    {
        Byte *magicCookie = (Byte *)malloc(propertySize);
        
        CheckError(AudioQueueGetProperty(queue,
                                        kAudioQueueProperty_MagicCookie,
                                        magicCookie,
                                        &propertySize),
                                        "Couldn't get audio queue's magic cookie");
        
        CheckError(AudioFileSetProperty(theFile,
                                        kAudioFilePropertyMagicCookieData,
                                        propertySize,
                                        magicCookie), "Couldn't set audio file's magic cookie");
        free(magicCookie);
    }
}


/* record buffer size computing */

static int ComputeRecordBufferSize(const AudioStreamBasicDescription *format,
                                   AudioQueueRef queue,
                                   float seconds)
{
    int packets, frames, bytes;
    
    /*
     How many frames(one sample for every channel) are in each buffer ?!:)
     here we multiply the sample rate by the buffer dureation. If ASBD already has an mBytesPerFrame value (PCM),
     get the needed byte by multyplying mBytesperFrame with the frame count
     */
    
    frames = (int) ceil(seconds * format->mSampleRate);
    
    if(format->mBytesPerFrame >0){
        bytes = frames * format->mBytesPerPacket;
    } else {
        UInt32 maxPacketSize;
        
        /*
         if not / get the mBytesPerPacket (constant packet size)
         */
        
        if(format->mBytesPerPacket > 0){
            maxPacketSize  = frames * format-> mBytesPerPacket;
        } else {
            UInt32 propertySize = sizeof(maxPacketSize);
            /*
             In the hard case, we get the audio queue property kAudioConverterPropertyMaximumOutputPacketSize, which gives  an upper bound to work with. Either way, there's a maxPacketSize.
             */
            CheckError(AudioQueueGetProperty(queue,
                                             kAudioConverterPropertyMaximumOutputPacketSize,
                                             &maxPacketSize,
                                             &propertySize), "Could not get queue's maximum output packet size");
        }
        
        if(format->mFramesPerPacket >0)
            /* 
             But how many packets are there? The ASBD might provide a mFramesPerPacket value; in that case, we divide the frame count by mFramesPerPacket to get a packet count (packets).
             */
            packets = frames / format-> mFramesPerPacket;
        else
            /* WCS: 1 frame / packet */
            packets = frames;
            
        /* sanity check */
        if(packets ==0)
            packets =1;
        
        bytes = packets * maxPacketSize;
        
    }
    
    return bytes;
}


#pragma mark record callback function

static void AQInputCallback(void *inUserData,
                            AudioQueueRef inQueue,
                            AudioQueueBufferRef inBuffer,
                            const AudioTimeStamp *inStartTime,
                            UInt32 inNumPackets,
                            const AudioStreamPacketDescription *inPacketDesc)
{
    
//    AwesomeRecorder *recorder = (AwesomeRecorder *) inUserData;
    
    AwesomeRecorder *recorder = (AwesomeRecorder *)inUserData;
    
    if (inNumPackets > 0) {
        CheckError(AudioFileWritePackets(recorder->recordFile,
                                         FALSE,
                                         inBuffer->mAudioDataByteSize,
                                         inPacketDesc,
                                         recorder->recordPacket,
                                         &inNumPackets,
                                         inBuffer -> mAudioData), "AudioFileWritepackets failed");
        
        recorder->recordPacket += inNumPackets;
    }
    
    if(recorder->running)
        CheckError(AudioQueueEnqueueBuffer(inQueue,
                                           inBuffer,
                                            0,
                                           NULL),"AudioQueueEnqueueBuffer failed");
    
}


#pragma mark main function

int main(int argc, const char * argv[])
{
    
    AwesomeRecorder recorder = {0};
    AudioStreamBasicDescription recordFormat;
    memset(&recordFormat, 0, sizeof(recordFormat));
    
    recordFormat.mFormatID = kAudioFormatMPEG4AAC;
    recordFormat.mChannelsPerFrame = 2 ;
    
    GetDefaultInputDeviceSampleRate(&recordFormat.mSampleRate);
    
    UInt32 propSize = sizeof(recordFormat);
    CheckError(AudioFormatGetProperty(kAudioFormatProperty_FormatInfo,
                                      0,
                                      NULL,
                                      &propSize,
                                      &recordFormat), "AudioFormatGetProperty failed");
    
    
    AudioQueueRef queue = {0};
    CheckError(AudioQueueNewInput(&recordFormat, AQInputCallback,
                                  &recorder,
                                  NULL,
                                  NULL,
                                  0,
                                  &queue
                                  ), "AudioQueueNewInput failed");

    /* get ASBD from Audio Queue*/
    
    UInt32 size = sizeof(recordFormat);
    CheckError(AudioQueueGetProperty(queue,
                                     kAudioConverterCurrentOutputStreamDescription,
                                     &recordFormat,
                                     &size), "Couldn't get queue's format");
    
    /* prepare file */
    CFURLRef fileUrl = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
                                                     CFSTR("output.caf"),
                                                     kCFURLPOSIXPathStyle,
                                                     false );
    
    CheckError(AudioFileCreateWithURL(fileUrl,
                                      kAudioFileCAFType,
                                      &recordFormat,
                                      kAudioFileFlags_EraseFile,
                                      &recorder.recordFile),
               "AudioFileCreateWithURL failed");

    CFRelease(fileUrl);
    
    /* check for magic cookies */
    CopyEncoderCookieToFile(queue, recorder.recordFile);
    
    /* get buffer size */
    
    int bufferBytesSize = ComputeRecordBufferSize(&recordFormat, queue, 0.5);
    
    int bufferIndex;
    
    for(bufferIndex = 0; bufferIndex < kNumberRecordBuffers; ++bufferIndex)
    {
        AudioQueueBufferRef buffer;
        
        CheckError(AudioQueueAllocateBuffer(queue,
                                            bufferBytesSize,
                                            &buffer), "AudioQueueAllocateBuffer failed");
        

        CheckError(AudioQueueEnqueueBuffer(queue,
                                           buffer,
                                           0,
                                           NULL), "AudioQueueEnqueueBuffer failed");
    }
    
    recorder.running = TRUE;
    
    CheckError(AudioQueueStart(queue,
                               NULL),
               "AudioQueueStart failed");
    
    printf("Recording, press <return> to stop:\n");
    getchar();
    
    printf("Recording done.");
    recorder.running = FALSE;
    
    CheckError(AudioQueueStop(queue, TRUE), "AudioQueueStop failed");
    
    CopyEncoderCookieToFile(queue, recorder.recordFile);
    
    AudioQueueDispose(queue, TRUE);
    AudioFileClose(recorder.recordFile);
    
    return 0;
}
