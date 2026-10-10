import SwiftUI
import AVFoundation

/// Hosts the decoder's output layer. The layer is sized to the view (which SwiftUI keeps inside the safe area).
struct DisplayLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    func makeUIView(context: Context) -> LayerHostView { LayerHostView(layer: layer) }
    func updateUIView(_ uiView: LayerHostView, context: Context) {}
}

final class LayerHostView: UIView {
    private let displayLayer: AVSampleBufferDisplayLayer
    init(layer: AVSampleBufferDisplayLayer) {
        displayLayer = layer
        super.init(frame: .zero)
        backgroundColor = .black
        isOpaque = true
        self.layer.addSublayer(layer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}
