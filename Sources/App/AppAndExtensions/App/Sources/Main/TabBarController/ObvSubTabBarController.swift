/*
 *  Olvid for iOS
 *  Copyright © 2019-2024 Olvid SAS
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

import UIKit
import ObvTypes
import ObvEngine
import ObvUICoreData

@available(iOS, deprecated: 18.0)
protocol ObvSubTabBarControllerDelegate: AnyObject {
    func middleButtonTapped(sourceView: UIView)
}


@available(iOS, deprecated: 18.0, message: "Under iOS 18, we use the new API for creating tabs. See ObvSubTabBarControllerNew.")
final class ObvSubTabBarController: UITabBarController, AnyObvUITabBarController, ObvSubTabBarDelegate {

    weak var obvDelegate: ObvSubTabBarControllerDelegate?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        let tabBar = ObvSubTabBar()
        tabBar.obvDelegate = self
        self.setValue(tabBar, forKey: "tabBar")
    }
    
    override func addChild(_ childController: UIViewController) {
        super.addChild(childController)
        if children.count == 2 {
            super.addChild(FakeMiddleChildViewController())
        }
    }
    
    func middleButtonTapped(sourceView: UIView) {
        obvDelegate?.middleButtonTapped(sourceView: sourceView)
    }
    

    @objc func dismissPresentedViewController() {
        presentedViewController?.dismiss(animated: true)
    }

}


@available(iOS, deprecated: 18.0)
fileprivate final class FakeMiddleChildViewController: UIViewController {
    
    override var tabBarItem: UITabBarItem! {
        get {
            let item = UITabBarItem(title: nil, image: nil, tag: -1)
            item.isEnabled = false
            return item
        }
        set {}
    }
    
}

@available(iOS, deprecated: 18.0)
fileprivate protocol ObvSubTabBarDelegate: AnyObject {
    func middleButtonTapped(sourceView: UIView)
}

@available(iOS, deprecated: 18.0)
fileprivate final class ObvSubTabBar: UITabBar {

    weak var obvDelegate: ObvSubTabBarDelegate?
    
    private var middleButton: BigTabbarButton = {
        let btn = BigTabbarButton()
        btn.startColor = UIColor(displayP3Red: 47/255.0, green: 101/255.0, blue: 245/255.0, alpha: 1.0)
        btn.endColor = UIColor(displayP3Red: 0/255.0, green: 68/255.0, blue: 201/255.0, alpha: 1.0)
        return btn
    }()

    override func awakeFromNib() {
        super.awakeFromNib()
        setupMiddleButton()
        configureAppearance()
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupMiddleButton()
        configureAppearance()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupMiddleButton()
        configureAppearance()
    }
    
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.isHidden {
            return super.hitTest(point, with: event)
        }
        
        let from = point
        let to = middleButton.center

        return sqrt((from.x - to.x) * (from.x - to.x) + (from.y - to.y) * (from.y - to.y)) <= middleButton.frame.size.height / 2 ? middleButton : super.hitTest(point, with: event)
    }
    
    func setupMiddleButton() {
        middleButton.translatesAutoresizingMaskIntoConstraints = false
        middleButton.addTarget(self, action: #selector(test), for: .touchUpInside)
        addSubview(middleButton)
        let constraints = [
            middleButton.widthAnchor.constraint(equalToConstant: BigTabbarButton.radius),
            middleButton.heightAnchor.constraint(equalToConstant: BigTabbarButton.radius),
            middleButton.centerXAnchor.constraint(equalTo: self.centerXAnchor),
            middleButton.centerYAnchor.constraint(equalTo: self.topAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
    }
    
    func configureAppearance() {
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundEffect = UIBlurEffect(style: .prominent)
        self.standardAppearance = tabBarAppearance
        UITabBar.appearance().tintColor = appTheme.colorScheme.olvidDark
    }

    @objc func test() {
        obvDelegate?.middleButtonTapped(sourceView: middleButton)
    }
    
}


@available(iOS, deprecated: 18.0)
fileprivate final class BigTabbarButton: UIButton {
    
    static let radius: CGFloat = 50
    
    init() {
        super.init(frame: .zero)
        initialSetup()
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        initialSetup()
    }
    
    private func initialSetup() {
        
        self.frame.size = CGSize(width: 50, height: 50)
        self.backgroundColor = .blue
        self.layer.cornerRadius = 25
        self.layer.masksToBounds = false
        self.center = CGPoint(x: UIScreen.main.bounds.width / 2, y: 0)
        
        self.layer.shadowPath = UIBezierPath(
            arcCenter: CGPoint(x: self.frame.width/2, y: self.frame.height/2),
            radius: max(self.frame.width, self.frame.height)/2,
            startAngle: 0,
            endAngle: 2*CGFloat.pi,
            clockwise: true
        ).cgPath
        self.layer.shadowColor = UIColor.black.cgColor
        self.layer.shadowOpacity = 0.2
        self.layer.shadowOffset = CGSize(width: 0, height: 1)
        self.layer.shadowRadius = 4
        
        self.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 24.0, weight: .bold)), for: .normal)
        self.tintColor = .white

    }
    
    internal var cgColorGradient: [CGColor]? {
        guard let startColor = startColor, let endColor = endColor else {
            return nil
        }
        
        return [startColor.cgColor, endColor.cgColor]
    }

    var gradientLayer: CAGradientLayer {
        return layer as! CAGradientLayer
    }

    override public class var layerClass: AnyClass {
        return CAGradientLayer.classForCoder()
    }
    
    @IBInspectable var startColor: UIColor? {
        didSet { gradientLayer.colors = cgColorGradient }
    }

    @IBInspectable var endColor: UIColor? {
        didSet { gradientLayer.colors = cgColorGradient }
    }

    @IBInspectable var startPoint: CGPoint = CGPoint(x: 0.0, y: 0.0) {
        didSet { gradientLayer.startPoint = startPoint }
    }

    @IBInspectable var endPoint: CGPoint = CGPoint(x: 1.0, y: 1.0) {
        didSet { gradientLayer.endPoint = endPoint }
    }

    override var isSelected: Bool {
        didSet {
            debugPrint(isSelected)
        }
    }
    
}
