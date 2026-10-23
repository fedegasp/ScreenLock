//
//  LockView.swift
//  ScreenLock
//
//  Created by Federico Gasperini on 22/10/26.
//

import SwiftUI

struct LockView: View {
    @ObservedObject var coordinator: LockCoordinator
    @ObservedObject var preferences: Preferences

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.white)

                Text("Screen Locked", comment: "Title shown on the full-screen lock window.")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)

                Group {
                    switch coordinator.phase {
                    case .idle:
                        Text("Waiting for authentication…", comment: "Lock screen status before the authentication prompt appears.")
                    case .authenticating:
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                            Text("Verifying…", comment: "Lock screen status while the Touch ID/password prompt is on screen.")
                        }
                    case .failed(let message):
                        Text(message)
                            .multilineTextAlignment(.center)
                    }
                }
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.75))

                Group {
                    if coordinator.phase == .idle {
                        Text("Press ⌃⌥⌘L to unlock", comment: "Hint on the lock screen explaining how to bring up the authentication prompt.")
                    } else {
                        Text("Press ⌃⌥⌘L to try again", comment: "Hint on the lock screen explaining how to show the authentication prompt again.")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomLeading) {
            Toggle(isOn: $preferences.showsStatusItem) {
                Text("Show menu bar icon", comment: "Switch in the bottom-left corner of the lock screen that shows or hides the menu bar icon.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .toggleStyle(.checkbox)
            .controlSize(.large)
            .environment(\.colorScheme, .dark)
            .padding(24)
        }
    }
}
