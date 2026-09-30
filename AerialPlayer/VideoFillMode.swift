import AVFoundation

enum VideoFillMode: String, CaseIterable {
    case aspectFit, aspectFill, resize

    var title: String {
        switch self {
        case .aspectFit: return "aspectFit（完整显示）"
        case .aspectFill: return "aspectFill（铺满裁切）"
        case .resize: return "resize（拉伸）"
        }
    }

    var gravity: AVLayerVideoGravity {
        switch self {
        case .aspectFit: return .resizeAspect
        case .aspectFill: return .resizeAspectFill
        case .resize: return .resize
        }
    }
}
