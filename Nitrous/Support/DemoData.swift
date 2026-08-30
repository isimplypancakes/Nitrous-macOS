import Foundation

#if DEBUG
/// Builds a fully-populated in-memory session so the UI can be exercised
/// without a live Discord login (which requires captcha-gated credentials).
extension AppModel {
    func loadDemo() {
        let me = DiscordUser(id: "1000", username: "you", globalName: "You",
                             discriminator: "0", avatar: nil)
        let alex = DiscordUser(id: "2001", username: "alex", globalName: "Alex Rivera", discriminator: "0", avatar: nil)
        let sam  = DiscordUser(id: "2002", username: "samko", globalName: "Sam", discriminator: "0", avatar: nil)
        let mod  = DiscordUser(id: "2003", username: "nova", globalName: "Nova", discriminator: "0", avatar: nil)
        let bot  = DiscordUser(id: "2004", username: "GameBot", globalName: "GameBot", discriminator: "0", avatar: nil, bot: true)

        [me, alex, sam, mod, bot].forEach { usersCache[$0.id] = $0 }
        user = me
        presences = ["2001": "online", "2002": "idle", "2003": "dnd", "2004": "online", "1000": "online"]

        func text(_ id: String, _ name: String, _ pos: Int, cat: String? = nil) -> Channel {
            Channel(id: id, type: .guildText, guildId: "g1", name: name, position: pos, parentId: cat)
        }
        let general = text("c1", "general", 1, cat: "cat1")
        let channels = [
            Channel(id: "cat1", type: .guildCategory, guildId: "g1", name: "TEXT CHANNELS", position: 0),
            general,
            text("c2", "off-topic", 2, cat: "cat1"),
            text("c3", "memes", 3, cat: "cat1"),
            Channel(id: "cat2", type: .guildCategory, guildId: "g1", name: "VOICE", position: 4),
            Channel(id: "v1", type: .guildVoice, guildId: "g1", name: "Lounge", position: 5, parentId: "cat2"),
            Channel(id: "v2", type: .guildVoice, guildId: "g1", name: "Gaming", position: 6, parentId: "cat2")
        ]
        let g1 = Guild(id: "g1", name: "Pixel Pals", icon: nil, ownerId: "2001",
                       channels: channels, memberCount: 128)
        let g2 = Guild(id: "g2", name: "Swift Devs", icon: nil, channels: [
            Channel(id: "d1", type: .guildText, guildId: "g2", name: "general", position: 0)
        ], memberCount: 3021)
        let g3 = Guild(id: "g3", name: "Study Hall", icon: nil, channels: [
            Channel(id: "e1", type: .guildText, guildId: "g3", name: "welcome", position: 0)
        ], memberCount: 44)
        guilds = [g1, g2, g3]
        channelsByGuild = ["g1": channels, "g2": g2.channels ?? [], "g3": g3.channels ?? []]

        dmChannels = [
            Channel(id: "dm1", type: .dm, name: nil, recipients: [alex]),
            Channel(id: "dm2", type: .dm, name: nil, recipients: [sam]),
            Channel(id: "dm3", type: .groupDM, name: "Weekend Squad", recipients: [alex, sam, mod])
        ]

        func msg(_ id: String, _ author: DiscordUser, _ content: String, minsAgo: Double, reactions: [Reaction]? = nil) -> Message {
            Message(id: id, channelId: "c1", author: author, content: content,
                    timestamp: DiscordTime.plainFormatter.string(from: Date().addingTimeInterval(-minsAgo * 60)),
                    reactions: reactions)
        }
        let thumbs = Reaction(count: 4, me: true, emoji: Emoji(id: nil, name: "👍"))
        let fire = Reaction(count: 2, me: false, emoji: Emoji(id: nil, name: "🔥"))
        messagesByChannel["c1"] = [
            msg("m1", alex, "yo, did everyone see the new build?", minsAgo: 42),
            msg("m2", sam, "yeah it's **so** much faster now 🚀", minsAgo: 41, reactions: [fire]),
            msg("m3", alex, "the swipe drawers feel exactly like the real app", minsAgo: 40),
            msg("m4", mod, "nice work. shipping account switching next", minsAgo: 33, reactions: [thumbs]),
            msg("m5", bot, "GG! Match starting in #Lounge in 5 minutes.", minsAgo: 20),
            msg("m6", me, "on my way, just finishing this message row layout", minsAgo: 3)
        ]
        messagesByChannel["dm1"] = [
            Message(id: "x1", channelId: "dm1", author: alex, content: "ping me when you push", timestamp: DiscordTime.plainFormatter.string(from: Date().addingTimeInterval(-3600)))
        ]
        selectedGuildID = "g1"
        selectedChannelID = "c1"
        gatewayState = .ready
        typingByChannel["c1"] = ["2002": Date()]
    }
}
#endif
