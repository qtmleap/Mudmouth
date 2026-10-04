//
//  ContentId.swift
//  Mudmouth
//
//  Created by devonly on 2025/08/13.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Foundation

/// Nintendo Switch AppのコンテンツIDを定義する列挙型
public enum ContentId: Int64, CaseIterable, Codable, Identifiable {
    public var id: Int64 {
        rawValue
    }

    /// スプラトゥーン2
    case SP2 = 5_741_031_244_955_648
    /// スプラトゥーン3
    case SP3 = 4_834_290_508_791_808
    /// あつまれどうぶつの森
    case ACNH = 4_953_919_198_265_344
    /// スマッシュブラザーズ
    case SMSP = 5_598_642_853_249_024

    var description: String {
        NSLocalizedString("\(Self.self)_\(String(describing: self))".uppercased(), bundle: .module, comment: "")
    }
}
