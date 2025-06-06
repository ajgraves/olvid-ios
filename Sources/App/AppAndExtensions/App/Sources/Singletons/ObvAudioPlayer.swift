/*
 *  Olvid for iOS
 *  Copyright © 2019-2022 Olvid SAS
 *
 *  This file is part of Olvid for iOS.
 *
 *  Olvid is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU Affero General Public License, version 3,
 *  as published by the Free Software Foundation.
 *
 *  Olvid is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU Affero General Public License for more details.
 *
 *  You should have received a copy of the GNU Affero General Public License
 *  along with Olvid.  If not, see <https://www.gnu.org/licenses/>.
 */

import Foundation
import AVFoundation
import MediaPlayer
import os.log
import ObvAppCoreConstants

protocol ObvAudioPlayerDelegate: AnyObject {
    func audioPlayerDidFinishPlaying()
    func audioPlayerDidStopPlaying()
    func audioIsPlaying(currentTime: TimeInterval)
}

final class ObvAudioPlayer: NSObject, AVAudioPlayerDelegate {

    public static let shared: ObvAudioPlayer = ObvAudioPlayer()
    private let log = OSLog(subsystem: ObvAppCoreConstants.logSubsystem, category: String(describing: ObvAudioPlayer.self))

    override init() {
        super.init()
        setupRemoteTransportControls()
    }

    private var audioPlayer: AVAudioPlayer?
    private var timer: Timer?
    var current: HardLinkToFyle?
    weak var delegate: ObvAudioPlayerDelegate?
    var timeObserverToken: Any?

    var currentPosition: TimeInterval? {
        audioPlayer?.currentTime
    }

    var isPlaying: Bool { audioPlayer?.isPlaying ?? false }

    func play(_ hardLink: HardLinkToFyle, enableSpeaker speaker: Bool, at time: TimeInterval? = 0) -> Bool {
        guard let url = hardLink.hardlinkURL else { return false }
        current = hardLink
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            if let timer = timer {
                timer.invalidate()
            }
            guard let audioPlayer = self.audioPlayer else { assertionFailure(); return false }
            timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) {_ in
                guard self.isPlaying else { return }
                self.delegate?.audioIsPlaying(currentTime: audioPlayer.currentTime)
                self.setupNowPlaying()
            }
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playAndRecord, options: [.allowBluetooth, .allowBluetoothA2DP])
            } catch {
                return false
            }
            if let time = time {
                audioPlayer.currentTime = time
            }
            setSpeaker(to: speaker)
            os_log("🎵 Start playing %{public}@ with speaker %{public}@", log: self.log, type: .info, url.lastPathComponent, speaker ? "enable" : "disable")
            let success = audioPlayer.play()
            if success {
                setupNowPlaying()
            }
            return success
        } catch(let error) {
            os_log("🎵 Failed to play: %{public}@", log: self.log, type: .fault, error.localizedDescription)
            return false
        }
    }

    func stop() {
        guard let audioPlayer = audioPlayer else { return }
        os_log("🎵 Stop %{public}@", log: self.log, type: .info, audioPlayer.url?.lastPathComponent ?? "nil")
        audioPlayer.stop()
        self.audioPlayer = nil
        self.current = nil
        self.timer?.invalidate()
        self.timer = nil
        self.delegate?.audioPlayerDidStopPlaying()
        self.clearNowPlaying()
    }

    func pause() {
        guard let audioPlayer = audioPlayer else { return }
        os_log("🎵 Pause %{public}@", log: self.log, type: .info, audioPlayer.url?.lastPathComponent ?? "nil")
        audioPlayer.pause()
        self.clearNowPlaying()
    }

    func resume(enableSpeaker speaker: Bool, at time: TimeInterval? = 0) {
        guard let audioPlayer = audioPlayer else { return }
        if let time = time {
            audioPlayer.currentTime = time
        }
        setSpeaker(to: speaker)
        os_log("🎵 Resume %{public}@ with speaker %{public}@", log: self.log, type: .info, audioPlayer.url?.lastPathComponent ?? "nil", speaker ? "enable" : "disable")
        audioPlayer.play()
        self.delegate?.audioIsPlaying(currentTime: audioPlayer.currentTime)
        self.setupNowPlaying()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully successfull: Bool) {
        guard successfull else { return }
        os_log("🎵 Audio did finish playing %{public}@", log: self.log, type: .info, player.url?.lastPathComponent ?? "nil")
        self.delegate?.audioPlayerDidFinishPlaying()
        self.clearNowPlaying()
    }

    static func duration(of url: URL) -> Double {
        let audioAsset = AVURLAsset.init(url: url, options: nil)
        let duration = audioAsset.duration
        let durationInSeconds = CMTimeGetSeconds(duration)
        return durationInSeconds
    }

    var isSpeakerEnable: Bool {
        let session = AVAudioSession.sharedInstance()
        return session.currentRoute.outputs.contains(where: { $0.isSpeaker })
    }

    func setSpeaker(to value: Bool) {
        guard value != isSpeakerEnable else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            if value {
                try session.overrideOutputAudioPort(.speaker)
            } else {
                try session.overrideOutputAudioPort(.none)
            }
            os_log("🎵 Speaker was %{public}@", log: log, type: .info, value ? "enable" : "disable")
        } catch {
            os_log("🎵 Could not %{public}@ speaker: %{public}@", log: log, type: .info, value ? "enable" : "disable", error.localizedDescription)
        }
    }

}

extension ObvAudioPlayer {

    func setupRemoteTransportControls() {
        /// Get the shared MPRemoteCommandCenter
        let commandCenter = MPRemoteCommandCenter.shared()

        /// Add handler for Play Command
        commandCenter.playCommand.addTarget { [weak self] event in
            guard let audioPlayer = self?.audioPlayer else { return .commandFailed }
            if !audioPlayer.isPlaying {
                audioPlayer.play()
                return .success
            }
            return .commandFailed
        }

        /// Add handler for Pause Command
        commandCenter.pauseCommand.addTarget { [weak self] event in
            guard let audioPlayer = self?.audioPlayer else { return .commandFailed }
            if audioPlayer.isPlaying {
                audioPlayer.pause()
                return .success
            }
            return .commandFailed
        }
    }

    func setupNowPlaying() {
        guard let audioPlayer = self.audioPlayer else { return }
        /// Define Now Playing Info
        var nowPlayingInfo = [String: Any]()
        nowPlayingInfo[MPMediaItemPropertyTitle] = audioPlayer.url?.lastPathComponent

        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = audioPlayer.currentTime
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = Int(audioPlayer.duration)
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0

        /// Set the metadata
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

}
