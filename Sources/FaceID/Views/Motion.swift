import SwiftUI

/// With Reduce Motion, movement becomes a short cross-fade.
enum Motion {
    static func animation(_ base: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : base
    }
}
