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

import CoreData
import Combine
import os.log
import ObvUI
import SwiftUI
import ObvUICoreData
import ObvSystemIcon
import ObvSettings
import ObvDesignSystem
import ObvAppCoreConstants
import ObvUserNotificationsSounds


final class DiscussionSettingsHostingViewController: UIHostingController<DiscussionExpirationSettingsWrapperView> {

    fileprivate let model: DiscussionExpirationSettingsViewModel

    init?(discussionSharedConfiguration: PersistedDiscussionSharedConfiguration, discussionLocalConfiguration: PersistedDiscussionLocalConfiguration) {
        assert(Thread.isMainThread)
        assert(discussionSharedConfiguration.managedObjectContext == ObvStack.shared.viewContext)
        guard let model = DiscussionExpirationSettingsViewModel(
            sharedConfigurationInViewContext: discussionSharedConfiguration,
            localConfigurationInViewContext: discussionLocalConfiguration) else {
                return nil
            }
        let view = DiscussionExpirationSettingsWrapperView(
            model: model,
            localConfiguration: discussionLocalConfiguration,
            sharedConfiguration: model.sharedConfigurationInScratchViewContext)
        self.model = model
        super.init(rootView: view)
        model.delegate = self
        self.isModalInPresentation = true // We make sure the modal cannot be too easily dismissed
    }

    @objc required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }


}

extension DiscussionSettingsHostingViewController: DiscussionExpirationSettingsViewModelDelegate {
 
    func dismissAction() {
        self.dismiss(animated: true)
    }

}


protocol DiscussionExpirationSettingsViewModelDelegate: AnyObject {
    func dismissAction()
}

final class DiscussionExpirationSettingsViewModel: ObservableObject {

    weak var delegate: DiscussionExpirationSettingsViewModelDelegate?

    private let scratchViewContext: NSManagedObjectContext
    @Published private(set) var localConfigurationInViewContext: PersistedDiscussionLocalConfiguration
    private(set) var sharedConfigurationInScratchViewContext: PersistedDiscussionSharedConfiguration
    private let ownedIdentityInViewContext: PersistedObvOwnedIdentity
    @Published var changed: Bool // This allows to "force" the refresh of the view
    @Published var showConfirmationMessageBeforeSavingSharedConfig = false

    init?(sharedConfigurationInViewContext: PersistedDiscussionSharedConfiguration, localConfigurationInViewContext: PersistedDiscussionLocalConfiguration) {
        let scratchViewContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        scratchViewContext.persistentStoreCoordinator = ObvStack.shared.persistentStoreCoordinator
        self.scratchViewContext = scratchViewContext
        guard let sharedConfigurationInScratchViewContext = try? PersistedDiscussionSharedConfiguration.get(objectID: sharedConfigurationInViewContext.objectID, within: scratchViewContext) else {
            return nil
        }
        self.sharedConfigurationInScratchViewContext = sharedConfigurationInScratchViewContext
        self.localConfigurationInViewContext = localConfigurationInViewContext
        guard let _ownedIdentity = sharedConfigurationInScratchViewContext.discussion?.ownedIdentity else {
            return nil
        }
        self.ownedIdentityInViewContext = _ownedIdentity
        self.changed = false
    }

    private let log = OSLog(subsystem: ObvAppCoreConstants.logSubsystem, category: "DiscussionExpirationSettingsViewModel")

    var sharedConfigCanBeModified: Bool {
        sharedConfigurationInScratchViewContext.canBeModifiedAndSharedByOwnedIdentity
    }

    func updateSharedConfiguration(with value: PersistedDiscussionSharedConfigurationValue) {
        guard let discussionId = try? sharedConfigurationInScratchViewContext.discussion?.identifier else {
            assertionFailure()
            return
        }
        do {
            _ = try ownedIdentityInViewContext.replaceDiscussionSharedConfigurationSentByThisOwnedIdentity(
                with: value.toExpirationJSON(overriding: sharedConfigurationInScratchViewContext),
                inDiscussionWithId: discussionId)
        } catch {
            assertionFailure()
            return
        }
        withAnimation {
            self.changed.toggle()
        }
    }

    func dismissAction(sendNewSharedConfiguration: Bool?) {
        assert(Thread.isMainThread)
        guard let discussionId = try? sharedConfigurationInScratchViewContext.discussion?.identifier else {
            delegate?.dismissAction()
            return
        }
        guard scratchViewContext.hasChanges else {
            delegate?.dismissAction()
            return
        }
        // If we reach this point, the user may have changed the shared settings.
        // We compare the shared settings within the scratch context with those within the view context.
        guard let sharedConfigurationInViewContext = try? PersistedDiscussionSharedConfiguration.get(objectID: sharedConfigurationInScratchViewContext.objectID, within: ObvStack.shared.viewContext) else {
            assertionFailure()
            delegate?.dismissAction()
            return
        }
        guard sharedConfigurationInViewContext.differs(from: sharedConfigurationInScratchViewContext) else {
            delegate?.dismissAction()
            return
        }
        // If we reach this point, we should as the user to confirm her changes since they will be shared with other participants
        guard let confirmed = sendNewSharedConfiguration else {
            showConfirmationMessageBeforeSavingSharedConfig = true
            return
        }
        if confirmed {
            let expirationJSON = sharedConfigurationInScratchViewContext.toExpirationJSON()
            ObvMessengerInternalNotification.userWantsToSetAndShareNewDiscussionSharedExpirationConfiguration(
                ownedCryptoId: ownedIdentityInViewContext.cryptoId,
                discussionId: discussionId,
                expirationJSON: expirationJSON)
                .postOnDispatchQueue()
        }
        delegate?.dismissAction()
    }

}

fileprivate extension PersistedDiscussionLocalConfiguration {

    var _autoRead: OptionalBoolType {
        OptionalBoolType(autoRead)
    }

    var _retainWipedOutboundMessages: OptionalBoolType {
        OptionalBoolType(retainWipedOutboundMessages)
    }

    var _doSendReadReceipt: OptionalBoolType {
        OptionalBoolType(doSendReadReceipt)
    }

    var _countBasedRetentionIsActive: OptionalBoolType {
        OptionalBoolType(countBasedRetentionIsActive)
    }

    var _muteNotificationsDuration: MuteDurationOption? { nil }

    var _notificationSound: OptionalNotificationSound {
        OptionalNotificationSound(notificationSound)
    }

    var _performInteractionDonation: OptionalBoolType {
        OptionalBoolType(performInteractionDonation)
    }

}

extension PersistedDiscussionSharedConfiguration {

    func setReadOnce(model: DiscussionExpirationSettingsViewModel, to value: Bool) {
        model.updateSharedConfiguration(with: .readOnce(readOnce: value))
    }

    func getVisibilityDurationOption(model: DiscussionExpirationSettingsViewModel) -> TimeInterval? {
        visibilityDuration
    }

    func setVisibilityDurationOption(model: DiscussionExpirationSettingsViewModel, to value: TimeInterval?) {
        model.updateSharedConfiguration(with: .visibilityDuration(visibilityDuration: value))
    }

    func getExistenceDurationOption(model: DiscussionExpirationSettingsViewModel) -> TimeInterval? {
        existenceDuration
    }

    func setExistenceDurationOption(model: DiscussionExpirationSettingsViewModel, to value: TimeInterval?) {
        model.updateSharedConfiguration(with: .existenceDuration(existenceDuration: value))
    }

}

enum OptionalBoolType: Int, CaseIterable, Identifiable {

    case none = -1
    case falseValue = 0
    case trueValue = 1
    var id: Int { rawValue }
    init(_ value: Bool?) {
        switch value {
        case .none:
            self = .none
        case .some(let val):
            self = val ? .trueValue : .falseValue
        }
    }
    var value: Bool? {
        switch self {
        case .none: return nil
        case .trueValue: return true
        case .falseValue: return false
        }
    }
}

enum OptionalFetchContentRichURLsMetadataChoice: Int, CaseIterable, Identifiable {
    case none = -1
    case never = 0
    case withinSentMessagesOnly = 1
    case always = 2
    var id: Int { rawValue }
    init(_ value: ObvMessengerSettings.Discussions.FetchContentRichURLsMetadataChoice?) {
        switch value {
        case .none:
            self = .none
        case .some(let val):
            switch val {
            case .never: self = .never
            case .withinSentMessagesOnly: self = .withinSentMessagesOnly
            case .always: self = .always
            }
        }
    }
    var value: ObvMessengerSettings.Discussions.FetchContentRichURLsMetadataChoice? {
        switch self {
        case .none: return nil
        case .never: return .never
        case .withinSentMessagesOnly: return .withinSentMessagesOnly
        case .always: return .always
        }
    }
}

struct DiscussionExpirationSettingsWrapperView: View {

    @ObservedObject fileprivate var model: DiscussionExpirationSettingsViewModel
    @ObservedObject fileprivate var localConfiguration: PersistedDiscussionLocalConfiguration
    fileprivate var sharedConfiguration: PersistedDiscussionSharedConfiguration

    var body: some View {
        DiscussionExpirationSettingsView(
            changed: $model.changed,
            readOnce: ValueWithBinding(sharedConfiguration, \.readOnce) { value, _ in
                sharedConfiguration.setReadOnce(model: model, to: value)
            },
            autoRead: ValueWithBinding(localConfiguration, \._autoRead) {
                PersistedDiscussionLocalConfigurationValue.autoRead($0.value).sendUpdateRequestNotifications(with: $1)
            },
            visibilityDurationOption: ValueWithBinding(sharedConfiguration, sharedConfiguration.getVisibilityDurationOption(model: model)) { value, _ in
                sharedConfiguration.setVisibilityDurationOption(model: model, to: value)
            },
            existenceDurationOption: ValueWithBinding(sharedConfiguration, sharedConfiguration.getExistenceDurationOption(model: model)) { value, _ in
                sharedConfiguration.setExistenceDurationOption(model: model, to: value)
            },
            retainWipedOutboundMessages: ValueWithBinding(localConfiguration, \._retainWipedOutboundMessages) {
                PersistedDiscussionLocalConfigurationValue.retainWipedOutboundMessages($0.value).sendUpdateRequestNotifications(with: $1)
            },
            doSendReadReceipt: ValueWithBinding(localConfiguration, \._doSendReadReceipt) {
                PersistedDiscussionLocalConfigurationValue.doSendReadReceipt($0.value).sendUpdateRequestNotifications(with: $1)
            },
            mentionNotificationMode: ValueWithBinding(localConfiguration, \.mentionNotificationMode) {
                PersistedDiscussionLocalConfigurationValue.mentionNotificationMode($0)
                    .sendUpdateRequestNotifications(with: $1)
            },
            showConfirmationMessageBeforeSavingSharedConfig: $model.showConfirmationMessageBeforeSavingSharedConfig,
            countBasedRetentionIsActive: ValueWithBinding(localConfiguration, \._countBasedRetentionIsActive) {
                PersistedDiscussionLocalConfigurationValue.countBasedRetentionIsActive($0.value).sendUpdateRequestNotifications(with: $1)
            },
            countBasedRetention: ValueWithBinding(
                localConfiguration, \.countBasedRetention,
                defaultValue: ObvMessengerSettings.Discussions.countBasedRetentionPolicy) {
                    PersistedDiscussionLocalConfigurationValue.countBasedRetention($0).sendUpdateRequestNotifications(with: $1) },
            timeBasedRetention: ValueWithBinding(
                localConfiguration, \.timeBasedRetention) {
                    PersistedDiscussionLocalConfigurationValue.timeBasedRetention($0).sendUpdateRequestNotifications(with: $1) },
            muteNotificationsEndDate: localConfiguration.currentMuteNotificationsEndDate,
            muteNotificationsDuration:
                ValueWithBinding(
                    localConfiguration, \._muteNotificationsDuration) {
                        let endDateFromNow = $0?.endDateFromNow
                        PersistedDiscussionLocalConfigurationValue.muteNotificationsEndDate(endDateFromNow).sendUpdateRequestNotifications(with: $1) },
            defaultEmoji: ValueWithBinding(
                localConfiguration, \.defaultEmoji) {
                    PersistedDiscussionLocalConfigurationValue.defaultEmoji($0).sendUpdateRequestNotifications(with: $1) },
            notificationSound: ValueWithBinding(
                localConfiguration, \._notificationSound) {
                    PersistedDiscussionLocalConfigurationValue.notificationSound($0.value).sendUpdateRequestNotifications(with: $1) },
            performInteractionDonation: ValueWithBinding(
                localConfiguration, \._performInteractionDonation) {
                    PersistedDiscussionLocalConfigurationValue.performInteractionDonation($0.value).sendUpdateRequestNotifications(with: $1) },
            sharedConfigCanBeModified: model.sharedConfigCanBeModified,
            dismissAction: model.dismissAction)
    }

}


fileprivate struct DiscussionExpirationSettingsView: View {

    @Binding var changed: Bool
    let readOnce: ValueWithBinding<PersistedDiscussionSharedConfiguration, Bool>
    let autoRead: ValueWithBinding<PersistedDiscussionLocalConfiguration, OptionalBoolType>
    let visibilityDurationOption: ValueWithBinding<PersistedDiscussionSharedConfiguration, TimeInterval?>
    let existenceDurationOption: ValueWithBinding<PersistedDiscussionSharedConfiguration, TimeInterval?>
    let retainWipedOutboundMessages: ValueWithBinding<PersistedDiscussionLocalConfiguration, OptionalBoolType>
    let doSendReadReceipt: ValueWithBinding<PersistedDiscussionLocalConfiguration, OptionalBoolType>
    let mentionNotificationMode: ValueWithBinding<PersistedDiscussionLocalConfiguration, DiscussionMentionNotificationMode>
    @Binding var showConfirmationMessageBeforeSavingSharedConfig: Bool
    let countBasedRetentionIsActive: ValueWithBinding<PersistedDiscussionLocalConfiguration, OptionalBoolType>
    let countBasedRetention: ValueWithBinding<PersistedDiscussionLocalConfiguration, Int>
    let timeBasedRetention: ValueWithBinding<PersistedDiscussionLocalConfiguration, DurationOptionAltOverride>
    let muteNotificationsEndDate: Date?
    let muteNotificationsDuration: ValueWithBinding<PersistedDiscussionLocalConfiguration, MuteDurationOption?>
    let defaultEmoji: ValueWithBinding<PersistedDiscussionLocalConfiguration, String?>
    let notificationSound: ValueWithBinding<PersistedDiscussionLocalConfiguration, OptionalNotificationSound>
    let performInteractionDonation: ValueWithBinding<PersistedDiscussionLocalConfiguration, OptionalBoolType>

    let sharedConfigCanBeModified: Bool
    var dismissAction: (Bool?) -> Void

    @State private var showingMuteActionSheet = false

    private func countBasedRetentionIncrement() {
        countBasedRetention.binding.wrappedValue += 10
    }

    private func countBasedRetentionDecrement() {
        countBasedRetention.binding.wrappedValue = max(10, countBasedRetention.value - 10)
    }

    var muteNotificationsFooter: Text {
        if let muteNotificationsEndDate = muteNotificationsEndDate {
            if muteNotificationsEndDate.timeIntervalSinceNow > TimeInterval(years: 10) {
                return Text("MUTED_NOTIFICATIONS_FOOTER_INDEFINITELY")
            } else {
                return Text("MUTED_NOTIFICATIONS_FOOTER_UNTIL_\(PersistedDiscussionLocalConfiguration.formatDateForMutedNotification(muteNotificationsEndDate))")
            }
        } else {
            return Text("UNMUTED_NOTIFICATIONS_FOOTER")
        }
    }

    var body: some View {
        NavigationView {
            Form {
                /* LOCAL SETTINGS */
                Group {
                    Section(footer: muteNotificationsFooter) {
                        Toggle(isOn: .init {
                            muteNotificationsEndDate != nil
                        } set: { newValue in
                            if newValue {
                                showingMuteActionSheet.toggle()
                            } else {
                                muteNotificationsDuration.set(nil)
                            }
                        }) {
                            Label("MUTE_NOTIFICATIONS", systemIcon: .moonZzzFill)
                        }
                    }

                    Section(footer: Text("discussion-expiration-settings-view.body.section.mention-notification-mode.picker.footer.title")) {
                        Picker(selection: mentionNotificationMode.binding,
                               label: Label("discussion-expiration-settings-view.body.section.mention-notification-mode.picker.title", systemIcon: .bell(.fill))) {

                            ForEach(DiscussionMentionNotificationMode.allCases) { value in
                                Text(value.displayTitle(globalOptions: ObvMessengerSettings.Discussions.notificationOptions))
                                    .tag(value)
                            }
                        }
                    }

                    Section(footer: Text("SEND_READ_RECEIPT_SECTION_FOOTER")) {
                        Picker(selection: doSendReadReceipt.binding, label: Label("SEND_READ_RECEIPTS_LABEL", systemImage: "eye.fill")) {
                            ForEach(OptionalBoolType.allCases) { optionalBool in
                                switch optionalBool {
                                case .none:
                                    let textAppDefault = ObvMessengerSettings.Discussions.doSendReadReceipt ? CommonString.Word.Yes : CommonString.Word.No
                                    Text("\(CommonString.Word.Default) (\(textAppDefault))").tag(optionalBool)
                                case .trueValue:
                                    Text(CommonString.Word.Yes).tag(optionalBool)
                                case .falseValue:
                                    Text(CommonString.Word.No).tag(optionalBool)
                                }
                            }
                        }
                    }
                    ChangeDefaultEmojiView(defaultEmoji: defaultEmoji.binding)
                    Section {
                        NotificationSoundPicker(selection: notificationSound.binding, showDefault: true) { sound -> Text in
                            switch sound {
                            case .none:
                                if let globalNotificationSound = ObvMessengerSettings.Discussions.notificationSound {
                                    return Text("\(CommonString.Word.Default) (\(globalNotificationSound.description))")
                                } else {
                                    let systemSound = (try? AttributedString(markdown: "_\(NotificationSound.system.description)_")) ?? AttributedString(NotificationSound.system.description)
                                    return Text("\(CommonString.Word.Default) (\(systemSound))")
                                }
                            case .some(let sound):
                                if sound == .system {
                                    return Text(sound.description)
                                        .italic()
                                } else {
                                    return Text(sound.description)
                                }
                            }
                        }
                    }
                    Section(footer: Text("PERFORM_INTERACTION_DONATION_FOR_THIS_DISCUSSION_FOOTER")) {
                        Picker(selection: performInteractionDonation.binding, label: Label("PERFORM_INTERACTION_DONATION_FOR_THIS_DISCUSSION_LABEL", systemIcon: .squareAndArrowUp)) {
                            ForEach(OptionalBoolType.allCases) { optionalBool in
                                switch optionalBool {
                                case .none:
                                    let textAppDefault = ObvMessengerSettings.Discussions.performInteractionDonation ? CommonString.Word.Yes : CommonString.Word.No
                                    Text("\(CommonString.Word.Default) (\(textAppDefault))").tag(optionalBool)
                                case .trueValue:
                                    Text(CommonString.Word.Yes).tag(optionalBool)
                                case .falseValue:
                                    Text(CommonString.Word.No).tag(optionalBool)
                                }
                            }
                        }
                    }
                }
                /* RETENTION SETTINGS */
                Group {
                    Section {
                        Text("RETENTION_SETTINGS_TITLE")
                            .font(.headline)
                        Text("LOCAL_RETENTION_SETTINGS_EXPLANATION")
                            .font(.callout)
                    }
                    Section(footer: Text("COUNT_BASED_SINGLE_DISCUSSION_SECTION_FOOTER")) {
                        Picker(selection: countBasedRetentionIsActive.binding, label: Label("COUNT_BASED_LABEL", systemImage: "number")) {
                            ForEach(OptionalBoolType.allCases) { optionalBool in
                                switch optionalBool {
                                case .none:
                                    let textAppDefault = ObvMessengerSettings.Discussions.countBasedRetentionPolicyIsActive ? CommonString.Word.Yes : CommonString.Word.No
                                    Text("\(CommonString.Word.Default) (\(textAppDefault))").tag(optionalBool)
                                case .trueValue:
                                    Text(CommonString.Word.Yes).tag(optionalBool)
                                case .falseValue:
                                    Text(CommonString.Word.No).tag(optionalBool)
                                }
                            }
                        }
                        switch countBasedRetentionIsActive.value {
                        case .none:
                            if ObvMessengerSettings.Discussions.countBasedRetentionPolicyIsActive {
                                Stepper(onIncrement: countBasedRetentionIncrement,
                                        onDecrement: countBasedRetentionDecrement) {
                                    Text("KEEP_\(UInt(countBasedRetention.value))_MESSAGES")
                                }
                            } else {
                                EmptyView()
                            }
                        case .falseValue:
                            EmptyView()
                        case .trueValue:
                            Stepper(onIncrement: countBasedRetentionIncrement,
                                    onDecrement: countBasedRetentionDecrement) {
                                Text("KEEP_\(UInt(countBasedRetention.value))_MESSAGES")
                            }
                        }
                    }
                    Section(footer: Text("TIME_BASED_SINGLE_DISCUSSION_SECTION_FOOTER")) {
                        Picker(selection: timeBasedRetention.binding, label: Label("TIME_BASED_LABEL", systemImage: "calendar.badge.clock")) {
                            ForEach(DurationOptionAltOverride.allCases) { durationOverride in
                                switch durationOverride {
                                case .useAppDefault:
                                    let textAppDefault = ObvMessengerSettings.Discussions.timeBasedRetentionPolicy.description
                                    Text("\(durationOverride.description) (\(textAppDefault))").tag(durationOverride)
                                default:
                                    Text(durationOverride.description).tag(durationOverride)
                                }
                            }
                        }
                    }
                }
                /* EPHEMERAL MESSAGES - LOCAL CONFIG */
                Group {
                    Section {
                        VStack(alignment: .leading) {
                            Text("EPHEMERAL_MESSAGES")
                                .font(.headline)
                            Text("LOCAL_CONFIG")
                                .font(.callout)
                                .foregroundColor(Color(AppTheme.shared.colorScheme.secondaryLabel))
                        }
                        Text("LOCAL_EPHEMERAL_SETTINGS_EXPLANATION")
                            .font(.callout)
                    }
                    Section(footer: Text("AUTO_READ_SECTION_FOOTER")) {
                        Picker(selection: autoRead.binding, label: Label("AUTO_READ_LABEL", systemImage: "hand.tap.fill")) {
                            ForEach(OptionalBoolType.allCases) { optionalBool in
                                switch optionalBool {
                                case .none:
                                    let textAppDefault = ObvMessengerSettings.Discussions.autoRead ? CommonString.Word.Yes : CommonString.Word.No
                                    Text("\(CommonString.Word.Default) (\(textAppDefault))").tag(optionalBool)
                                case .trueValue:
                                    Text(CommonString.Word.Yes).tag(optionalBool)
                                case .falseValue:
                                    Text(CommonString.Word.No).tag(optionalBool)
                                }
                            }
                        }
                    }
                    Section(footer: Text("RETAIN_WIPED_OUTBOUND_MESSAGES_SECTION_FOOTER")) {
                        Picker(selection: retainWipedOutboundMessages.binding, label: Label("RETAIN_WIPED_OUTBOUND_MESSAGES_LABEL", systemImage: "trash.slash")) {
                            ForEach(OptionalBoolType.allCases) { optionalBool in
                                switch optionalBool {
                                case .none:
                                    let textAppDefault = ObvMessengerSettings.Discussions.retainWipedOutboundMessages ? CommonString.Word.Yes : CommonString.Word.No
                                    Text("\(CommonString.Word.Default) (\(textAppDefault))").tag(optionalBool)
                                case .trueValue:
                                    Text(CommonString.Word.Yes).tag(optionalBool)
                                case .falseValue:
                                    Text(CommonString.Word.No).tag(optionalBool)
                                }
                            }
                        }
                    }
                    /* SHARED SETTINGS FOR EPHEMERAL MESSAGES */
                    Section {
                        VStack(alignment: .leading) {
                            Text("EPHEMERAL_MESSAGES")
                                .font(.headline)
                            Text("SHARED_CONFIG")
                                .font(.callout)
                                .foregroundColor(Color(AppTheme.shared.colorScheme.secondaryLabel))
                        }
                        Text("EXPIRATION_SETTINGS_EXPLANATION")
                            .font(.callout)
                        if !sharedConfigCanBeModified {
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: "person.fill.questionmark")
                                Text("ONLY_GROUP_OWNER_CAN_MODIFY")
                            }.font(.callout)
                        }
                    }
                    Section(footer: Text("READ_ONCE_SECTION_FOOTER")) {
                        Toggle(isOn: readOnce.binding) {
                            Label("READ_ONCE_LABEL", systemImage: "flame.fill")
                        }.disabled(!sharedConfigCanBeModified)
                    }
                    Section(footer: Text("LIMITED_VISIBILITY_SECTION_FOOTER")) {
                        NavigationLink {
                            ExistenceOrVisibilityDurationView(timeInverval: visibilityDurationOption.binding)
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Label("LIMITED_VISIBILITY_LABEL", systemIcon: .eyes)
                                Spacer()
                                Text(verbatim: TimeInterval.formatForExistenceOrVisibilityDuration(timeInterval: visibilityDurationOption.binding.wrappedValue, unitsStyle: .short))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!sharedConfigCanBeModified)
                    }
                    Section(footer: Text("LIMITED_EXISTENCE_SECTION_FOOTER")) {
                        NavigationLink {
                            ExistenceOrVisibilityDurationView(timeInverval: existenceDurationOption.binding)
                        } label: {
                            HStack(alignment: .firstTextBaseline) {
                                Label("LIMITED_EXISTENCE_SECTION_LABEL", systemIcon: .timer)
                                Spacer()
                                Text(verbatim: TimeInterval.formatForExistenceOrVisibilityDuration(timeInterval: existenceDurationOption.binding.wrappedValue, unitsStyle: .short))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!sharedConfigCanBeModified)
                    }
                }
            }
            .navigationBarTitle(CommonString.Title.discussionSettings)
            .navigationBarItems(leading:
                                    Button(action: { dismissAction(nil) },
                                           label: {
                Image(systemIcon: .xmarkCircleFill)
                    .font(Font.system(size: 24, weight: .semibold, design: .default))
                    .foregroundColor(Color(AppTheme.shared.colorScheme.tertiaryLabel))
            })
            )
            .alert(isPresented: $showConfirmationMessageBeforeSavingSharedConfig) {
                Alert(title: Text("MODIFIED_SHARED_SETTINGS_CONFIRMATION_TITLE"),
                      message: Text("MODIFIED_SHARED_SETTINGS_CONFIRMATION_MESSAGE"),
                      primaryButton: Alert.Button.cancel(Text(CommonString.Word.Discard), action: {
                    dismissAction(false)
                }),
                      secondaryButton: Alert.Button.default(Text(CommonString.Word.Update), action: {
                    dismissAction(true)
                })
                )
            }
            .actionSheet(isPresented: $showingMuteActionSheet) {
                return ActionSheet(title: Text("MUTE_NOTIFICATIONS"),
                                   buttons: muteActionSheetButtons)
            }
        }
        .navigationViewStyle(StackNavigationViewStyle()) // Prevents split on iPad
    }

    private var muteActionSheetButtons: [ActionSheet.Button] {
        var buttons = [ActionSheet.Button]()
        buttons += MuteDurationOption.allCases.map { duration in
            return Alert.Button.default(
                Text(duration.description),
                action: {
                    muteNotificationsDuration.set(duration)
                    changed.toggle()
                })
        }
        buttons += [.cancel()]
        return buttons
    }
}



struct ChangeDefaultEmojiView: View {

    @Binding var defaultEmoji: String?
    @State private var showingEmojiPickerSheet = false

    var body: some View {
        Section {
            Button(action: {
                showingEmojiPickerSheet = true
            }) {
                HStack {
                    Image(systemIcon: .handThumbsup)
                        .foregroundColor(.blue)
                    Text("DEFAULT_EMOJI")
                        .foregroundColor(Color(AppTheme.shared.colorScheme.label))
                    Spacer()
                    if let defaultEmoji = defaultEmoji {
                        Text(defaultEmoji)
                            .foregroundColor(Color(AppTheme.shared.colorScheme.secondaryLabel))
                    } else {
                        Text("\(CommonString.Word.Default) (\(ObvMessengerSettings.Emoji.defaultEmojiButton ?? ObvMessengerConstants.defaultEmoji))")
                            .foregroundColor(Color(AppTheme.shared.colorScheme.secondaryLabel))
                    }
                }
            }
        }
        .sheet(isPresented: $showingEmojiPickerSheet) {
            EmojiPickerView(model: EmojiPickerViewModel(selectedEmoji: defaultEmoji) { emoji in
                self.defaultEmoji = emoji
                self.showingEmojiPickerSheet = false
            })
        }
    }
}


struct DiscussionExpirationSettingsView_Previews: PreviewProvider {

    static var previews: some View {
        Group {
            DiscussionExpirationSettingsView(
                changed: .constant(false),
                readOnce: ValueWithBinding(constant: false),
                autoRead: ValueWithBinding(constant: .falseValue),
                visibilityDurationOption: ValueWithBinding(constant: nil),
                existenceDurationOption: ValueWithBinding(constant: .init(days: 90)),
                retainWipedOutboundMessages: ValueWithBinding(constant: .falseValue),
                doSendReadReceipt: ValueWithBinding(constant: .none),
                mentionNotificationMode: ValueWithBinding(constant: .globalDefault),
                showConfirmationMessageBeforeSavingSharedConfig: .constant(false),
                countBasedRetentionIsActive: ValueWithBinding(constant: .none),
                countBasedRetention: ValueWithBinding(constant: 0),
                timeBasedRetention: ValueWithBinding(constant: .useAppDefault),
                muteNotificationsEndDate: nil,
                muteNotificationsDuration: ValueWithBinding(constant: .indefinitely),
                defaultEmoji: ValueWithBinding(constant: nil),
                notificationSound: ValueWithBinding(constant: .none),
                performInteractionDonation: ValueWithBinding(constant: .trueValue),
                sharedConfigCanBeModified: true,
                dismissAction: { _ in })
            DiscussionExpirationSettingsView(
                changed: .constant(false),
                readOnce: ValueWithBinding(constant: true),
                autoRead: ValueWithBinding(constant: .falseValue),
                visibilityDurationOption: ValueWithBinding(constant: .init(hours: 1)),
                existenceDurationOption: ValueWithBinding(constant: nil),
                retainWipedOutboundMessages: ValueWithBinding(constant: .trueValue),
                doSendReadReceipt: ValueWithBinding(constant: .trueValue),
                mentionNotificationMode: ValueWithBinding(constant: .alwaysNotifyWhenMentionned),
                showConfirmationMessageBeforeSavingSharedConfig: .constant(false),
                countBasedRetentionIsActive: ValueWithBinding(constant: .none),
                countBasedRetention: ValueWithBinding(constant: 0),
                timeBasedRetention: ValueWithBinding(constant: .none),
                muteNotificationsEndDate: Date.distantFuture,
                muteNotificationsDuration: ValueWithBinding(constant: .indefinitely),
                defaultEmoji: ValueWithBinding(constant: nil),
                notificationSound: ValueWithBinding(constant: .some(.busy)),
                performInteractionDonation: ValueWithBinding(constant: .falseValue),
                sharedConfigCanBeModified: false,
                dismissAction: { _ in })
        }
    }
}


struct ObvLabel: View {
    
    private let title: LocalizedStringKey
    private let symbolIcon: any SymbolIcon
    
    init(_ title: LocalizedStringKey, symbolIcon: any SymbolIcon) {
        self.title = title
        self.symbolIcon = symbolIcon
    }
        
    var body: some View {
        Label(
            title: {
                Text(title)
                    .foregroundStyle(.primary)
            },
            icon: {
                Image(symbolIcon: symbolIcon)
                    .foregroundColor(.secondary)
            }
        )
    }
    
}


struct ObvLabelAlt: View {
    
    let verbatim: String
    let symbolIcon: any SymbolIcon
    
    var body: some View {
        Label(
            title: {
                Text(verbatim: verbatim)
                    .foregroundStyle(.primary)
            },
            icon: {
                Image(symbolIcon: symbolIcon)
                    .foregroundColor(.secondary)
            }
        )
    }
    
}
