import Foundation

/// One desktop with a job: a name, a color and the things that belong on it
/// (docs/designs/desktop-roles.md). Desktops are numbered the way Mission Control numbers them,
/// across screens when "Displays have separate Spaces" is on, so a role lives on one screen.
public struct DesktopRole: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    /// "#RRGGBB": the menu bar tag, the panel badge, and the colorable backgrounds.
    public var colorHex: String
    /// What the desktop's wallpaper shows under the role name.
    public var background: RoleBackground
    /// 1...9, the Switch to Desktop N shortcuts macOS offers.
    public var desktopNumber: Int
    public var items: [RoleItem]

    public static let desktopNumbers = 1...9

    public init(id: UUID = UUID(), name: String, colorHex: String, background: RoleBackground = .colored(.radial),
                desktopNumber: Int, items: [RoleItem] = []) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.background = background
        self.desktopNumber = desktopNumber
        self.items = items
    }

    private enum CodingKeys: String, CodingKey { case id, name, colorHex, background, desktopNumber, items }

    /// Roles saved before backgrounds existed get Apple's Radial in their color.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        colorHex = try c.decode(String.self, forKey: .colorHex)
        background = try c.decodeIfPresent(RoleBackground.self, forKey: .background) ?? .colored(.radial)
        desktopNumber = try c.decode(Int.self, forKey: .desktopNumber)
        items = try c.decode([RoleItem].self, forKey: .items)
    }

    /// Desktop numbers used by more than one role, or outside 1...9. Settings refuses both.
    public static func invalidDesktopNumbers(in roles: [DesktopRole]) -> Set<Int> {
        var seen: Set<Int> = []
        var invalid: Set<Int> = []
        for role in roles {
            if !desktopNumbers.contains(role.desktopNumber) || !seen.insert(role.desktopNumber).inserted {
                invalid.insert(role.desktopNumber)
            }
        }
        return invalid
    }
}

/// A role's wallpaper: a style drawn in the role color, or a picture. The role name goes on top
/// of either, because a menu bar item looks the same on every screen.
public enum RoleBackground: Codable, Hashable, Sendable {
    case colored(BackgroundStyle)
    /// A picture file (any image macOS opens, the system wallpapers included). The role color
    /// still marks the tag and the panel badge.
    case image(path: String)

    public var style: BackgroundStyle? {
        if case .colored(let style) = self { return style }
        return nil
    }

    public var imagePath: String? {
        if case .image(let path) = self { return path }
        return nil
    }
}

/// Wallpapers drawn from the role color alone, so changing the color recolors them.
public enum BackgroundStyle: String, Codable, CaseIterable, Hashable, Sendable {
    /// Apple's Radial wallpaper (macOS ships Radial Sky Blue), turned to the role color.
    case radial
    /// The color, flat.
    case solid

    public var title: String {
        switch self {
        case .radial: return "Radial"
        case .solid: return "Solid"
        }
    }

    /// A style this version does not know (an earlier build had more) becomes Radial, so the
    /// roles still load.
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .radial
    }
}

/// Something a role opens on its desktop.
public enum RoleItem: Codable, Hashable, Sendable {
    /// A Mac app by bundle identifier.
    case app(bundleID: String)
    /// A Chrome window of one profile. `profileName` is the name Chrome shows for the profile
    /// (Local State), which Chrome puts in the window title: "Claude - Google Chrome - Sam (floo.one)".
    case chrome(profileDirectory: String, profileName: String, urls: [String])

    public static let chromeBundleID = "com.google.Chrome"

    public var bundleID: String {
        switch self {
        case .app(let bundleID): return bundleID
        case .chrome: return Self.chromeBundleID
        }
    }
}

/// A standard window on a desktop that is showing, as Accessibility reports it. Popups, sheets
/// and helper windows are left out by the inventory (spike, 2026-11-04).
public struct DesktopWindow: Hashable, Sendable {
    public var id: UInt32
    public var bundleID: String
    public var title: String

    public init(id: UInt32, bundleID: String, title: String) {
        self.id = id
        self.bundleID = bundleID
        self.title = title
    }

    /// The Chrome profile name in the title, nil when the title does not carry one (a single-profile
    /// Chrome, or a window that is not a browser window).
    public var chromeProfileName: String? {
        guard let range = title.range(of: " - Google Chrome - ", options: .backwards) else { return nil }
        let person = title[range.upperBound...]
        guard person.hasSuffix(")"), let open = person.lastIndex(of: "(") else { return nil }
        let name = person[person.index(after: open)..<person.index(before: person.endIndex)]
        return name.isEmpty ? nil : String(name)
    }
}

/// What one desktop holds right now. Apps in `unreadable` did not answer Accessibility in time,
/// so their part of the inventory is incomplete (eng review D7, D8b).
public struct DesktopInventory: Hashable, Sendable {
    public var windows: [DesktopWindow]
    public var unreadable: Set<String>

    public init(windows: [DesktopWindow] = [], unreadable: Set<String> = []) {
        self.windows = windows
        self.unreadable = unreadable
    }
}

/// Where an app's real windows are across all desktops (window list, not Accessibility).
public struct AppWindows: Hashable, Sendable {
    public var isRunning: Bool
    /// Desktops holding at least one real window of the app.
    public var desktops: Set<Int>
    /// Real windows whose desktop cannot be told (minimized ones, for example).
    public var hasUnplacedWindows: Bool

    public init(isRunning: Bool, desktops: Set<Int> = [], hasUnplacedWindows: Bool = false) {
        self.isRunning = isRunning
        self.desktops = desktops
        self.hasUnplacedWindows = hasUnplacedWindows
    }

    public static let notRunning = AppWindows(isRunning: false)
}

/// Why an item was left alone. Each one is shown in the report.
public enum UnresolvedReason: Hashable, Sendable {
    /// The app's windows are on other desktops; opening it would only jump there (macOS cannot
    /// move a window between desktops).
    case openOnAnotherDesktop([Int])
    /// The app did not answer Accessibility within 0.5 s.
    case notResponding
    /// Some of the app's windows could not be placed, so absence cannot be proven (D8b).
    case couldNotCheck
    /// A Chrome window on this desktop does not say which profile it belongs to.
    case checkProfile
    /// Launched, but no window showed up in time. Never relaunched in the same walk.
    case didNotAppear
    /// The window showed up somewhere it could not be moved from.
    case landedElsewhere
    /// The role's desktop does not exist: create it in Mission Control.
    case missingDesktop
    /// Control+N did not bring the desktop up within 2 s.
    case switchFailed
    /// You switched desktops twice during the walk, so it stopped (D4).
    case stoppedBecauseYouSwitched
    /// The walk was cancelled before it reached this item.
    case cancelled
    /// The app failed to open.
    case launchFailed(String)
}

/// What the planner decides for one item on the desktop being set up.
public enum ItemPlan: Hashable, Sendable {
    case alreadyThere
    case open
    case unresolved(UnresolvedReason)
}

/// Opens only what is missing and never guesses (eng review D8b): an item is opened only when
/// the inventory proves it absent.
public enum LaunchPlanner {
    public static func plan(_ item: RoleItem, desktop: Int, inventory: DesktopInventory, appWindows: AppWindows) -> ItemPlan {
        if inventory.unreadable.contains(item.bundleID) { return .unresolved(.notResponding) }
        let here = inventory.windows.filter { $0.bundleID == item.bundleID }
        switch item {
        case .app:
            if !here.isEmpty { return .alreadyThere }
            if !appWindows.isRunning { return .open }
            if appWindows.hasUnplacedWindows { return .unresolved(.couldNotCheck) }
            let elsewhere = appWindows.desktops.subtracting([desktop])
            if !elsewhere.isEmpty { return .unresolved(.openOnAnotherDesktop(elsewhere.sorted())) }
            // Running with no window anywhere: opening it again shows its window here.
            return .open
        case .chrome(_, let profileName, _):
            if here.contains(where: { $0.chromeProfileName == profileName }) { return .alreadyThere }
            if here.contains(where: { $0.chromeProfileName == nil }) { return .unresolved(.checkProfile) }
            // Windows of other profiles here or anywhere do not count: a new window always opens.
            return .open
        }
    }
}
