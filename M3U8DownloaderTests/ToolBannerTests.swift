import AppKit
import SwiftUI
import Testing

@testable import M3U8Downloader

/// The banner sizes itself differently depending on what it is asked, and the window lays
/// itself out by asking. A banner whose height balloons for *some* proposals slides the whole
/// window's content out of view (see `ToolBanner`), so every proposal the layout might make is
/// checked, not just the width it ends up with.
@MainActor
struct ToolBannerTests {

    private func banner(title: String = "The N_m3u8DL-RE download engine was not found.")
        -> ToolBanner
    {
        ToolBanner(
            title: title, hasDetail: true, systemImage: "exclamationmark.octagon.fill",
            tint: .red, onShowDetail: {}, onCheckAgain: {})
    }

    private func heights(of view: ToolBanner) -> [(String, CGFloat)] {
        let controller = NSHostingController(rootView: view)
        var result: [(String, CGFloat)] = []
        for width in [60, 200, 400, 630, 1200, 4000] as [CGFloat] {
            let size = controller.sizeThatFits(in: CGSize(width: width, height: 100_000))
            result.append(("width \(Int(width))", size.height))
        }
        result.append(("fitting", controller.view.fittingSize.height))
        return result
    }

    @Test("The banner is a few dozen points tall at every width it may be offered")
    func heightIsBounded() {
        for (proposal, height) in heights(of: banner()) {
            #expect(height < 140, "\(proposal): \(height) pt")
        }
    }

    @Test("A long title still wraps to at most two lines, not a tall block")
    func longTitleIsBounded() {
        let long = String(
            repeating: "The N_m3u8DL-RE download engine was not found at the expected place. ",
            count: 6)
        for (proposal, height) in heights(of: banner(title: long)) {
            #expect(height < 140, "\(proposal): \(height) pt")
        }
    }

    @Test("It is the same height whether or not there are instructions to show")
    func detailDoesNotChangeTheHeight() {
        let with = banner()
        let without = ToolBanner(
            title: with.title, hasDetail: false, systemImage: with.systemImage, tint: with.tint,
            onShowDetail: {}, onCheckAgain: {})
        let a = NSHostingController(rootView: with).sizeThatFits(
            in: CGSize(width: 630, height: 100_000)
        ).height
        let b = NSHostingController(rootView: without).sizeThatFits(
            in: CGSize(width: 630, height: 100_000)
        ).height
        #expect(abs(a - b) < 1)
    }
}
