import Foundation
import UIKit
import CryptoKit
import SwiftUI
import CommonCrypto

// MARK: - 加密图片加载器
//
// 站点封面图通过 AES-128-CBC（NoPadding）加密传输（crypto-image 协议）：
//   - 密文 = AES-CBC 加密后的图片原始字节，key/iv 为 16 字节 UTF-8 字符串
//   - 部分图床（如 WebP 转码 CDN）返回明文，需先嗅探格式签名再决定是否解密
//   - 解密结果缓存到内存 + 磁盘（以 URL 去除 query 后的 SHA256 为键）

final class CryptoImageLoader {
    static let shared = CryptoImageLoader()

    // 协议快照（static/web/js/plugins/crypto-image-protocol.js）
    static let decryptKey = "f5d965df75336270"
    static let decryptIV = "97b60394abc2fbe1"

    private let memoryCache = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let ioQueue = DispatchQueue(label: "fmhuangguo.imageloader.io", qos: .userInitiated)
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private let inflightLock = NSLock()

    private var diskDir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("CoverCache", isDirectory: true)
    }

    private init() {
        memoryCache.countLimit = 400
        memoryCache.totalCostLimit = 80 * 1024 * 1024
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 30
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
    }

    static func diskKey(for urlString: String) -> String {
        // 去掉时效性 query（auth_key 会变，同一图片 path 不变）
        let path = URL(string: urlString)?.path ?? urlString
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 异步加载图片：内存 → 磁盘 → 网络（下载后自动判断是否需要解密）
    func load(_ urlString: String?) async -> UIImage? {
        guard let urlString = urlString, !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        let key = Self.diskKey(for: urlString) as NSString

        if let hit = memoryCache.object(forKey: key) { return hit }

        if let diskHit = readDisk(key: key as String) {
            memoryCache.setObject(diskHit, forKey: key, cost: diskHit.pixelCost)
            return diskHit
        }

        // 去重并发请求
        inflightLock.lock()
        if let existing = inflight[urlString] {
            inflightLock.unlock()
            return await existing.value
        }
        let task = Task<UIImage?, Never> { [weak self] in
            guard let self = self else { return nil }
            defer {
                self.inflightLock.lock()
                self.inflight[urlString] = nil
                self.inflightLock.unlock()
            }
            return await self.fetchAndDecode(url: url, key: key as String)
        }
        inflight[urlString] = task
        inflightLock.unlock()

        let image = await task.value
        if let image = image {
            memoryCache.setObject(image, forKey: key, cost: image.pixelCost)
        }
        return image
    }

    private func fetchAndDecode(url: URL, key: String) async -> UIImage? {
        var req = URLRequest(url: url)
        req.setValue(RouteService.ua, forHTTPHeaderField: "User-Agent")
        req.setValue(SiteAPI.shared.base + "/", forHTTPHeaderField: "Referer")
        let data: Data
        do {
            let (d, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200, !d.isEmpty else { return nil }
            data = d
        } catch {
            return nil
        }

        let plain: Data
        if Self.sniffPlainImageMime(data) != nil {
            plain = data
        } else {
            guard let decrypted = Self.aesDecrypt(data) else { return nil }
            plain = decrypted
        }

        guard let image = UIImage(data: plain) else { return nil }
        writeDisk(data: plain, key: key)
        return image
    }

    // MARK: 格式嗅探（与站点 worker.sniffPlainImageMime 对齐）

    static func sniffPlainImageMime(_ d: Data) -> String? {
        guard d.count >= 12 else { return nil }
        let b = [UInt8](d.prefix(12))
        func ascii(_ from: Int, _ to: Int) -> String {
            String(bytes: b[from..<to], encoding: .ascii) ?? ""
        }
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        if ascii(0, 4) == "RIFF" && ascii(8, 12) == "WEBP" { return "image/webp" }
        if b[0] == 0x89 && Array(b[1..<9]) == pngSignature { return "image/png" }
        if ascii(0, 6) == "GIF87a" || ascii(0, 6) == "GIF89a" { return "image/gif" }
        return nil
    }

    // MARK: AES-128-CBC NoPadding 解密（等效 worker.decryptSubtle 的 trick）

    static func aesDecrypt(_ cipher: Data) -> Data? {
        let keyData = Data(decryptKey.utf8)
        let ivData = Data(decryptIV.utf8)
        let blockSize = kCCBlockSizeAES128
        let keySize = kCCKeySizeAES128
        guard keyData.count == keySize, ivData.count == blockSize else { return nil }
        guard !cipher.isEmpty else { return nil }

        let len = cipher.count
        let alignedLen = (len + 15) & ~15

        // 输入补零到块对齐 + 追加一块由密文末块派生的合法 PKCS#7 填充块
        var buffer = Data(count: alignedLen + blockSize)
        buffer.replaceSubrange(0..<len, with: cipher)
        let lastBlockStart = alignedLen - blockSize
        let lastBlockData = buffer.subdata(in: lastBlockStart..<alignedLen)

        // padBlock = E(PKCS7_BLOCK ^ C[n])，即以 C[n] 为 IV 加密 PKCS7 常数块的首块输出
        let pkcs7 = Data(repeating: 0x10, count: 16)
        let xored = Data(zip(pkcs7, lastBlockData).map { $0 ^ $1 })
        guard let padBlock = Self.rawCBC(input: xored, key: keyData, iv: lastBlockData, encrypt: true),
              padBlock.count >= 16 else { return nil }
        buffer.replaceSubrange(alignedLen..<(alignedLen + 16), with: padBlock.prefix(16))

        guard let out = Self.rawCBC(input: buffer, key: keyData, iv: ivData, encrypt: false) else { return nil }
        return out.prefix(len)
    }

    private static func rawCBC(input: Data, key: Data, iv: Data, encrypt: Bool) -> Data? {
        var out = Data(count: input.count + kCCBlockSizeAES128)
        var outLen = 0
        let status = input.withUnsafeBytes { (inPtr: UnsafeRawBufferPointer) -> CCCryptorStatus in
            var ivMutable = iv
            return out.withUnsafeMutableBytes { (outPtr: UnsafeMutableRawBufferPointer) -> CCCryptorStatus in
                let keyPtr = key.withUnsafeBytes { UnsafeRawPointer($0).bindMemory(to: UInt8.self, capacity: key.count) }
                let ivPtr = ivMutable.withUnsafeMutableBytes { UnsafeRawPointer($0).bindMemory(to: UInt8.self, capacity: 16) }
                return CCCrypt(encrypt ? CCOperation(kCCEncrypt) : CCOperation(kCCDecrypt),
                               CCAlgorithm(kCCAlgorithmAES), 0, // CBC 模式（无 PKCS7 选项 = NoPadding）
                               keyPtr, key.count,
                               ivPtr,
                               inPtr.baseAddress, input.count,
                               outPtr.baseAddress, outPtr.count, &outLen)
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(outLen)
    }

    // MARK: 磁盘缓存

    private func readDisk(key: String) -> UIImage? {
        ioQueue.sync {
            let file = diskDir.appendingPathComponent(key)
            guard let data = try? Data(contentsOf: file), let img = UIImage(data: data) else { return nil }
            return img
        }
    }

    private func writeDisk(data: Data, key: String) {
        ioQueue.async {
            try? data.write(to: self.diskDir.appendingPathComponent(key), options: .atomic)
        }
    }

    func clearCache() {
        memoryCache.removeAllObjects()
        ioQueue.sync {
            try? FileManager.default.removeItem(at: diskDir)
            try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        }
    }
}

private extension UIImage {
    var pixelCost: Int {
        Int(size.width * size.height * scale * scale) + 64_000
    }
}

// MARK: - SwiftUI 图片视图（替代 AsyncImage，带骨架屏动效）

struct NetImage: View {
    let urlString: String?
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color(.secondarySystemBackground))
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if failed {
                Image(systemName: "photo")
                    .foregroundColor(Color(white: 0.78))
            } else {
                Color.clear.shimmer()
            }
        }
        .task(id: urlString) {
            if let img = await CryptoImageLoader.shared.load(urlString) {
                withAnimation(.easeOut(duration: 0.18)) {
                    image = img
                }
            } else {
                failed = true
            }
        }
    }
}

// MARK: - 骨架屏微光动效

struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    LinearGradient(colors: [.clear,
                                            Color.white.opacity(0.5),
                                            .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: geo.size.width * 0.55)
                        .offset(x: phase * geo.size.width * 1.5)
                }
                .allowsHitTesting(false)
            )
            .clipped()
            .onAppear {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) {
                    phase = 1
                }
            }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(Shimmer())
    }
}

// MARK: - 触感反馈

func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
    UIImpactFeedbackGenerator(style: style).impactOccurred()
}
