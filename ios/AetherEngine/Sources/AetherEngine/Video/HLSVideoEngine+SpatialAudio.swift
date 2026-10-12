import Foundation
import AetherLibavformat
import AetherLibavcodec
import AetherLibavutil

extension HLSVideoEngine {

    /// The bed a source should be rendered into, or nil to keep the ordinary bridge.
    ///
    /// TrueHD only, and only when FFmpeg marked the stream Atmos (`AV_PROFILE_TRUEHD_ATMOS`, which
    /// mlpdec sets from the major sync while the probe decodes a frame): a TrueHD track without an
    /// object presentation gains nothing from rendering and would lose its lossless 7.1 for it.
    /// 48 kHz, or not yet known, since TrueHD reports its rate from the first frame and Atmos is
    /// only ever authored at 48 kHz.
    static func spatialRenderingLayout(
        rendering: ObjectAudioRendering,
        codecID: AVCodecID,
        profile: Int32,
        sampleRate: Int32
    ) -> SpatialSpeakerLayout? {
        guard let layout = rendering.layout,
              codecID == AV_CODEC_ID_TRUEHD,
              profile == AV_PROFILE_TRUEHD_ATMOS,
              sampleRate == 0 || sampleRate == Int32(ObjectAudioRendering.sampleRate)
        else { return nil }
        return layout
    }

    /// Build the producer on a `SpatialAudioBridge` when the host asked for object rendering and the
    /// source qualifies. Nil means "not this route": ineligible, unsupported OS, or a bridge/header
    /// failure, each logged, and the caller carries on with the ordinary bridge cascade, so asking
    /// for Atmos never costs a session its audio.
    func buildSpatialAudioProducerIfEligible(
        audioStream: UnsafeMutablePointer<AVStream>,
        sourceAudioStreamIndex: Int32,
        sourceCodecLabel: String,
        audioHLSCodecs: inout String?,
        audioLanguage: String?
    ) -> HLSSegmentProducer? {
        let par = audioStream.pointee.codecpar.pointee
        guard let layout = Self.spatialRenderingLayout(
            rendering: objectAudioRendering, codecID: par.codec_id,
            profile: par.profile, sampleRate: par.sample_rate)
        else {
            if par.codec_id == AV_CODEC_ID_TRUEHD {
                if objectAudioRendering != .off {
                    EngineLog.emit(
                        "[HLSVideoEngine] object rendering requested but TrueHD is not 48 kHz Atmos "
                        + "(profile=\(par.profile) rate=\(par.sample_rate)); keeping the channel bridge",
                        category: .session
                    )
                } else if par.profile == AV_PROFILE_TRUEHD_ATMOS {
                    // The host's choice, not a failure, but the one a missing-heights report turns on:
                    // the channel bridge plays the 7.1 presentation, where the objects are mixed into
                    // the floor channels.
                    EngineLog.emit(
                        "[HLSVideoEngine] TrueHD Atmos with objectAudioRendering off; the channel bridge "
                        + "carries the 7.1 presentation, with the objects mixed into the floor channels",
                        category: .session
                    )
                }
            }
            return nil
        }
        // VOD only: the live reopen and splice paths re-time the bridge in ways this one's encoder
        // latency and fixed packet stamping do not follow.
        guard !isLiveSession else {
            EngineLog.emit(
                "[HLSVideoEngine] TrueHD Atmos rendering is VOD only; keeping the channel bridge on this live session",
                category: .session
            )
            return nil
        }
        guard #available(macOS 26.0, iOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
            EngineLog.emit(
                "[HLSVideoEngine] TrueHD Atmos rendering needs OS 26 (APAC encoder API); keeping the channel bridge",
                category: .session
            )
            return nil
        }

        // vendored 变更：TrueHDObjectAudioDecoder 已随 LibTrueHD（iOS 18 门槛）移除，
        // TrueHD Atmos 对象音频渲染不可用，直接走通道桥（普通 FFmpeg 解码）降级路径
        EngineLog.emit(
            "[HLSVideoEngine] TrueHD Atmos object rendering unavailable (vendored without LibTrueHD); keeping the channel bridge",
            category: .session
        )
        return nil
    }
}
