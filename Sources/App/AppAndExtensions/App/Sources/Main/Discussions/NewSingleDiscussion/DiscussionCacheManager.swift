/*
 *  Olvid for iOS
 *  Copyright © 2019-2025 Olvid SAS
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

import ObvUI
import ObvUICoreData
import os.log
import QuickLook
import UIKit
import ObvDesignSystem
import ObvAppCoreConstants
import AVFoundation


final class DiscussionCacheManager: DiscussionCacheDelegate {
    
    private struct HardlinkAndSize: Hashable {
        let hardlinkURL: URL
        let size: ObvDiscussionThumbnailSize
    }

    private static let log = OSLog(subsystem: ObvAppCoreConstants.logSubsystem, category: "DiscussionCacheManager")

    private var imageCache = [HardlinkAndSize: UIImage]()
    private var imageCacheContinuations = [HardlinkAndSize: [CheckedContinuation<UIImage, Error>]]()
    
    private var dataDetectedCache = [String: [ObvDiscussionDataDetected]]()
    private var dataDetectedCacheCompletions = [String: [(Bool) -> Void]]()
    
    private var linkCache = [String: [URL]]()

    private var hardlinksCache = [TypeSafeManagedObjectID<FyleMessageJoinWithStatus>: HardLinkToFyle]()
    private var hardlinksCacheCompletions = [TypeSafeManagedObjectID<PersistedMessage>: [(Bool) -> Void]]()
    private var hardlinksCacheContinuations = [TypeSafeManagedObjectID<FyleMessageJoinWithStatus>: [CheckedContinuation<Void, Error>]]()
    
    private var durationsFormattedCache = [URL: String]()
    private var durationsFormattedCacheContinuations = [URL: [CheckedContinuation<String?, Error>]]()
    
    private var replyToCache = [TypeSafeManagedObjectID<PersistedMessage>: ReplyToBubbleView.Configuration]()
    private var replyToCacheCompletions = [TypeSafeManagedObjectID<PersistedMessage>: [() -> Void]]()

    private var downsizedThumbnailCache = [TypeSafeManagedObjectID<FyleMessageJoinWithStatus>: UIImage]()
    private var downsizedThumbnailCacheCompletions = [TypeSafeManagedObjectID<FyleMessageJoinWithStatus>: [(Result<Void, Error>) -> Void]]()

    private let internalQueue = DispatchQueue(label: "DiscussionCacheManager internal queue")
    private let queueForPostingNotifications = DispatchQueue(label: "DiscussionCacheManager internal queue for posting notifications")
    
    private let backgroundContext = ObvStack.shared.newBackgroundContext()
    
    private let previewFetcherDelegate: MissingReceivedLinkPreviewFetcherDelegate?
    
    private let queueForLaunchingImageGeneration = DispatchQueue(label: "DiscussionCacheManager internal queue for launching image generations")
    
    init(previewFetcherDelegate: MissingReceivedLinkPreviewFetcherDelegate? = nil) {
        self.previewFetcherDelegate = previewFetcherDelegate
    }
    
    private static func makeError(message: String) -> Error {
        NSError(domain: String(describing: self), code: 0, userInfo: [NSLocalizedFailureReasonErrorKey: message])
    }
    private func makeError(message: String) -> Error {
        DiscussionCacheManager.makeError(message: message)
    }

    func getCachedHardlinkForFyleMessageJoinWithStatus(with objectID: TypeSafeManagedObjectID<FyleMessageJoinWithStatus>) -> HardLinkToFyle? {
        assert(Thread.isMainThread)
        return hardlinksCache[objectID]
    }
    
    func requestMissingPreviewIfNeededForMessage(with objectID: TypeSafeManagedObjectID<PersistedMessageReceived>) {
        assert(Thread.isMainThread)
        
        Task {
            do {
                try await previewFetcherDelegate?.fetchMissingPreviewIfNeeded(with: objectID, cacheDelegate: self)
            } catch {
                assertionFailure()
            }
        }
    }
    
    func requestAllRelevantHardlinksForMessage(with objectID: TypeSafeManagedObjectID<PersistedMessage>, completionWhenHardlinksCached: @escaping ((Bool) -> Void)) {
        
        assert(Thread.isMainThread)
        
        guard let message = try? PersistedMessage.get(with: objectID, within: ObvStack.shared.viewContext) else {
            // Can happen if the message has just been deleted
            completionWhenHardlinksCached(false)
            return
        }
        
        // Create a list of joins/fyleElements for which we want to request hardlinks

        let joinObjectIDs: [TypeSafeManagedObjectID<FyleMessageJoinWithStatus>]
        let fyleElements: [FyleElement]
        do {
            var joins = [FyleMessageJoinWithStatus]()
            if let sentMessage = message as? PersistedMessageSent {
                joins.append(contentsOf: sentMessage.fyleMessageJoinWithStatuses.filter({ !$0.isPreviewType }) as [FyleMessageJoinWithStatus])
            } else if let receivedMessage = message as? PersistedMessageReceived {
                joins.append(contentsOf: receivedMessage.fyleMessageJoinWithStatuses.filter({ !$0.isPreviewType }) as [FyleMessageJoinWithStatus])
            } else {
                assertionFailure()
            }

            switch message.genericRepliesTo {
            case .available(message: let replyTo):
                let joinsFromReplyTo = replyTo.fyleMessageJoinWithStatus?.filter({ !$0.isPreviewType }) ?? []
                joins.append(contentsOf: joinsFromReplyTo)
            case .none, .notAvailableYet, .deleted:
                break
            }
            
            guard !joins.isEmpty else {
                completionWhenHardlinksCached(false)
                return
            }
            joinObjectIDs = joins.map({ $0.typedObjectID })
            fyleElements = joins.compactMap({ $0.fyleElement })
            guard fyleElements.count == joins.count else {
                // This can happen when a message is remotely wiped (e.g. when someone else did delete a message for all participants of a discussion)
                completionWhenHardlinksCached(false)
                return
            }
        }
        
        // Store the completion
        
        if var completions = hardlinksCacheCompletions[objectID] {
            completions.append(completionWhenHardlinksCached)
            hardlinksCacheCompletions[objectID] = completions
            return
        } else {
            hardlinksCacheCompletions[objectID] = [completionWhenHardlinksCached]
        }

        // Request hardlinks
        
        HardLinksToFylesNotifications.requestAllHardLinksToFyles(fyleElements: fyleElements) { hardlinks in
            DispatchQueue.main.async { [weak self] in
                var cellNeedsToUpdateItsConfiguration = false
                for (joinObjectID, hardlink) in zip(joinObjectIDs, hardlinks) {
                    if let cachedHardlink = self?.hardlinksCache[joinObjectID] {
                        if cachedHardlink != hardlink {
                            self?.hardlinksCache[joinObjectID] = hardlink
                            cellNeedsToUpdateItsConfiguration = true
                        }
                    } else {
                        self?.hardlinksCache[joinObjectID] = hardlink
                        cellNeedsToUpdateItsConfiguration = true
                    }
                }
                guard let completionsToCall = self?.hardlinksCacheCompletions.removeValue(forKey: objectID) else { return }
                for completionToCall in completionsToCall {
                    completionToCall(cellNeedsToUpdateItsConfiguration)
                }
            }
        }.postOnDispatchQueue()
        
    }
    
    // MARK: - Images (and thumbnails) for FyleMessageJoinWithStatus

    func getCachedDurationFormatted(for objectID: TypeSafeManagedObjectID<FyleMessageJoinWithStatus>) -> String? {
        guard let hardlink = getCachedHardlinkForFyleMessageJoinWithStatus(with: objectID) else { return nil }
        return getCachedDurationFormattedForHardlink(hardlink: hardlink)
    }
    
    @MainActor
    func requestDurationFormatted(objectID: TypeSafeManagedObjectID<FyleMessageJoinWithStatus>) async throws {
        try await requestHardlinkForFyleMessageJoinWithStatus(with: objectID)
        guard let hardlink = getCachedHardlinkForFyleMessageJoinWithStatus(with: objectID) else { assertionFailure(); throw Self.makeError(message: "Internal error") }
        _ = try await requestDurationFormattedForHardlink(hardlink: hardlink)
    }
    
    func getCachedDurationFormattedForHardlink(hardlink: HardLinkToFyle) -> String? {
        guard let hardlinkURL = hardlink.hardlinkURL else { return nil }
        return durationsFormattedCache[hardlinkURL]
    }
    
    @MainActor
    @discardableResult func requestDurationFormattedForHardlink(hardlink: HardLinkToFyle) async throws -> String? {
        guard let hardlinkURL = hardlink.hardlinkURL else {
            assertionFailure()
            throw Self.makeError(message: "Could not find hardlink URL in hardlink \(hardlink.fyleURL.lastPathComponent)")
        }
        
        if let duration = durationsFormattedCache[hardlinkURL] {
            return duration
        }
        
        guard FileManager.default.fileExists(atPath: hardlinkURL.path) else {
            assertionFailure()
            throw Self.makeError(message: "There is no file at the URL indicated in the hardlink for the fyle \(hardlink.fyleURL.lastPathComponent)")
        }

        os_log("Dealing with a file duration request for a hardlink with a hardlink URL that exists on disk: %{public}@", log: Self.log, type: .info, hardlinkURL.path)

        let durationFormatted: String?
        if durationsFormattedCacheContinuations.keys.contains(hardlinkURL) {
            os_log("Another task already deals with this hardlink URL: %{public}@", log: Self.log, type: .info, hardlinkURL.path)
            durationFormatted = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, Error>) in
                if let duration = durationsFormattedCache[hardlinkURL] {
                    continuation.resume(returning: duration)
                } else {
                    var continuations = durationsFormattedCacheContinuations[hardlinkURL, default: []]
                    continuations.append(continuation)
                    durationsFormattedCacheContinuations[hardlinkURL] = continuations
                }
            }
        } else {
            
            os_log("We are in charge of fetching the duration for this hardlink URL: %{public}@", log: Self.log, type: .info, hardlinkURL.path)
            
            durationsFormattedCacheContinuations[hardlinkURL] = [] // We are in charge -> this prevents another call to fall in this branch
            
            do {
                let asset = AVAsset(url: hardlinkURL)
                let duration = try await asset.load(.duration)
                
                durationFormatted = duration.formatted
            } catch {
                if let continuations = durationsFormattedCacheContinuations.removeValue(forKey: hardlinkURL) {
                    continuations.forEach({ $0.resume(throwing: error) })
                }
                throw error
            }
            
            durationsFormattedCache[hardlinkURL] = durationFormatted
            
            if let continuations = durationsFormattedCacheContinuations.removeValue(forKey: hardlinkURL) {
                continuations.forEach({ $0.resume(returning: durationFormatted) })
            }
            
        }
        
        return durationFormatted
    }
    
    /// This method performs the request to make the hardlink available in cache.
    @MainActor
    func requestHardlinkForFyleMessageJoinWithStatus(with objectID: TypeSafeManagedObjectID<FyleMessageJoinWithStatus>) async throws {
        
        guard !hardlinksCache.keys.contains(objectID) else { return }
        
        guard let fyleElement = try? FyleMessageJoinWithStatus.get(objectID: objectID.objectID, within: ObvStack.shared.viewContext)?.fyleElement else {
            throw Self.makeError(message: "Could not get FyleMessageJoinWithStatus")
        }
        
        if hardlinksCacheContinuations.keys.contains(objectID) {
            
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                assert(Thread.isMainThread)
                if hardlinksCache[objectID] != nil {
                    continuation.resume()
                } else {
                    var continuations = hardlinksCacheContinuations[objectID, default: []]
                    continuations.append(continuation)
                    hardlinksCacheContinuations[objectID] = continuations
                }
            }

        } else {
            
            hardlinksCacheContinuations[objectID] = [] // We are in charge -> this prevents another call to fall in this branch
            
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                HardLinksToFylesNotifications.requestHardLinkToFyle(fyleElement: fyleElement) { result in
                    DispatchQueue.main.async { [weak self] in
                        let error: Error?
                        switch result {
                        case .success(let hardlink):
                            assert(self?.hardlinksCache[objectID] == nil)
                            os_log("The request hardlink to fyle %{public}@ returned a hardlink", log: Self.log, type: .info, fyleElement.fyleURL.lastPathComponent)
                            if let hardlinkURL = hardlink.hardlinkURL {
                                if FileManager.default.fileExists(atPath: hardlinkURL.path) {
                                    os_log("The hardlink to fyle %{public}@ has a hardlink URL that exists on disk. Good.", log: Self.log, type: .info, fyleElement.fyleURL.lastPathComponent)
                                    self?.hardlinksCache[objectID] = hardlink
                                    error = nil
                                } else {
                                    os_log("The hardlink to fyle %{public}@ has a hardlink URL but it does not exist on disk", log: Self.log, type: .fault, fyleElement.fyleURL.lastPathComponent)
                                    assertionFailure()
                                    error = Self.makeError(message: "The hardlink to fyle \(fyleElement.fyleURL.lastPathComponent) has a hardlink URL but it does not exist on disk")
                                }
                            } else {
                                os_log("The hardlink to fyle %{public}@ has no hardlink URL", log: Self.log, type: .fault, fyleElement.fyleURL.lastPathComponent)
                                error = Self.makeError(message: "The hardlink to fyle \(fyleElement.fyleURL.lastPathComponent) has no hardlink URL")
                            }
                        case .failure(let _error):
                            assertionFailure(_error.localizedDescription)
                            error = _error
                        }
                        
                        if let error = error {
                            if let continuations = self?.hardlinksCacheContinuations.removeValue(forKey: objectID) {
                                continuations.forEach({ $0.resume(throwing: error) })
                            }
                            continuation.resume(throwing: error)
                        } else {
                            if let continuations = self?.hardlinksCacheContinuations.removeValue(forKey: objectID) {
                                continuations.forEach({ $0.resume() })
                            }
                            continuation.resume()
                        }
                        
                    }
                }.postOnDispatchQueue(queueForPostingNotifications)
                
            }

        }
        
    }

    
    func getCachedDataDetection(attributedString: AttributedString) -> [ObvDiscussionDataDetected]? {
        let text = String(attributedString.characters)
        return getCachedDataDetection(text: text)
    }

    
    private func getCachedDataDetection(text: String) -> [ObvDiscussionDataDetected]? {
        return dataDetectedCache[text]
    }
    

    func requestDataDetection(attributedString: AttributedString, completionWhenDataDetectionCached: @escaping ((Bool) -> Void)) {
        
        assert(Thread.isMainThread)
        
        let text = String(attributedString.characters)
                
        if let dataDetected = getCachedDataDetection(text: text) {
            completionWhenDataDetectionCached(!dataDetected.isEmpty)
            return
        }
        
        if var completions = dataDetectedCacheCompletions[text] {
            completions.append(completionWhenDataDetectionCached)
            dataDetectedCacheCompletions[text] = completions
            return
        } else {
            dataDetectedCacheCompletions[text] = [completionWhenDataDetectionCached]
            internalQueue.async {
                let matches: [ObvDiscussionDataDetected] = text
                    .detectData()
                    .compactMap { result in
                        guard let link = result.getLinkForAttributedString() else { return nil }
                        return ObvDiscussionDataDetected(range: result.range, resultType: result.resultType, link: link)
                    }
                DispatchQueue.main.async { [weak self] in
                    guard let _self = self else { return }
                    assert(_self.dataDetectedCache[text] == nil)
                    _self.dataDetectedCache[text] = matches
                    guard let completions = _self.dataDetectedCacheCompletions.removeValue(forKey: text) else { assertionFailure(); return }
                    for completion in completions {
                        completion(!matches.isEmpty)
                    }
                }
            }
        }
        
    }
    

    func getFirstHttpsURL(text: String) -> URL? {
        if let urls = linkCache[text] {
            return urls.first
        } else {
            let urls = text.getHttpsURLs()
            linkCache[text] = urls
            return urls.first
        }
    }

    
    func getCachedImageForHardlink(hardlink: HardLinkToFyle, size: ObvDiscussionThumbnailSize) -> UIImage? {
        guard let hardlinkURL = hardlink.hardlinkURL else { return nil }
        return imageCache[HardlinkAndSize(hardlinkURL: hardlinkURL, size: size)]
    }

    
    /// If this method returns without throwing, a prepared image has been cached for the hardlink at the requested size (or more).
    @MainActor
    @discardableResult func requestImageForHardlink(hardlink: HardLinkToFyle, size: ObvDiscussionThumbnailSize) async throws -> UIImage {
        
        guard let hardlinkURL = hardlink.hardlinkURL else {
            assertionFailure()
            throw Self.makeError(message: "Could not find hardlink URL in hardlink \(hardlink.fyleURL.lastPathComponent)")
        }

        let hardlinkAndSize = HardlinkAndSize(hardlinkURL: hardlinkURL, size: size)

        if let image = imageCache[hardlinkAndSize] {
            return image
        }
        guard FileManager.default.fileExists(atPath: hardlinkURL.path) else {
            assertionFailure()
            throw Self.makeError(message: "There is no file at the URL indicated in the hardlink for the fyle \(hardlink.fyleURL.lastPathComponent)")
        }

        os_log("Dealing with an image request for a hardlink with a hardlink URL that exists on disk: %{public}@", log: Self.log, type: .info, hardlinkURL.path)

        let thumbnail: UIImage
        
        if imageCacheContinuations.keys.contains(hardlinkAndSize) {
        
            os_log("Another task already deals with this hardlink URL: %{public}@", log: Self.log, type: .info, hardlinkURL.path)
            thumbnail = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
                if let image = imageCache[hardlinkAndSize] {
                    continuation.resume(returning: image)
                } else {
                    var continuations = imageCacheContinuations[hardlinkAndSize, default: []]
                    continuations.append(continuation)
                    imageCacheContinuations[hardlinkAndSize] = continuations
                }
            }
            
        } else {
            
            os_log("We are in charge of the image creation for this hardlink URL: %{public}@", log: Self.log, type: .info, hardlinkURL.path)
            
            imageCacheContinuations[hardlinkAndSize] = [] // We are in charge -> this prevents another call to fall in this branch
            
            do {
                switch size {
                case .full(let minSize):
                    thumbnail = try await hardlinkURL.byPreparingThumbnailPreparedForDisplay(ofSize: minSize)
                case .cropBottom(mandatoryWidth: let mandatoryWidth, maxHeight: let maxHeight):
                    thumbnail = try await hardlinkURL.bybyPreparingCropBottomThumbnailPreparedForDisplay(mandatoryWidth: mandatoryWidth, maxHeight: maxHeight)
                }
            } catch {
                if let continuations = imageCacheContinuations.removeValue(forKey: hardlinkAndSize) {
                    continuations.forEach({ $0.resume(throwing: error) })
                }
                throw error
            }
            imageCache[hardlinkAndSize] = thumbnail
            if let continuations = imageCacheContinuations.removeValue(forKey: hardlinkAndSize) {
                continuations.forEach({ $0.resume(returning: thumbnail) })
            }
            
        }
        
        return thumbnail
        
    }
    

    // MARK: - Reply-to

    
    /// Returns a first acceptable version of the `ReplyToBubbleView.Configuration` that is appropriate for the given `message`. If necessary, this method asynchronously computes
    /// a hardlink and a thumbnail allowing to "augment" the returned configuration. If found at least a hardlink can be found, the completion handler is called. The next time this method is called, the returned configuration
    /// will be an "augmented" version of the configuration with a hardlink and, possibly, a thumbnail.
    /// Note that the completion handler is *not* called if there is not hardlink to request.
    @MainActor
    func requestReplyToBubbleViewConfiguration(message: PersistedMessage, completionWhenCellNeedsUpdateConfiguration: @escaping () -> Void) -> ReplyToBubbleView.Configuration? {
        
        let messageObjectID = message.typedObjectID
        
        // If a configuration is cached, we know it is the best we can have, so we return it.
        
        if let cachedConfiguration = replyToCache[messageObjectID] {
            return cachedConfiguration
        }
        
        // Compute a minimal version of the configuration that we can return synchronously
        
        switch message.genericRepliesTo {

        case .none:
            return nil

        case .notAvailableYet:
            return .loading
            
        case .deleted:
            return .messageWasDeleted
            
        case .available(message: let replyTo):

            let name: String
            let nameColor: UIColor
            let lineColor: UIColor
            let bodyColor: UIColor
            let bubbleColor: UIColor
            let appTheme = AppTheme.shared

            if let received = replyTo as? PersistedMessageReceived {
                
                if let contact = received.contactIdentity {
                    name = MessageCellStrings.replyingTo(contact.customOrFullDisplayName)
                    nameColor = contact.cryptoId.colors.text
                    lineColor = contact.cryptoId.colors.text
                } else {
                    name = MessageCellStrings.replyingToContact
                    nameColor = .white
                    lineColor = .systemFill
                }
                
                bodyColor = UIColor.secondaryLabel
                bubbleColor = appTheme.colorScheme.newReceivedCellReplyToBackground

            } else if replyTo is PersistedMessageSent {
                
                name = NSLocalizedString("REPLYING_TO_YOU", comment: "")
                nameColor = .white
                lineColor = appTheme.colorScheme.adaptiveOlvidBlueReversed
                bodyColor = UIColor.secondaryLabel.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
                bubbleColor = appTheme.colorScheme.adaptiveOlvidBlue
                
            } else {
                assertionFailure("Unexpected message type for a reply-to")
                return nil
            }
            
            let showThumbnail: Bool
            if let msg = replyTo as? PersistedMessageReceived {
                showThumbnail = !(replyTo.fyleMessageJoinWithStatus?.isEmpty ?? true) && !msg.readingRequiresUserAction
            } else {
                showThumbnail = !(replyTo.fyleMessageJoinWithStatus?.isEmpty ?? true)
            }
            
            let configuration: ReplyToBubbleView.Configuration
            
            if replyTo.isRemoteWiped {
                
                var deleterName: String?
                if let ownedCryptoId = replyTo.discussion?.ownedIdentity?.cryptoId,
                   let deleterCryptoId = replyTo.deleterCryptoId,
                   let contact = try? PersistedObvContactIdentity.get(contactCryptoId: deleterCryptoId, ownedIdentityCryptoId: ownedCryptoId, whereOneToOneStatusIs: .any, within: ObvStack.shared.viewContext) {
                    deleterName = contact.customOrShortDisplayName
                } else {
                    deleterName = nil
                }
                
                configuration = ReplyToBubbleView.Configuration.remotelyWiped(
                    messageObjectID: replyTo.typedObjectID,
                    deleterName: deleterName,
                    bodyColor: bodyColor,
                    name: name,
                    nameColor: nameColor,
                    lineColor: lineColor,
                    bubbleColor: bubbleColor,
                    showThumbnail: showThumbnail,
                    hardlink: nil,
                    thumbnail: nil)
                
            } else if replyTo.isLocallyWiped {
                
                return .messageWasDeleted

            } else {
                
                configuration = ReplyToBubbleView.Configuration.loaded(
                    messageObjectID: replyTo.typedObjectID,
                    body: replyTo.textBody,
                    bodyColor: bodyColor,
                    name: name,
                    nameColor: nameColor,
                    lineColor: lineColor,
                    bubbleColor: bubbleColor,
                    showThumbnail: showThumbnail,
                    hardlink: nil,
                    thumbnail: nil)
                
            }
            
            // If there is a thumbnail to show, compute it asynchronously.
            
            if showThumbnail {
                
                // Store the completion and be the first (and only) to get a hardlink
                
                if var completions = replyToCacheCompletions[messageObjectID] {
                    
                    completions.append(completionWhenCellNeedsUpdateConfiguration)
                    replyToCacheCompletions[messageObjectID] = completions
                    
                } else {
                    
                    replyToCacheCompletions[messageObjectID] = [completionWhenCellNeedsUpdateConfiguration]
                    
                    Task { [weak self] in
                        guard let _self = self else { return }
                        let hardlink = try await _self.getAppropriateHardlinkForJoinsOfReplyTo(replyTo)
                        var augmentedConfig = configuration.replaceHardLink(with: hardlink)
                        do {
                            let size = CGSize(width: MessageCellConstants.replyToImageSize, height: MessageCellConstants.replyToImageSize)
                            let thumbnail = try await _self.requestImageForHardlink(hardlink: hardlink, size: .full(minSize: size))
                            augmentedConfig = augmentedConfig.replaceThumbnail(with: thumbnail)
                        } catch {
                            // We could not get an image corresponding to the hardlink. We return the current config.
                            os_log("Failed to get appropriate thumbnail for hardlink for a replyTo Bubble: %{public}@. Augmenting the config with the hardlink only.", log: Self.log, type: .error, error.localizedDescription)
                        }
                        // If we reach this point, we can augment the configuration using both the hardlink and the image found. We then return.
                        self?.requestReplyToBubbleViewConfigurationSucceeded(messageObjectID: messageObjectID, configToCache: augmentedConfig)
                    }
                    
                }

            }

            return configuration
            
        }
        
    }
    
    
    private func requestReplyToBubbleViewConfigurationSucceeded(messageObjectID: TypeSafeManagedObjectID<PersistedMessage>, configToCache: ReplyToBubbleView.Configuration) {
        DispatchQueue.main.async { [weak self] in
            guard let _self = self else { return }
            _self.replyToCache[messageObjectID] = configToCache
            guard let completions = _self.replyToCacheCompletions.removeValue(forKey: messageObjectID) else { assertionFailure(); return }
            for completion in completions {
                completion()
            }
        }
    }
    
    
    /// This method is used while computing the configuration of a reply to. When a reply to is found, we first look for an appropriate hardlink to augment its configuration (using this
    /// method). If one is found, we compute a thumbnail (using another method).
    @MainActor
    private func getAppropriateHardlinkForJoinsOfReplyTo(_ replyTo: PersistedMessage) async throws -> HardLinkToFyle {
        let replyToObjectID = replyTo.typedObjectID
        guard let fyleMessageJoinWithStatus = replyTo.fyleMessageJoinWithStatus, !fyleMessageJoinWithStatus.isEmpty else {
            throw Self.makeError(message: "Failed to get appropriate hardlink for joins of replyTo (1)")
        }
        let joinObjectIDs = fyleMessageJoinWithStatus.map({ $0.typedObjectID })
        assert(!joinObjectIDs.isEmpty)
        for joinObjectID in joinObjectIDs {
            if let hardlink = self.getCachedHardlinkForFyleMessageJoinWithStatus(with: joinObjectID), hardlink.hardlinkURL != nil {
                return hardlink
            }
        }
        // If we reach this point, we could not find an appropriate cached hardlink. We request the first one.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HardLinkToFyle, Error>) in
            self.requestAllRelevantHardlinksForMessage(with: replyToObjectID) { hardlinkFound in
                assert(Thread.isMainThread)
                if hardlinkFound, let joinObjectID = joinObjectIDs.first, let hardlink = self.getCachedHardlinkForFyleMessageJoinWithStatus(with: joinObjectID), hardlink.hardlinkURL != nil {
                    continuation.resume(returning: hardlink)
                } else {
                    continuation.resume(throwing: Self.makeError(message: "Failed to get appropriate hardlink for joins of replyTo (2)"))
                }
            }
        }
    }

    
    // MARK: - Downsized thumbnails
    
    func getCachedDownsizedThumbnail(objectID: TypeSafeManagedObjectID<FyleMessageJoinWithStatus>) -> UIImage? {
        return downsizedThumbnailCache[objectID]
    }
    
    
    func removeCachedDownsizedThumbnail(objectID: TypeSafeManagedObjectID<FyleMessageJoinWithStatus>) {
        _ = downsizedThumbnailCache.removeValue(forKey: objectID)
    }
    
    
    func requestDownsizedThumbnail(objectID: TypeSafeManagedObjectID<FyleMessageJoinWithStatus>, data: Data, completionWhenImageCached: @escaping ((Result<Void, Error>) -> Void)) {

        assert(Thread.isMainThread)
        
        // Store the completion
        
        if var completions = downsizedThumbnailCacheCompletions[objectID] {
            completions.append(completionWhenImageCached)
            downsizedThumbnailCacheCompletions[objectID] = completions
            return
        } else {
            downsizedThumbnailCacheCompletions[objectID] = [completionWhenImageCached]
        }

        // Request the downsized image
        
        internalQueue.async { [weak self] in
            guard let image = UIImage(data: data) else {
                self?.requestDownsizedThumbnailFailed(objectID: objectID, errorMessage: "Could not turn data into an UIImage")
                return
            }
            self?.requestDownsizedThumbnailFailedSucceeded(objectID: objectID, imageToCache: image)
        }
    }

    private func requestDownsizedThumbnailFailed(objectID: TypeSafeManagedObjectID<FyleMessageJoinWithStatus>, errorMessage: String) {
        assert(!Thread.isMainThread)
        DispatchQueue.main.async { [weak self] in
            guard let _self = self else { return }
            guard let completions = _self.downsizedThumbnailCacheCompletions.removeValue(forKey: objectID) else { assertionFailure(); return }
            for completion in completions {
                completion(.failure(_self.makeError(message: errorMessage)))
            }
        }
    }

    
    private func requestDownsizedThumbnailFailedSucceeded(objectID: TypeSafeManagedObjectID<FyleMessageJoinWithStatus>, imageToCache: UIImage) {
        assert(!Thread.isMainThread)
        DispatchQueue.main.async { [weak self] in
            guard let _self = self else { return }
            _self.downsizedThumbnailCache[objectID] = imageToCache
            guard let completions = _self.downsizedThumbnailCacheCompletions.removeValue(forKey: objectID) else { assertionFailure(); return }
            for completion in completions {
                completion(.success(()))
            }
        }
    }

    
    // MARK: - Images (and thumbnails) for FyleMessageJoinWithStatus

    func getCachedPreparedImage(for objectID: TypeSafeManagedObjectID<FyleMessageJoinWithStatus>, size: ObvDiscussionThumbnailSize) -> UIImage? {
        guard let hardlink = getCachedHardlinkForFyleMessageJoinWithStatus(with: objectID) else { return nil }
        return getCachedImageForHardlink(hardlink: hardlink, size: size)
    }

    
    @MainActor
    func requestPreparedImage(objectID: TypeSafeManagedObjectID<FyleMessageJoinWithStatus>, size: ObvDiscussionThumbnailSize) async throws {
        try await requestHardlinkForFyleMessageJoinWithStatus(with: objectID)
        guard let hardlink = getCachedHardlinkForFyleMessageJoinWithStatus(with: objectID) else { assertionFailure(); throw Self.makeError(message: "Internal error") }
        _ = try await requestImageForHardlink(hardlink: hardlink, size: size)
        assert(getCachedImageForHardlink(hardlink: hardlink, size: size) != nil)
        assert(getCachedPreparedImage(for: objectID, size: size) != nil)
    }


}


// MARK: - Helpers

public extension String {
    
    func detectData() -> [NSTextCheckingResult] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.allTypes.rawValue) else { assertionFailure(); return [] }
        let range = NSRange(location: 0, length: self.utf16.count)
        let matches = detector.matches(in: self, range: range)
        return matches
    }
    
    
    func getHttpsURLs() -> [URL] {
        guard self.lowercased().contains("https") else { return [] }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { assertionFailure(); return [] }
        let range = NSRange(location: 0, length: self.utf16.count)
        let matches = detector.matches(in: self, options: [], range: range)
        guard !matches.isEmpty else { return [] }
        let httpsURLs: [URL] = matches.compactMap { (match) -> URL? in
            guard let rangeOfMatch = Range(match.range, in: self) else { return nil }
            let url = URL(string: String(self[rangeOfMatch]))
            return url?.scheme?.lowercased() == "https" ? url : nil
        }
        return httpsURLs
    }
    
}


private extension NSTextCheckingResult {
    
    /// When data is detected in a string (that will typically be displayed in a message cell), we want to prepare the `NSTextCheckingResult` the best way we
    /// can to facilitate the work at the cell level. We thus return an URL for each `NSTextCheckingResult` which will be used as a link attribute of the attributed string
    /// of the cell's text.
    func getLinkForAttributedString() -> URL? {
        switch self.resultType {
        case .phoneNumber:
            var urlComponents = URLComponents()
            urlComponents.scheme = "tel"
            urlComponents.host = self.phoneNumber
            guard let url = urlComponents.url else { assertionFailure(); return nil }
            return url
        case .address:
            guard let address = self.addressComponents?.values.map({String($0)}).joined(separator: "+") else { assertionFailure(); return nil }
            var urlComponents = URLComponents()
            urlComponents.scheme = "https"
            urlComponents.host = "maps.apple.com"
            urlComponents.queryItems = [.init(name: "address", value: address)]
            guard let url = urlComponents.url else { assertionFailure(); return nil }
            return url
        case .date:
            guard let timeIntervalSinceReferenceDate = self.date?.timeIntervalSinceReferenceDate else { assertionFailure(); return nil }
            guard let url = URL(string: "calshow:\(timeIntervalSinceReferenceDate)") else { assertionFailure(); return nil }
            return url
        case .link:
            guard let url = self.url else { assertionFailure(); return nil }
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = "https"
            guard let finalURL = components.url else { assertionFailure(); return nil }
            return finalURL
        default:
            assertionFailure()
            return url
        }
    }
    
}


private extension CMTime {
    var formatted: String? {
        guard let sec = seconds?.rounded() else { return nil }

        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        if sec < 60 * 60 {
            formatter.allowedUnits = [.minute, .second]
        } else {
            formatter.allowedUnits = [.hour, .minute, .second]
        }
        return formatter.string(from: sec) ?? nil
    }

    var seconds: Double? {
        let time = CMTimeGetSeconds(self)
        guard time.isNaN == false else { return nil }
        return time
    }
}
