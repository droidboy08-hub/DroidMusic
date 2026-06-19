import SwiftUI
import AVFoundation

// MARK: - Native video surface (Phase 5)
//
// itag 18 is muxed (video + audio in one stream on one clock), so attaching an
// AVPlayerLayer to MusicPlayer's AVPlayer gives synced now-playing video for
// free — it cannot drift from the audio. Audio plays whether or not this view
// is on screen; this only renders the picture when `showVideo` is on.
struct VideoLayerView: UIViewRepresentable {
    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = MusicPlayer.shared.player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: PlayerLayerView, context: Context) {}
}

/// UIView whose backing layer IS an AVPlayerLayer (no manual frame syncing).
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
