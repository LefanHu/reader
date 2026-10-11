import AVFoundation
import Darwin
import Flutter
import NaturalLanguage
import UIKit

/// Engine-owned file synthesis. Generation callbacks are metadata, never playback
/// events; the existing file player alone owns the app's audio session.
final class ReaderNarrationPlugin: NSObject, FlutterPlugin, AVSpeechSynthesizerDelegate {
  private let channel: FlutterMethodChannel
  private let io = DispatchQueue(label: "reader.narration.files", qos: .utility)
  private let tokenizerQueue = DispatchQueue(label: "reader.narration.sentences", qos: .utility)
  // The OS supplies this trust anchor. A device sandbox can deny metadata for
  // its system-owned ancestors even while this directory is fully accessible.
  private let sandboxRoot = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    .resolvingSymlinksInPath()
  private var synthesizer: AVSpeechSynthesizer? = AVSpeechSynthesizer()
  private var root: URL?
  private var pending: [Job] = []
  private var active: Job?
  private var detached = false
  private let maxBytes: Int64 = 32 * 1024 * 1024

  private final class Job {
    let id: String
    let generation: Int
    let text: String
    let voice: AVSpeechSynthesisVoice
    let path: URL
    let reply: FlutterResult
    let utterance: AVSpeechUtterance
    let lock = NSLock()
    private var cancelled = false
    var settled = false // Main-thread only.
    var timeout: DispatchWorkItem?
    // Everything below is confined to the file queue.
    var file: AVAudioFile?
    var inode: ino_t?
    var device: dev_t?
    var frames: Int64 = 0
    var bufferCount = 0
    var maxBufferFrames: AVAudioFrameCount = 0
    var rate: Double = 0
    var bytesPerFrame = 0
    var channels: AVAudioChannelCount = 0
    var format: AVAudioCommonFormat = .otherFormat
    var interleaved = false
    var ended = false
    var didFinish = false
    var markers: [[String: Any]] = []
    var markersUsable = true
    var finished = false

    init(id: String, generation: Int, text: String, voice: AVSpeechSynthesisVoice,
         path: URL, reply: @escaping FlutterResult) {
      self.id = id; self.generation = generation; self.text = text
      self.voice = voice; self.path = path; self.reply = reply
      utterance = AVSpeechUtterance(string: text)
      utterance.voice = voice
      utterance.rate = AVSpeechUtteranceDefaultSpeechRate
      utterance.preUtteranceDelay = 0
      utterance.postUtteranceDelay = 0
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  }

  private init(registrar: FlutterPluginRegistrar) {
    channel = FlutterMethodChannel(name: "reader/narration", binaryMessenger: registrar.messenger())
    super.init()
    synthesizer?.delegate = self
    synthesizer?.usesApplicationAudioSession = true
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = ReaderNarrationPlugin(registrar: registrar)
    registrar.publish(plugin)
    registrar.addMethodCallDelegate(plugin, channel: plugin.channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard !detached else { result(error("unavailable", "The Flutter engine detached.")); return }
    switch call.method {
    case "initialize": bindRoot(call.arguments, result: result)
    case "voices": voices(result)
    case "sentenceRanges": sentences(call.arguments, result: result)
    case "synthesize": enqueue(call.arguments, result: result)
    case "cancelGeneration":
      guard let args = call.arguments as? [String: Any], let generation = args["generation"] as? Int else {
        result(error("arguments", "Missing synthesis generation.")); return
      }
      cancel(generation: generation, result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    detached = true
    channel.setMethodCallHandler(nil)
    cancel(generation: nil, result: nil)
    synthesizer?.delegate = nil
    synthesizer = nil
  }

  private func error(_ code: String, _ message: String) -> FlutterError {
    FlutterError(code: "narration_\(code)", message: message, details: nil)
  }

  /// Roots may rebind only after idle cleanup (isolated native test fixtures).
  /// External paths and symlinks are never trusted.
  private func bindRoot(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any], let path = args["root"] as? String,
      path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
      result(error("path", "Invalid private narration root.")); return
    }
    let candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let canonical = candidate.resolvingSymlinksInPath()
    // iOS's system-owned /var alias is not an app-controlled storage link.
    let systemAlias = candidate.path.hasPrefix("/var/") && canonical.path == "/private" + candidate.path
    guard unaliased(canonical.path).hasPrefix(unaliased(sandboxRoot.path) + "/"),
      candidate.path == canonical.path || systemAlias,
      safeDirectories(canonical), root == nil || root == canonical || (active == nil && pending.isEmpty) else {
      result(error("path", "Narration storage must be an owned sandbox directory.")); return
    }
    root = canonical
    result(nil)
  }

  private func ordinaryVoices() -> [AVSpeechSynthesisVoice] {
    AVSpeechSynthesisVoice.speechVoices().filter { voice in
      if #available(iOS 17.0, *), voice.voiceTraits.contains(.isPersonalVoice) { return false }
      return true
    }
  }

  private func voices(_ result: FlutterResult) {
    let installed = ordinaryVoices()
    let language = Locale.preferredLanguages.first ?? Locale.current.identifier
    let preferred = AVSpeechSynthesisVoice(language: language)
    let requestedLanguage = Locale(identifier: language).languageCode
    let defaultID = installed.first(where: {
      $0.identifier == preferred?.identifier &&
        Locale(identifier: $0.language).languageCode == requestedLanguage
    })?.identifier
    result([
      "voices": installed.map { voice -> [String: Any] in
        let quality: String
        if #available(iOS 16.0, *), voice.quality == .premium { quality = "premium" }
        else if voice.quality == .enhanced { quality = "enhanced" }
        else { quality = "standard" }
        return ["identifier": voice.identifier, "name": voice.name,
                "language": voice.language, "quality": quality]
      },
      "defaultIdentifier": defaultID as Any? ?? NSNull(),
      "synthesisFingerprint": "apple-avspeech:\(ProcessInfo.processInfo.operatingSystemVersionString)",
    ])
  }

  private func sentences(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any], let blocks = args["blocks"] as? [[String: Any]],
      blocks.allSatisfy({ $0["id"] is String && $0["text"] is String }) else {
      result(error("arguments", "Sentence tokenization needs normalized blocks.")); return
    }
    let language = args["language"] as? String
    tokenizerQueue.async {
      var ranges: [String: [[String: Int]]] = [:]
      for block in blocks {
        let text = block["text"] as! String
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        if let language = language, !language.isEmpty { tokenizer.setLanguage(NLLanguage(rawValue: language)) }
        var pairs: [[String: Int]] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
          let native = NSRange(range, in: text)
          pairs.append(["start": native.location, "end": NSMaxRange(native)])
          return true
        }
        ranges[block["id"] as! String] = pairs
      }
      DispatchQueue.main.async {
        if self.detached { result(self.error("cancelled", "The Flutter engine detached.")) }
        else { result(ranges) }
      }
    }
  }

  private func enqueue(_ arguments: Any?, result: @escaping FlutterResult) {
    guard let args = arguments as? [String: Any], let id = args["requestId"] as? String,
      !id.isEmpty, id.count <= 128, let generation = args["generation"] as? Int,
      let text = args["text"] as? String, let voiceID = args["voice"] as? String,
      let path = args["stagingPath"] as? String else {
      result(error("arguments", "The speech request is malformed.")); return
    }
    // Each rejection names its cause so a failure is diagnosable from the app.
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 3000 else {
      result(error("text", "The speech clip is empty or longer than 3,000 characters.")); return
    }
    guard let voice = ordinaryVoices().first(where: { $0.identifier == voiceID }) else {
      result(error("voice", "The selected voice is not installed on this device.")); return
    }
    guard let target = ownedTarget(path) else {
      result(error("path", "The speech clip's storage location is not an owned narration file.")); return
    }
    guard pending.count + (active == nil ? 0 : 1) < 3,
      active?.id != id, !pending.contains(where: { $0.id == id }) else {
      result(error("busy", "The bounded synthesis queue is full.")); return
    }
    let job = Job(id: id, generation: generation, text: text, voice: voice, path: target, reply: result)
    pending.append(job)
    startNext()
  }

  /// The store supplies a content-addressed WAV staging name; native code never
  /// derives a filename from book text or creates a missing book directory.
  private func ownedTarget(_ path: String) -> URL? {
    guard let root = root, !path.split(separator: "/").contains("..") else { return nil }
    let target = URL(fileURLWithPath: unaliased(URL(fileURLWithPath: path).standardizedFileURL.path))
    let prefix = unaliased(root.path) + "/books/"
    guard target.path.hasPrefix(prefix) else { return nil }
    let parts = target.path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 3, isHash(String(parts[0])), parts[1] == "narration",
      String(parts[2]).hasSuffix(".wav.tmp"), isHash(String(parts[2].dropLast(8))),
      safeDirectories(target.deletingLastPathComponent()) else { return nil }
    var info = stat()
    guard lstat(target.path, &info) != 0, errno == ENOENT else { return nil }
    return target
  }

  /// iOS reaches app containers as both `/var/...` and `/private/var/...`;
  /// Foundation and Dart canonicalize differently, so compare one spelling.
  private func unaliased(_ path: String) -> String {
    path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
  }

  private func isHash(_ value: String) -> Bool {
    value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  /// Inspect every app-controlled component, never ancestors outside the sandbox.
  private func safeDirectories(_ directory: URL) -> Bool {
    var path = unaliased(sandboxRoot.path)
    let directoryPath = unaliased(directory.path)
    guard directoryPath == path || directoryPath.hasPrefix(path + "/") else { return false }
    var homeInfo = stat()
    guard lstat(path, &homeInfo) == 0, (homeInfo.st_mode & S_IFMT) == S_IFDIR else { return false }
    for part in directoryPath.dropFirst(path.count).split(separator: "/") {
      path += "/" + part
      var info = stat()
      guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
    }
    return true
  }

  private func startNext() {
    guard !detached, active == nil, !pending.isEmpty, let synth = synthesizer else { return }
    let job = pending.removeFirst()
    active = job
    let timeout = DispatchWorkItem { [weak self, weak job] in
      guard let self = self, let job = job, self.active === job, !job.settled else { return }
      job.cancel()
      self.synthesizer?.stopSpeaking(at: .immediate)
      self.io.async { self.fail(job, self.error("timeout", "Device speech exceeded 30 seconds.")) }
    }
    job.timeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    let buffer: AVSpeechSynthesizer.BufferCallback = { [weak self, job] value in
      guard let self = self else { return }
      self.io.async { self.write(value, job: job) }
    }
    if #available(iOS 16.0, *) {
      synth.write(job.utterance, toBufferCallback: buffer, toMarkerCallback: { [weak self, job] markers in
        guard let self = self else { return }
        let values: [[String: Any]] = markers.compactMap { marker in
          let kind: String
          switch marker.mark {
          case .word: kind = "word"
          case .sentence: kind = "sentence"
          default: return nil
          }
          return ["kind": kind, "utf16Start": marker.textRange.location,
                  "utf16End": NSMaxRange(marker.textRange), "byteOffset": marker.byteSampleOffset]
        }
        self.io.async {
          guard !job.isCancelled, !job.finished, job.markersUsable else { return }
          if values.count + job.markers.count > 2 * job.text.utf16.count + 2 {
            job.markers.removeAll(); job.markersUsable = false
          } else { job.markers.append(contentsOf: values) }
        }
      })
    } else { synth.write(job.utterance, toBufferCallback: buffer) }
  }

  private func write(_ value: AVAudioBuffer, job: Job) {
    guard !job.isCancelled, !job.finished else { return }
    guard let pcm = value as? AVAudioPCMBuffer else { fail(job, error("format", "Unexpected synthesis buffer.")); return }
    if pcm.frameLength == 0 {
      job.ended = true
      completeIfReady(job)
      return
    }
    let format = pcm.format
    let layout = format.streamDescription.pointee
    guard format.sampleRate.isFinite, format.sampleRate >= 8000, format.sampleRate <= 192000,
      (1...2).contains(format.channelCount), layout.mFormatID == kAudioFormatLinearPCM,
      format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatInt16,
      layout.mBytesPerFrame > 0 else { fail(job, error("format", "Unsupported synthesis PCM layout.")); return }
    do {
      if job.file == nil {
        guard safeDirectories(job.path.deletingLastPathComponent()) else { throw CocoaError(.fileWriteNoPermission) }
        let fd = open(job.path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CocoaError(.fileWriteFileExists) }
        var info = stat()
        let status = fstat(fd, &info)
        close(fd)
        guard status == 0 else { throw CocoaError(.fileWriteUnknown) }
        job.inode = info.st_ino; job.device = info.st_dev
        job.rate = format.sampleRate; job.bytesPerFrame = Int(layout.mBytesPerFrame)
        job.channels = format.channelCount; job.format = format.commonFormat; job.interleaved = format.isInterleaved
        job.file = try AVAudioFile(forWriting: job.path, settings: [
          // Staging ends in .tmp: select WAVE explicitly, not by extension.
          AVAudioFileTypeKey: kAudioFileWAVEType,
          AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
          AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 16,
          AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
          AVLinearPCMIsNonInterleaved: false,
        ], commonFormat: format.commonFormat, interleaved: format.isInterleaved)
      }
      guard job.rate == format.sampleRate, job.bytesPerFrame == Int(layout.mBytesPerFrame),
        job.channels == format.channelCount, job.format == format.commonFormat,
        job.interleaved == format.isInterleaved,
        (job.frames + Int64(pcm.frameLength)) * Int64(job.channels) * 2 + 4096 <= maxBytes else {
        throw CocoaError(.fileWriteInvalidFileName)
      }
      try job.file?.write(from: pcm)
      job.frames += Int64(pcm.frameLength)
      job.bufferCount += 1
      job.maxBufferFrames = max(job.maxBufferFrames, pcm.frameLength)
    } catch { fail(job, self.error("write", "Device speech could not write bounded PCM audio: \(error.localizedDescription)")) }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    guard let job = active, job.utterance === utterance else { return }
    io.async { job.didFinish = true; self.completeIfReady(job) }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    guard let job = active, job.utterance === utterance, !job.isCancelled else { return }
    job.cancel()
    io.async { self.fail(job, self.error("cancelled", "Device speech was cancelled.")) }
  }

  private func completeIfReady(_ job: Job) {
    guard job.ended, job.didFinish, !job.finished, !job.isCancelled else { return }
    job.file = nil // Close/finalize the WAV before returning its staging asset.
    guard job.frames > 0, job.rate > 0, ownsFile(job) else {
      fail(job, error("empty", "Device speech produced no playable audio.")); return
    }
    let fd = open(job.path.path, O_RDONLY | O_NOFOLLOW)
    guard fd >= 0 else { fail(job, error("write", "The synthesis file disappeared.")); return }
    var finalized = stat()
    guard fstat(fd, &finalized) == 0, finalized.st_ino == job.inode,
      finalized.st_dev == job.device, finalized.st_size <= maxBytes else {
      close(fd)
      fail(job, error("format", "Device speech produced invalid or oversized audio.")); return
    }
    let flushed = fsync(fd)
    close(fd)
    guard flushed == 0 else { fail(job, error("write", "Device speech could not finalize audio.")); return }
    job.finished = true
    // Standalone native probe: iOS 27 build 24A434, ordinary Samantha, mono
    // Float32/22050Hz, 276 buffers. Offsets stayed utterance-relative/aligned.
    // Unprobed voices, OS builds, and layouts remain sentence-only.
    let verified = job.voice.identifier == "com.apple.voice.super-compact.en-US.Samantha" &&
      ProcessInfo.processInfo.operatingSystemVersionString == "Version 27.0 (Build 24A434)" &&
      job.rate == 22050 && job.channels == 1 && job.format == .pcmFormatFloat32 &&
      job.bytesPerFrame == 4 && !job.interleaved
    let metadata: [String: Any] = [
      "sampleRate": job.rate, "sourceBytesPerFrame": job.bytesPerFrame,
      "sourceChannels": job.channels, "sourceFormat": job.format.rawValue,
      "sourceInterleaved": job.interleaved, "frameCount": job.frames,
      "markers": job.markersUsable ? job.markers : [], "offsetOrigin": verified ? "utterance" : "unverified",
      "bufferCount": job.bufferCount, "maxBufferFrames": job.maxBufferFrames,
    ]
    settle(job, value: metadata)
  }

  private func ownsFile(_ job: Job) -> Bool {
    var info = stat()
    return lstat(job.path.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG &&
      info.st_ino == job.inode && info.st_dev == job.device
  }

  private func fail(_ job: Job, _ reason: FlutterError) {
    guard !job.finished else { return }
    job.finished = true
    job.cancel()
    job.file = nil
    if ownsFile(job) { try? FileManager.default.removeItem(at: job.path) }
    settle(job, value: reason)
  }

  private func settle(_ job: Job, value: Any) {
    DispatchQueue.main.async {
      guard !job.settled else { return }
      if job.isCancelled, !(value is FlutterError) {
        self.io.async {
          if self.ownsFile(job) { try? FileManager.default.removeItem(at: job.path) }
          self.settle(job, value: self.error("cancelled", "Device speech was cancelled."))
        }
        return
      }
      job.settled = true
      job.timeout?.cancel()
      if self.active === job {
        if value is FlutterError { self.synthesizer?.stopSpeaking(at: .immediate) }
        self.active = nil
      }
      job.reply(value)
      self.startNext()
    }
  }

  /// Cancellation is outside the store queue and settles only after owned writes
  /// are closed, so pause/deletion cannot deadlock behind a synthesis writer.
  private func cancel(generation: Int?, result: FlutterResult?) {
    let queued = pending.filter { generation == nil || $0.generation == generation }
    pending.removeAll { generation == nil || $0.generation == generation }
    let running = active.flatMap { generation == nil || $0.generation == generation ? $0 : nil }
    for job in queued { job.cancel() }
    running?.cancel()
    if running != nil { synthesizer?.stopSpeaking(at: .immediate) }
    io.async {
      for job in queued { self.fail(job, self.error("cancelled", "Device speech was cancelled.")) }
      if let running = running { self.fail(running, self.error("cancelled", "Device speech was cancelled.")) }
      DispatchQueue.main.async { result?(nil) }
    }
  }
}
