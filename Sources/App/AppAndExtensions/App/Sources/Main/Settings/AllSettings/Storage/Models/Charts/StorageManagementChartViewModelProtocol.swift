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

import Foundation
import SwiftUI

protocol StorageManagementChartViewModelProtocol {

    var formattedTotalBytes: String { get }
    
    var storageCharts: [StorageChart] { get }
    
    var chartForegroundStyleScale: [Color] { get }
}

///
/// Structure to represent a value in a Chart.
///  Should be identifiable and the model have the same type `Storage` in order to be displayed in a single BarMark
struct StorageChart: Identifiable, Equatable {
    
    let id = UUID().uuidString
    let name: String
    let value: Int
    
    init(name: String, value: Int) {
        self.name = name
        self.value = value
    }
}
