import Foundation

/// Minimal `:shortcode:` → emoji table so the composer can convert the same
/// `:sob:`-style names Discord shows in the emoji panel. Only literal text
/// outside code is converted at render time; anything not in the table stays
/// as-is so guild-specific `:custom:` names are never mangled.
enum EmojiShortcodes {
    static func expand(in text: String) -> String {
        guard text.contains(":") else { return text }
        guard let re = try? NSRegularExpression(pattern: #":([A-Za-z0-9_+\-]+):"#) else { return text }
        let ns = text as NSString
        var replacements: [(NSRange, String)] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            if let emoji = table[name] {
                replacements.append((m.range, emoji))
            }
        }
        guard !replacements.isEmpty else { return text }
        var result = text as NSString
        for (range, emoji) in replacements.reversed() {
            result = result.replacingCharacters(in: range, with: emoji) as NSString
        }
        return result as String
    }

    /// All known shortcodes, sorted — used by the reaction emoji picker.
    static var all: [(shortcode: String, emoji: String)] {
        table.map { ($0.key, $0.value) }.sorted { $0.shortcode < $1.shortcode }
    }

    private static let table: [String: String] = {
        var t: [String: String] = [:]
        for pair in rawPairs {
            if t[pair.0] == nil { t[pair.0] = pair.1 }
        }
        return t
    }()

    /// Source pairs, held as tuples so a stray duplicate key inside the table
    /// can never trap at runtime (dictionary literals assert on duplicates).
    /// First occurrence wins; last one is dropped.
    private static let rawPairs: [(String, String)] = [
        ("sob", "😭"), ("joy", "😂"), ("laughing", "😆"), ("slight_smile", "🙂"),
        ("smile", "😄"), ("smiley", "😃"), ("grin", "😁"), ("rofl", "🤣"),
        ("sweat_smile", "😅"), ("laugh", "😆"), ("wink", "😉"), ("blush", "😊"),
        ("yum", "😋"), ("sunglasses", "😎"), ("heart_eyes", "😍"), ("kissing_heart", "😘"),
        ("kissing", "😗"), ("kissing_smiling_eyes", "😙"), ("kissing_closed_eyes", "😚"),
        ("relaxed", "☺️"), ("relieved", "😌"), ("pensive", "😔"), ("sleepy", "😪"),
        ("sleeping", "😴"), ("worried", "😟"), ("frowning", "😦"), ("anguished", "😧"),
        ("open_mouth", "😮"), ("hushed", "😯"), ("astonished", "😲"), ("flushed", "😳"),
        ("expressionless", "😑"), ("neutral_face", "😐"), ("confused", "😕"),
        ("confounded", "😖"), ("persevere", "😣"), ("disappointed", "😞"),
        ("tired_face", "😫"), ("weary", "😩"), ("fearful", "😨"), ("cry", "😢"),
        ("sweat", "😓"), ("cold_sweat", "😰"), ("scream", "😱"), ("angry", "😠"),
        ("rage", "😡"), ("triumph", "😤"), ("smirk", "😏"), ("unamused", "😒"),
        ("grinning", "😀"), ("grimacing", "😬"), ("nerd", "🤓"), ("eyes", "👀"),
        ("eye", "👁️"), ("rolling_eyes", "🙄"), ("thinking", "🤔"), ("zipper_mouth", "🤐"),
        ("money_mouth", "🤑"), ("stuck_out_tongue", "😛"), ("stuck_out_tongue_winking_eye", "😜"),
        ("stuck_out_tongue_closed_eyes", "😝"), ("drooling_face", "🤤"),
        ("face_with_monocle", "🧐"), ("lying_face", "🤥"), ("no_mouth", "😶"),
        ("facepalm", "🤦"), ("shrug", "🤷"), ("wave", "👋"), ("raised_hand", "✋"),
        ("ok_hand", "👌"), ("thumbsup", "👍"), ("+1", "👍"), ("thumbsdown", "👎"),
        ("-1", "👎"), ("clap", "👏"), ("pray", "🙏"), ("fist", "✊"), ("rocket", "🚀"),
        ("point_up", "☝️"), ("muscle", "💪"), ("flexed_biceps", "💪"), ("v", "✌️"),
        ("victory", "✌️"), ("handshake", "🤝"), ("raised_hands", "🙌"), ("punch", "👊"),
        ("collision", "💥"), ("boom", "💥"), ("100", "💯"), ("fire", "🔥"), ("hot", "🔥"),
        ("sparkles", "✨"), ("star", "⭐"), ("star2", "🌟"), ("dizzy", "💫"),
        ("hearts", "💖"), ("heart", "❤️"), ("red_heart", "❤️"), ("purple_heart", "💜"),
        ("blue_heart", "💙"), ("green_heart", "💚"), ("yellow_heart", "💛"),
        ("orange_heart", "🧡"), ("black_heart", "🖤"), ("white_heart", "🤍"),
        ("broken_heart", "💔"), ("heartbeat", "💓"), ("heartpulse", "💗"),
        ("two_hearts", "💕"), ("revolving_hearts", "💞"), ("cupid", "💘"),
        ("sparkling_heart", "💖"), ("gift_heart", "💝"), ("kiss", "💋"),
        ("smiling_imp", "😈"), ("imp", "👿"), ("alien", "👽"), ("ghost", "👻"),
        ("skull", "💀"), ("poop", "💩"), ("hankey", "💩"), ("clown_face", "🤡"),
        ("robot", "🤖"), ("cat", "🐱"), ("dog", "🐶"), ("mouse", "🐭"), ("hamster", "🐹"),
        ("rabbit", "🐰"), ("bear", "🐻"), ("panda_face", "🐼"), ("koala", "🐨"),
        ("tiger", "🐯"), ("lion", "🦁"), ("cow", "🐮"), ("pig", "🐷"), ("frog", "🐸"),
        ("monkey_face", "🐵"), ("chicken", "🐔"), ("penguin", "🐧"), ("bird", "🐦"),
        ("baby chick", "🐤"), ("hatching_chick", "🐣"), ("duck", "🦆"), ("eagle", "🦅"),
        ("owl", "🦉"), ("bat", "🦇"), ("wolf", "🐺"), ("fox_face", "🦊"),
        ("unicorn", "🦄"), ("horse", "🐴"), ("euro", "💶"), ("bee", "🐝"),
        ("bug", "🐛"), ("butterfly", "🦋"), ("snail", "🐌"), ("turtle", "🐢"),
        ("snake", "🐍"), ("dragon", "🐉"), ("whale", "🐳"), ("dolphin", "🐬"),
        ("fish", "🐟"), ("octopus", "🐙"), ("crab", "🦀"), ("shrimp", "🦐"),
        ("shell", "🐚"), ("cactus", "🌵"), ("evergreen_tree", "🌲"), ("deciduous_tree", "🌳"),
        ("palm_tree", "🌴"), ("leaves", "🍃"), ("cherry_blossom", "🌸"),
        ("rose", "🌹"), ("hibiscus", "🌺"), ("sunflower", "🌻"), ("blossom", "🌼"),
        ("tulip", "🌷"), ("seedling", "🌱"), ("herb", "🌿"), ("mushroom", "🍄"),
        ("earth_africa", "🌍"), ("earth_americas", "🌎"), ("earth_asia", "🌏"),
        ("full_moon", "🌕"), ("new_moon", "🌑"), ("star_wars", "🌌"),
        ("sunny", "☀️"), ("cloud", "☁️"), ("rainbow", "🌈"), ("umbrella", "☔"),
        ("snowflake", "❄️"), ("zap", "⚡"), ("droplet", "💧"),
        ("sweat_drops", "💦"), ("ocean", "🌊"), ("pizza", "🍕"),
        ("hamburger", "🍔"), ("fries", "🍟"), ("hotdog", "🌭"), ("taco", "🌮"),
        ("burrito", "🌯"), ("sushi", "🍣"), ("bento", "🍱"), ("ramen", "🍜"),
        ("spaghetti", "🍝"), ("cake", "🍰"), ("birthday", "🎂"), ("cookie", "🍪"),
        ("chocolate_bar", "🍫"), ("candy", "🍬"), ("lollipop", "🍭"),
        ("icecream", "🍦"), ("shaved_ice", "🍧"), ("donut", "🍩"), ("apple", "🍎"),
        ("banana", "🍌"), ("watermelon", "🍉"), ("grapes", "🍇"), ("strawberry", "🍓"),
        ("orange", "🍊"), ("lemon", "🍋"), ("peach", "🍑"), ("cherries", "🍒"),
        ("corn", "🌽"), ("eggplant", "🍆"), ("bread", "🍞"), ("cheese", "🧀"),
        ("egg", "🥚"), ("cupcake", "🧁"), ("coffee", "☕"), ("tea", "🍵"),
        ("sake", "🍶"), ("wine_glass", "🍷"), ("beer", "🍺"), ("beers", "🍻"),
        ("cocktail", "🍸"), ("tropical_drink", "🍹"), ("champagne", "🥂"),
        ("party", "🎉"), ("tada", "🎉"), ("confetti_ball", "🎊"),
        ("balloon", "🎈"), ("gift", "🎁"), ("crown", "👑"), ("ring", "💍"),
        ("gem", "💎"), ("moneybag", "💰"), ("dollar", "💵"), ("credit_card", "💳"),
        ("trophy", "🏆"), ("medal", "🏅"), ("first_place", "🥇"), ("second_place", "🥈"),
        ("third_place", "🥉"), ("soccer", "⚽"), ("basketball", "🏀"),
        ("football", "🏈"), ("baseball", "⚾"), ("tennis", "🎾"), ("bowling", "🎳"),
        ("golf", "⛳"), ("ski", "🎿"), ("video_game", "🎮"), ("joystick", "🕹️"),
        ("game_die", "🎲"), ("dart", "🎯"), ("slot_machine", "🎰"), ("8ball", "🎱"),
        ("movie_camera", "🎥"), ("film_strip", "🎞️"), ("tv", "📺"), ("radio", "📻"),
        ("computer", "💻"), ("laptop", "💻"), ("iphone", "📱"), ("keyboard", "⌨️"),
        ("email", "✉️"), ("envelope", "✉️"), ("love_letter", "💌"), ("postbox", "📮"),
        ("telephone", "☎️"), ("fax", "📠"), ("printer", "🖨️"), ("alarm_clock", "⏰"),
        ("hourglass", "⌛"), ("calendar", "📅"), ("memo", "📝"), ("pencil2", "✏️"),
        ("book", "📖"), ("books", "📚"), ("newspaper", "📰"), ("scissors", "✂️"),
        ("paperclip", "📎"), ("pushpin", "📌"), ("link", "🔗"), ("lock", "🔒"),
        ("unlock", "🔓"), ("key", "🔑"), ("hammer", "🔨"), ("wrench", "🔧"),
        ("gear", "⚙️"), ("nut_and_bolt", "🔩"), ("compass", "🧭"), ("flashlight", "🔦"),
        ("battery", "🔋"), ("electric_plug", "🔌"), ("bulb", "💡"), ("mag", "🔍"),
        ("mag_right", "🔎"), ("hourglass_flowing_sand", "⏳"), ("watch", "⌚"),
        ("warning", "⚠️"), ("exclamation", "❗"), ("question", "❓"),
        ("white_check_mark", "✅"), ("heavy_check_mark", "✔️"), ("x", "❌"),
        ("negative_squared_cross_mark", "❎"), ("red_circle", "🔴"), ("blue_circle", "🔵"),
        ("white_circle", "⚪"), ("black_circle", "⚫"), ("orange_circle", "🟠"),
        ("yellow_circle", "🟡"), ("green_circle", "🟢"), ("purple_circle", "🟣"),
        ("brown_circle", "🟤"), ("red_square", "🟥"), ("blue_square", "🟦"),
        ("arrow_up", "⬆️"), ("arrow_down", "⬇️"), ("arrow_left", "⬅️"),
        ("arrow_right", "➡️"), ("arrow_up_down", "↕️"), ("left_right_arrow", "↔️"),
        ("arrows_clockwise", "🔃"), ("repeat", "🔁"), ("repeat_one", "🔂"),
        ("play", "▶️"), ("pause", "⏸️"), ("stop", "⏹️"), ("fast_forward", "⏩"),
        ("rewind", "⏪"), ("arrow_forward", "▶️"), ("arrow_backward", "◀️"),
        ("top", "🔝"), ("end", "🔚"), ("back", "🔙"), ("soon", "🔜"), ("on", "🔛"),
        ("new", "🆕"), ("up", "🆙"), ("cool", "🆒"), ("free", "🆓"), ("ng", "🆖"),
        ("ab", "🆎"), ("cl", "🆑"), ("ok", "🆗"), ("sos", "🆘"), ("m", "Ⓜ️"),
        ("no_entry", "⛔"), ("no_smoking", "🚭"), ("mens", "🚹"), ("womens", "🚺"),
        ("wheelchair", "♿"), ("wc", "🚾"), ("potable_water", "🚰"), ("restroom", "🚻"),
        ("baby", "👶"), ("boy", "👦"), ("girl", "👧"), ("man", "👨"), ("woman", "👩"),
        ("older_man", "👴"), ("older_woman", "👵"), ("couple", "👫"), ("family", "👨‍👩‍👧"),
        ("princess", "👸"), ("queen", "👸"), ("dancer", "💃"), ("call_me_hand", "🤙"),
        ("raised_back_of_hand", "🤚"), ("middle_finger", "🖕"), ("fu", "🖕"),
        ("index_pointing_up", "👆"), ("point_up_2", "👆"), ("point_down", "👇"),
        ("point_left", "👈"), ("point_right", "👉"), ("nail_care", "💅"),
        ("crystal_ball", "🔮"), ("game", "🎮"), ("magic_wand", "🪄"),
        ("hammer_and_wrench", "🛠️"), ("construction", "🚧"), ("traffic_light", "🚦"),
        ("rotating_light", "🚨"), ("ambulance", "🚑"), ("fire_engine", "🚒"),
        ("police_car", "🚓"), ("taxi", "🚕"), ("red_car", "🚗"), ("blue_car", "🚙"),
        ("bus", "🚌"), ("truck", "🚚"), ("airplane", "✈️"), ("helicopter", "🚁"),
        ("satellite", "🛰️"), ("anchor", "⚓"), ("boat", "⛵"),
        ("ferry", "⛴️"), ("speedboat", "🚤"), ("ship", "🚢"), ("ticket", "🎫"),
        ("clapper", "🎬"), ("art", "🎨"), ("palette", "🎨"), ("paintbrush", "🖌️"),
        ("violin", "🎻"), ("guitar", "🎸"), ("musical_note", "🎵"), ("notes", "🎶"),
        ("microphone", "🎤"), ("musical_keyboard", "🎹"), ("drum", "🥁"),
        ("saxophone", "🎷"), ("trumpet", "🎺"), ("dna", "🧬"), ("microscope", "🔬"),
        ("telescope", "🔭"), ("satellite_antenna", "📡"), ("test_tube", "🧪"),
        ("atom_symbol", "⚛️"), ("crossed_swords", "⚔️"), ("shield", "🛡️"),
        ("dizzy_face", "😵"), ("slightly_frowning_face", "🙁"),
        ("face_with_head_bandage", "🤕"), ("face_with_thermometer", "🤒"),
        ("cowboy_hat_face", "🤠"), ("partying_face", "🥳"), ("pleading_face", "🥺"),
        ("hot_face", "🥵"), ("cold_face", "🥶"), ("yawning_face", "🥱"),
        ("face_with_hand_over_mouth", "🤭"), ("shushing_face", "🤫"),
        ("disguised_face", "🥸"), ("smiling_face_with_tear", "🥲"),
        ("hugging_face", "🤗"), ("nerd_face", "🤓"), ("dotted_line_face", "🫥"),
        ("melt", "🫠"), ("canned_food", "🥫"), ("cooking", "🍳"),

        // Discord-flavoured aliases people type in chat.
        ("_", "_"), ("inbox_tray", "📥"), ("outbox_tray", "📤"),
        ("scroll", "📜"), ("flag_white", "🏳️"), ("flag_black", "🏴"),
        ("ok_woman", "🙆‍♀️"), ("person_raising_hand", "🙋"),
        ("fingers_crossed", "🤞"), ("love_you_gesture", "🤟"), ("metal", "🤘"),
        ("call_me", "🤙"), ("mirror_ball", "🪩"),
        ("pick", "⛏️"), ("candle", "🕯️"), ("izakaya_lantern", "🏮"), ("hole", "🕳️"),
        ("tornado", "🌪️"), ("cyclone", "🌀"), ("foggy", "🌁"), ("night_with_stars", "🌃"),
        ("cityscape", "🏙️"), ("sunrise", "🌅"), ("sunset", "🌇"),
        ("milky_way", "🌌"), ("fireworks", "🎆"), ("sparkler", "🎇"),
    ]
}