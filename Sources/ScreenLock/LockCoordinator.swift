//
//  LockCoordinator.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 22/10/26.
//

import Combine
import Foundation

/// Shared observable state rendered by `LockView` while the screen is locked.
final class LockCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case authenticating
        case failed(String)
    }

    @Published var phase: Phase = .idle
}
