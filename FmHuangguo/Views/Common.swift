import SwiftUI

// MARK: - 网络封面图

struct NetImage: View {
    let urlString: String?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.92))
            if let urlString = urlString, let url = URL(string: urlString) {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure:
                        ZStack {
                            Color(white: 0.9)
                            Image(systemName: "photo").foregroundColor(.gray)
                        }
                    default:
                        ZStack {
                            Color(white: 0.94)
                            ProgressView()
                        }
                    }
                }
            } else {
                Image(systemName: "photo").foregroundColor(.gray)
            }
        }
    }
}

// MARK: - 错误重试

struct ErrorRetryView: View {
    let message: String
    var retryTitle: String = "重试"
    var extraActionTitle: String? = nil
    var extraAction: (() -> Void)? = nil
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 42))
                .foregroundColor(.gray)
            Text(message)
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button {
                    onRetry()
                } label: {
                    Text(retryTitle)
                        .font(.subheadline).fontWeight(.medium)
                        .padding(.horizontal, 28).padding(.vertical, 8)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(18)
                }
                if let title = extraActionTitle {
                    Button {
                        extraAction?()
                    } label: {
                        Text(title)
                            .font(.subheadline).fontWeight(.medium)
                            .padding(.horizontal, 20).padding(.vertical, 8)
                            .background(Color(white: 0.92))
                            .foregroundColor(.primary)
                            .cornerRadius(18)
                    }
                }
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 空状态

struct EmptyStateView: View {
    let icon: String
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 46))
                .foregroundColor(Color(white: 0.82))
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - 时间格式化

func fmtTime(_ t: Double) -> String {
    guard t.isFinite, t >= 0 else { return "0:00" }
    let s = Int(t.rounded())
    if s >= 3600 {
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
    return String(format: "%d:%02d", s / 60, s % 60)
}
