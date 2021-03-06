//
//  NextLevelSessionExporter.swift
//  NextLevelSessionExporter (http://nextlevel.engineering/)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation
import AVFoundation

// MARK: - types

public let NextLevelSessionExporterErrorDomain = "NextLevelSessionExporterErrorDomain"

public enum NextLevelSessionExporterError: Error, CustomStringConvertible {
    case unknown
    case setupFailure
    
    public var description: String {
        get {
            switch self {
            case .unknown:
                return "Unknown"
            case .setupFailure:
                return "Setup failure"
            }
        }
    }
}

// MARK: - NextLevelSessionExporterDelegate

public protocol NextLevelSessionExporterDelegate: NSObjectProtocol {
    func sessionExporter(_ sessionExporter: NextLevelSessionExporter, didUpdateProgress progress: Float)
    func sessionExporter(_ sessionExporter: NextLevelSessionExporter, didRenderFrame renderFrame: CVPixelBuffer, withPresentationTime presentationTime: CMTime, toRenderBuffer renderBuffer: CVPixelBuffer)
}

// MARK: - NextLevelSessionExporter

private let NextLevelSessionExporterInputQueue = "NextLevelSessionExporterInputQueue"

public class NextLevelSessionExporter: NSObject {
    
    public weak var delegate: NextLevelSessionExporterDelegate?
    
    // config
    
    public var asset: AVAsset?
    public var videoComposition: AVVideoComposition?
    public var audioMix: AVAudioMix?
    
    public var outputURL: URL?
    public var outputFileType: String?
    
    public var timeRange: CMTimeRange
    public var expectsMediaDataInRealTime: Bool
    public var optimizeForNetworkUse: Bool
    
    public var metadata: [AVMetadataItem]?

    public var videoInputConfiguration: [String : Any]?
    
    // AVVideoSettings.h
    public var videoOutputConfiguration: [String : Any]?
    
    // CVPixelBuffer.h
    public var audioOutputConfiguration: [String : Any]?

    // state
    
    public var status: AVAssetExportSessionStatus {
        get {
            if let writer = self._writer {
                switch writer.status {
                case .writing:
                    return .exporting
                case .failed:
                    return .failed
                case .completed:
                    return .completed
                case.cancelled:
                    return .cancelled
                case .unknown:
                    break
                }
            }
            return .unknown
        }
    }
    
    public var progress: Float {
        get {
            return self._progress
        }
    }
    
    // private instance vars
    
    internal var _writer: AVAssetWriter?
    internal var _reader: AVAssetReader?
    internal var _pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    
    internal var _inputQueue: DispatchQueue?
    
    internal var _videoOutput: AVAssetReaderVideoCompositionOutput?
    internal var _audioOutput: AVAssetReaderAudioMixOutput?
    internal var _videoInput: AVAssetWriterInput?
    internal var _audioInput: AVAssetWriterInput?

    internal var _progress: Float
    internal var _completionHandler: (() -> Void)?
    
    internal var _duration: TimeInterval
    internal var _lastSamplePresentationTime: CMTime
    
    // MARK: - object lifecycle
    
    public convenience init(withAsset asset: AVAsset) {
        self.init()
        self.asset = asset
    }
    
    override init() {
        self.timeRange = CMTimeRange(start: kCMTimeZero, end: kCMTimePositiveInfinity)
        self.expectsMediaDataInRealTime = true
        self.optimizeForNetworkUse = false
        self._progress = 0
        self._duration = 0
        self._lastSamplePresentationTime = kCMTimeInvalid
        super.init()
    }
    
    deinit {
        self._writer = nil
        self._reader = nil
        self._pixelBufferAdaptor = nil
        self._inputQueue = nil
        self._videoOutput = nil
        self._audioOutput = nil
        self._videoInput = nil
        self._audioInput = nil
    }
    
    // MARK: - functions
    
    public typealias NextLevelSessionExporterCompletionHandler = (Void) -> Void
    
    public func export(withCompletionHandler completionHandler: @escaping NextLevelSessionExporterCompletionHandler) throws {
        self.cancelExport()
        self._completionHandler = completionHandler
        
        if let outputURL = self.outputURL,
            let outputFileType = self.outputFileType,
            let asset = self.asset {
            
            do {
                self._reader = try AVAssetReader(asset: asset)
            } catch {
                print("NextLevelSessionExporter, could not setup a reader for the provided asset \(asset)")
                return
            }
            
            do {
                self._writer = try AVAssetWriter(outputURL: outputURL, fileType: outputFileType)
            } catch {
                print("NextLevelSessionExporter, could not setup a reader for the provided asset \(asset)")
                return
            }
            
        } else {
            throw NextLevelSessionExporterError.setupFailure
        }
        
        self._reader?.timeRange = self.timeRange
        self._writer?.shouldOptimizeForNetworkUse = self.optimizeForNetworkUse
        
        if let metadata = self.metadata {
            self._writer?.metadata = metadata
        }
        
        if self.timeRange.duration.isValid && CMTIME_IS_POSITIVEINFINITY(self.timeRange.duration) == false {
            self._duration = CMTimeGetSeconds(self.timeRange.duration)
        } else {
            if let asset = self.asset {
                self._duration = CMTimeGetSeconds(asset.duration)
            }
        }
        
        // video output
        
        if let videoTracks = self.asset?.tracks(withMediaType: AVMediaTypeVideo) {
            if videoTracks.count > 0 {
                self._videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: self.videoInputConfiguration)
                self._videoOutput?.alwaysCopiesSampleData = false
                
                if let videoComposition = self.videoComposition {
                    self._videoOutput?.videoComposition = videoComposition
                } else {
                    self._videoOutput?.videoComposition = self.makeVideoComposition()
                }
                
                if let videoOutput = self._videoOutput,
                    let reader = self._reader {
                    if reader.canAdd(videoOutput) {
                        reader.add(videoOutput)
                    }
                }
                
                // video input
                
                self._videoInput = AVAssetWriterInput(mediaType: AVMediaTypeVideo, outputSettings: self.videoOutputConfiguration)
                self._videoInput?.expectsMediaDataInRealTime = self.expectsMediaDataInRealTime
                if let writer = self._writer,
                    let videoInput = self._videoInput {
                    if writer.canAdd(videoInput) {
                        writer.add(videoInput)
                    }
                }
                
                let pixelBufferAttrib: [String : Any] = [ String(kCVPixelBufferPixelFormatTypeKey) : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                          String(kCVPixelBufferWidthKey) : self._videoOutput?.videoComposition?.renderSize.width,
                                          String(kCVPixelBufferHeightKey) : self._videoOutput?.videoComposition?.renderSize.height,
                                          "IOSurfaceOpenGLESTextureCompatibility" : true,
                                          "IOSurfaceOpenGLESFBOCompatibility" : true]
                if let videoInput = self._videoInput {
                    self._pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: pixelBufferAttrib)
                }
            }
        }
        
        // audio output
        
        if let audioTracks = self.asset?.tracks(withMediaType: AVMediaTypeAudio) {
            if audioTracks.count > 0 {
                self._audioOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: nil)
                self._audioOutput?.alwaysCopiesSampleData = false
                self._audioOutput?.audioMix = self.audioMix
                if let reader = self._reader,
                    let audioOutput = self._audioOutput {
                    if reader.canAdd(audioOutput) {
                        reader.add(audioOutput)
                    }
                }
            } else {
                self._audioOutput = nil
            }
        }
        
        // audio input
        
        if let _ = self._audioOutput {
            self._audioInput = AVAssetWriterInput(mediaType: AVMediaTypeAudio, outputSettings: self.audioOutputConfiguration)
            self._audioInput?.expectsMediaDataInRealTime = self.expectsMediaDataInRealTime
            if let writer = self._writer,
                let audioInput = self._audioInput {
                if writer.canAdd(audioInput) {
                    writer.add(audioInput)
                }
            }
        }
        
        // export
        
        self._writer?.startWriting()
        self._reader?.startReading()
        self._writer?.startSession(atSourceTime: self.timeRange.start)
        
        let audioSem = DispatchSemaphore(value: 0)
        let videoSem = DispatchSemaphore(value: 0)
        
        self._inputQueue = DispatchQueue(label: NextLevelSessionExporterInputQueue)
        if let inputQueue = self._inputQueue {
            if let videoTracks = self.asset?.tracks(withMediaType: AVMediaTypeVideo),
                let videoInput = self._videoInput,
                let videoOutput = self._videoOutput {
                if videoTracks.count > 0 {
                    videoInput.requestMediaDataWhenReady(on: inputQueue, using: {
                        if self.encode(readySamplesFromReaderOutput: videoOutput, toWriterInput: videoInput) == false {
                            videoSem.signal()
                        }
                    })
                } else {
                    videoSem.signal()
                }
            } else {
                videoSem.signal()
            }
            
            if let audioInput = self._audioInput,
                let audioOutput = self._audioOutput {
                audioInput.requestMediaDataWhenReady(on: inputQueue, using: {
                    if self.encode(readySamplesFromReaderOutput: audioOutput, toWriterInput: audioInput) == false {
                        audioSem.signal()
                    }
                })
            } else {
                audioSem.signal()
            }

            DispatchQueue.global().async {
                audioSem.wait()
                videoSem.wait()
                DispatchQueue.main.async {
                    self.finish()
                }
            }
        }
    }
    
    private func encode(readySamplesFromReaderOutput output: AVAssetReaderOutput, toWriterInput input: AVAssetWriterInput) -> Bool {
        while input.isReadyForMoreMediaData {
            if let sampleBuffer = output.copyNextSampleBuffer() {
                
                var handled = false
                var error = false
                
                if self._reader?.status != .reading || self._writer?.status != .writing {
                    handled = true
                    error = true
                }
                
                if handled == false && self._videoOutput == output {
                    self._lastSamplePresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    self._lastSamplePresentationTime = self._lastSamplePresentationTime - self.timeRange.start
                    self._progress = self._duration == 0 ? 1 : Float(CMTimeGetSeconds(self._lastSamplePresentationTime) / self._duration)
                    
                    if let pixelBufferAdaptor = self._pixelBufferAdaptor,
                        let pixelBufferPool = pixelBufferAdaptor.pixelBufferPool,
                        let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                        var renderBuffer: CVPixelBuffer? = nil
                        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &renderBuffer)
                        if let buffer = renderBuffer {
                            self.delegate?.sessionExporter(self, didRenderFrame: pixelBuffer, withPresentationTime: self._lastSamplePresentationTime, toRenderBuffer: buffer)
                            if pixelBufferAdaptor.append(buffer, withPresentationTime:self._lastSamplePresentationTime) == false {
                                error = true
                            }
                            handled = true
                        }
                    }
                }
                
                if handled == false && input.append(sampleBuffer) == false {
                    error = true
                }
                
                if error {
                    return false
                }
                
            } else {
                input.markAsFinished()
                return false
            }
        }
        return true
    }
    
    private func makeVideoComposition() -> AVMutableVideoComposition {
        let videoComposition = AVMutableVideoComposition()
        
        if let asset = self.asset,
            let videoTrack = asset.tracks(withMediaType: AVMediaTypeVideo).first {
            
            // determine the framerate
            
            var frameRate: Int32 = 0
            if let videoConfiguration = self.videoOutputConfiguration {
                if let videoCompressionConfiguration = videoConfiguration[AVVideoCompressionPropertiesKey] as? [String: Any] {
                    if let maxKeyFrameInterval = videoCompressionConfiguration[AVVideoMaxKeyFrameIntervalKey] as? Int32 {
                        frameRate = maxKeyFrameInterval
                    }
                }
            } else {
                frameRate = Int32(videoTrack.nominalFrameRate)
            }
            
            if frameRate == 0 {
                frameRate = 30
            }
            videoComposition.frameDuration = CMTimeMake(1, frameRate)
            
            // determine the appropriate size and transform
            
            if let videoConfiguration = self.videoOutputConfiguration {
                if let width = videoConfiguration[AVVideoWidthKey] as? CGFloat,
                    let height = videoConfiguration[AVVideoHeightKey] as? CGFloat {
                    
                    let transform = videoTrack.preferredTransform
                    
                    let targetSize = CGSize(width: width, height: height)
                    var naturalSize = videoTrack.naturalSize
                    
                    let videoAngleInDegrees = atan2(transform.b, transform.a) * 180 / CGFloat(M_PI)
                    if videoAngleInDegrees == 90 || videoAngleInDegrees == -90 {
                        let width = naturalSize.width
                        naturalSize.width = naturalSize.height
                        naturalSize.height = width
                    }
                    videoComposition.renderSize = naturalSize
                    
                    // center the video
                    
                    var ratio: CGFloat = 0
                    let xRatio: CGFloat = targetSize.width / naturalSize.width
                    let yRatio: CGFloat = targetSize.height / naturalSize.height
                    ratio = min(xRatio, yRatio)
                    
                    let postWidth = naturalSize.width * ratio
                    let postHeight = naturalSize.height * ratio
                    let transX = (targetSize.width - postWidth) * 0.5
                    let transY = (targetSize.height - postHeight) * 0.5
                    
                    let matrix = CGAffineTransform(translationX: (transX / xRatio), y: (transY / yRatio))
                    matrix.scaledBy(x: (ratio / xRatio), y: (ratio / yRatio))
                    transform.concatenating(matrix)
                    
                    // make the composition
                    
                    let compositionInstruction = AVMutableVideoCompositionInstruction()
                    compositionInstruction.timeRange = CMTimeRange(start: kCMTimeZero, duration: asset.duration)
                    
                    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
                    
                    layerInstruction.setTransform(transform, at: kCMTimeZero)
                    
                    compositionInstruction.layerInstructions = [layerInstruction]
                    videoComposition.instructions = [compositionInstruction]
                }
            }
        }
        
        return videoComposition
    }
    
    public func cancelExport() {
        if let inputQueue = self._inputQueue {
            inputQueue.async {
                if self._writer?.status == .writing {
                    self._writer?.cancelWriting()
                }
                
                if self._reader?.status == .reading {
                    self._reader?.cancelReading()
                }
                
                self.complete()
                self.reset()
            }
        }
    }
    
    private func updateProgress(progress: Float) {
        self.willChangeValue(forKey: "progress")
        self._progress = progress
        self.didChangeValue(forKey: "progress")
        self.delegate?.sessionExporter(self, didUpdateProgress: progress)
    }
    
    private func finish() {
        if let reader = self._reader, let writer = self._writer {
            if reader.status == .cancelled ||
                writer.status == .cancelled {
                return
            }
        
            if writer.status == .failed {
                self.complete()
            } else if reader.status == .failed {
                writer.cancelWriting()
                self.complete()
            } else {
                writer.finishWriting {
                    self.complete()
                }
            }
        }
    }
    
    private func complete() {
        if let writer = self._writer {
            if writer.status == .failed || writer.status == .cancelled {
                if let outputURL = self.outputURL {
                    do {
                        try FileManager.default.removeItem(at: outputURL)
                    } catch  {
                        print("NextLevelSessionExporter, failed to delete file at \(outputURL)")
                    }
                }
            }
        }
        
        if let completionHandler = self._completionHandler {
            completionHandler()
            self._completionHandler = nil
        }
    }
    
    private func reset() {
        self._progress = 0
        self._writer = nil
        self._reader = nil
        self._pixelBufferAdaptor = nil
        
        self._inputQueue = nil
        
        self._videoOutput = nil
        self._audioOutput = nil
        self._videoInput = nil
        self._audioInput = nil

        self._completionHandler = nil
    }
    
}
