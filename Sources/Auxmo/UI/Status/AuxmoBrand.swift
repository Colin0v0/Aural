import AppKit
import SwiftUI

/// GitHub 地址来自构建时注入的更新仓库身份，不在源码里复制账号名。
enum AuxmoProjectLinks {
    static var repositoryURL: URL? {
        repositoryURL(repository: Bundle.main.object(
            forInfoDictionaryKey: "AuxmoUpdateRepository"
        ) as? String)
    }

    static func repositoryURL(repository: String?) -> URL? {
        guard let repository, !repository.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repository)")
    }
}

/// 这个类型只用于取得当前代码实际所在的 bundle。
/// 主程序与 SwiftPM 测试宿主会分别提供 `.app` 和 `.xctest` 资源目录。
private final class AuxmoBrandBundleToken {}

/// 平面标记直接来自用户提供的版本 2 图标，只抠出白色 A 与三层声波弧线，
/// 不再由代码临摹轮廓。
struct AuxmoBrandMark: View {
    var size: CGFloat = 18
    var tint: Color = PanelStyle.ink

    var body: some View {
        Image(nsImage: AuxmoBrandAsset.template)
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

enum AuxmoBrandAsset {
    /// 不读取 SwiftPM 生成的 Bundle.module；不同工具链对该入口查找资源包的位置不同。
    static let bundle: Bundle = {
        guard let resources = Bundle(for: AuxmoBrandBundleToken.self).resourceURL,
              let bundle = Bundle(url: resources.appendingPathComponent("Auxmo_Auxmo.bundle")) else {
            fatalError("缺少 Auxmo_Auxmo.bundle 资源包")
        }
        return bundle
    }()

    /// 资源缺失意味着构建不完整，直接暴露错误，不退回手绘或系统占位图标。
    static let template: NSImage = {
        guard let url = bundle.url(forResource: "AuxmoMarkTemplate", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            fatalError("缺少 AuxmoMarkTemplate.png 品牌标记资源")
        }
        image.isTemplate = true
        return image
    }()
}

/// 状态栏直接复用抠出的透明模板，系统负责按菜单栏明暗模式着色。
enum AuxmoStatusIcon {
    static func make(size: CGFloat = 18) -> NSImage {
        guard let image = AuxmoBrandAsset.template.copy() as? NSImage else {
            fatalError("无法复制 Auxmo 品牌标记模板")
        }
        image.size = NSSize(width: size, height: size)
        image.isTemplate = true
        return image
    }

    /// 设备图标使用系统符号并保持模板着色，自动适配菜单栏明暗外观。
    static func device(systemName: String, size: CGFloat = 15) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        guard let image = NSImage(systemSymbolName: systemName,
                                  accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            fatalError("缺少菜单栏设备图标：\(systemName)")
        }
        image.isTemplate = true
        return image
    }
}
