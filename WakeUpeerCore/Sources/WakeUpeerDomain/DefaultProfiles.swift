import Foundation

/// Configuração inicial, criada no primeiro lançamento.
/// A partir daí o usuário edita pelas Preferências ou direto no `config.json`.
public enum DefaultProfiles {

    private static func app(_ bundleID: String, _ name: String, front: Bool = false) -> ProfileItem {
        ProfileItem(
            item: .application(bundleID: bundleID, displayName: name, path: nil),
            bringToFront: front
        )
    }

    public static func makeConfig() -> AppConfig {
        AppConfig(
            profiles: [work, weekdayEvening, weekend, lateNight],
            wakeThresholdHours: 4,
            launchDelayMilliseconds: 600
        )
    }

    /// Seg–sex, 08h–17h. Tolerância de 90 min cobre o dia em que o Mac liga atrasado.
    public static var work: Profile {
        Profile(
            name: "Trabalho",
            weekdays: Weekday.workdays,
            window: TimeWindow(from: 8, to: 17),
            items: [
                app("com.fortinet.FortiClient", "FortiClient"),
                app("com.tinyspeck.slackmacgap", "Slack"),
                app("com.microsoft.teams2", "Microsoft Teams"),
                app("com.microsoft.VSCode", "Visual Studio Code"),
                app("com.mitchellh.ghostty", "Ghostty", front: true),
            ],
            skipOnHoliday: true,
            priority: 10,
            graceMinutes: 90,
            symbolName: "briefcase"
        )
    }

    /// Seg–sex, 17h–23h.
    public static var weekdayEvening: Profile {
        Profile(
            name: "Noite de semana",
            weekdays: Weekday.workdays,
            window: TimeWindow(from: 17, to: 23),
            items: [
                app("com.spotify.client", "Spotify"),
                app("com.brave.Browser", "Brave Browser", front: true),
                app("com.hnc.Discord", "Discord"),
            ],
            priority: 5,
            graceMinutes: 30,
            symbolName: "moon"
        )
    }

    /// Sáb–dom, dia inteiro.
    public static var weekend: Profile {
        Profile(
            name: "Fim de semana",
            weekdays: Weekday.weekend,
            window: TimeWindow(startMinutes: 0, endMinutes: 0),  // dia inteiro
            items: [
                app("com.spotify.client", "Spotify"),
                app("com.hnc.Discord", "Discord"),
                app("com.brave.Browser", "Brave Browser", front: true),
            ],
            priority: 1,
            symbolName: "figure.walk"
        )
    }

    /// Todo dia, 23h–06h. Janela que atravessa a meia-noite.
    public static var lateNight: Profile {
        Profile(
            name: "Madrugada",
            weekdays: Weekday.everyDay,
            window: TimeWindow(from: 23, to: 6),
            items: [
                app("com.spotify.client", "Spotify"),
                app("md.obsidian", "Obsidian", front: true),
            ],
            priority: 8,
            symbolName: "moon.stars"
        )
    }
}
