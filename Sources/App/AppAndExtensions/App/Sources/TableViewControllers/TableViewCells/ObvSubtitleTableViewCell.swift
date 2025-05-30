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

import ObvUI
import ObvUICoreData
import UIKit
import ObvUIObvCircledInitials
import ObvDesignSystem


class ObvSubtitleTableViewCell: UITableViewCell, ObvTableViewCellWithActivityIndicator {

    static let nibName = "ObvSubtitleTableViewCell"
    static let identifier = "ObvSubtitleTableViewCell"

    // Views

    @IBOutlet weak var circlePlaceholder: UIView! { didSet { circlePlaceholder.backgroundColor = .clear } }
    @IBOutlet weak var titleStackView: UIStackView!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var subtitleLabel: UILabel!
    @IBOutlet weak var mainStackView: UIStackView!
    @IBOutlet weak var activityIndicatorPlaceholder: UIView!
    var activityIndicator: UIView?
    private var titleChip: ObvChipLabel?
    
    // Constraints
    
    @IBOutlet weak var circlePlaceholderHeightConstraint: NSLayoutConstraint!
    private let defaultCirclePlaceholderHeight: CGFloat = 56.0
    
    // Vars

    var title: String = "" { didSet { setTitle(); refreshCircledInitials() } }
    var subtitle: String = "" { didSet { setSubtitle() } }
    var circledInitialsConfiguration: CircledInitialsConfiguration? { didSet { refreshCircledInitials() } }
    private var chipImageView: UIImageView?
    private var badgeView: DiscView?

    // Subviews set in awakeFromNib
    
    private let circledInitials = NewCircledInitialsView()

}


// MARK: - awakeFromNib

extension ObvSubtitleTableViewCell {
    
    override func awakeFromNib() {
        super.awakeFromNib()
                
        titleLabel.textColor = appTheme.colorScheme.label
        subtitleLabel.textColor = appTheme.colorScheme.secondaryLabel

        circlePlaceholder.addSubview(circledInitials)
        circledInitials.translatesAutoresizingMaskIntoConstraints = false
        circledInitials.pinAllSidesToSides(of: circlePlaceholder)
        
        activityIndicatorPlaceholder.backgroundColor = .clear
        
        prepareForReuse()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHidden = false
        circlePlaceholderHeightConstraint.constant = defaultCirclePlaceholderHeight
        removeChipLabelAndChipImageView()
        removeTitleChip()
        titleLabel.text = nil
        subtitleLabel.text = nil
        setDefaultSubtitleFont()
    }
    
}


// MARK: - Setting labels and texts

extension ObvSubtitleTableViewCell {
    
    private func setTitle() {
        titleLabel.text = title
    }
    
    private func refreshCircledInitials() {
        guard let circledInitialsConfiguration = circledInitialsConfiguration else { return }
        circledInitials.configure(with: circledInitialsConfiguration)
    }

    private func setSubtitle() {
        subtitleLabel.text = subtitle
    }
    
    func setChipLabel(text: String) {
        removeChipLabelAndChipImageView()
        let chipLabel = ObvChipLabel()
        chipLabel.text = text
        chipLabel.textColor = .white
        chipLabel.chipColor = AppTheme.appleBadgeRedColor
        chipLabel.widthAnchor.constraint(equalToConstant: chipLabel.intrinsicContentSize.width).isActive = true
        self.mainStackView.addArrangedSubview(chipLabel)
    }
    
    func removeChipLabelAndChipImageView() {
        if let chipLabel = self.mainStackView.arrangedSubviews.last as? ObvChipLabel {
            self.mainStackView.removeArrangedSubview(chipLabel)
            chipLabel.removeFromSuperview()
        }
        if let chipImageView = chipImageView {
            self.mainStackView.removeArrangedSubview(chipImageView)
            chipImageView.removeFromSuperview()
            self.chipImageView = nil
        }
    }
    
    func setChipImage(to image: UIImage, withBadge: Bool) {
        removeChipLabelAndChipImageView()
        self.chipImageView = UIImageView(image: image)
        self.chipImageView!.widthAnchor.constraint(equalToConstant: 30.0).isActive = true
        self.chipImageView!.heightAnchor.constraint(equalToConstant: 30.0).isActive = true
        self.chipImageView!.contentMode = .scaleAspectFit
        self.chipImageView!.tintColor = AppTheme.shared.colorScheme.secondaryLabel
        self.mainStackView.addArrangedSubview(self.chipImageView!)
        if withBadge {
            self.chipImageView!.layoutIfNeeded()
            self.badgeView = DiscView(frame: CGRect(x: self.chipImageView!.bounds.width-5, y: 0, width: 10, height: 10))
            self.badgeView!.color = .red
            self.badgeView?.backgroundColor = .clear
            self.chipImageView!.addSubview(self.badgeView!)
            self.badgeView!.layoutIfNeeded()
        }
    }
    
    
    func setChipCheckmark() {
        let checkmark = UIImage(systemName: "checkmark.circle.fill")!.withTintColor(.green, renderingMode: .alwaysOriginal)
        setChipImage(to: checkmark, withBadge: false)
    }

    func setChipMute() {
        let checkmark = UIImage(systemIcon: .moonZzzFill)!.withTintColor(.gray, renderingMode: .alwaysOriginal)
        setChipImage(to: checkmark, withBadge: false)
    }

    
    func setChipXmark() {
        let checkmark = UIImage(systemName: "xmark.circle.fill")!.withTintColor(.systemRed, renderingMode: .alwaysOriginal)
        setChipImage(to: checkmark, withBadge: false)
    }
    
    func removeTitleChip() {
        if self.titleChip != nil {
            titleStackView.removeArrangedSubview(self.titleChip!)
            self.titleChip!.removeFromSuperview()
            self.titleChip = nil
            self.setNeedsDisplay()
        }
    }


    func setTitleChip(text: String) {
        removeTitleChip()
        self.titleChip = ObvChipLabel()
        self.titleChip!.text = text
        self.titleChip!.textColor = ObvChipLabel.defaultTextColor
        titleStackView.addArrangedSubview(self.titleChip!)
    }


    func makeSubtitleItalic() {
        let fontDescriptor = subtitleLabel.font.fontDescriptor
        guard let newDescriptor = fontDescriptor.withSymbolicTraits(.traitItalic) else { assertionFailure(); return }
        subtitleLabel.font = UIFont(descriptor: newDescriptor, size: 0) // 0 means keep existing size
    }

    func setDefaultSubtitleFont() {
        subtitleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
    }
}
