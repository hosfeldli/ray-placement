import Foundation

struct EmojiEntry: Identifiable, Sendable {
    let emoji: String
    let name: String
    let keywords: [String]

    var id: String { emoji }
}

enum EmojiCatalog {
    static let entries: [EmojiEntry] = [
        entry("😀", "Grinning Face", "happy smile joy"), entry("😃", "Smiling Face", "happy smile joy"),
        entry("😄", "Big Smile", "happy laugh joy"), entry("😁", "Beaming Face", "grin happy"),
        entry("😂", "Tears of Joy", "laugh crying funny"), entry("🤣", "Rolling Laugh", "laugh funny lol"),
        entry("😊", "Warm Smile", "happy blush"), entry("🙂", "Slight Smile", "happy"),
        entry("🙃", "Upside-Down Face", "silly sarcasm"), entry("😉", "Wink", "playful"),
        entry("😍", "Heart Eyes", "love crush"), entry("🥰", "Smiling with Hearts", "love affection"),
        entry("😘", "Blowing a Kiss", "love kiss"), entry("😎", "Sunglasses", "cool confident"),
        entry("🤓", "Nerd Face", "geek smart"), entry("🧐", "Monocle Face", "inspect think"),
        entry("🤔", "Thinking Face", "question consider"), entry("🫡", "Saluting Face", "respect yes"),
        entry("🤗", "Hugging Face", "hug support"), entry("🤫", "Shushing Face", "quiet secret"),
        entry("🤭", "Hand over Mouth", "oops surprise"), entry("🫢", "Open Eyes Hand over Mouth", "shock surprise"),
        entry("😅", "Sweat Smile", "relief nervous"), entry("😬", "Grimacing Face", "awkward nervous"),
        entry("🙄", "Rolling Eyes", "annoyed whatever"), entry("😴", "Sleeping Face", "sleep tired"),
        entry("🥱", "Yawning Face", "tired bored"), entry("😢", "Crying Face", "sad tear"),
        entry("😭", "Loudly Crying", "sad tears"), entry("😡", "Angry Face", "mad rage"),
        entry("🤯", "Exploding Head", "mind blown shock"), entry("🥳", "Party Face", "celebrate birthday"),
        entry("🤩", "Star-Struck", "amazing wow"), entry("😇", "Halo Face", "angel innocent"),
        entry("👋", "Waving Hand", "hello goodbye hi"), entry("🤚", "Raised Back of Hand", "stop hand"),
        entry("🖐️", "Hand with Fingers Splayed", "hand five"), entry("✋", "Raised Hand", "stop high five"),
        entry("👌", "OK Hand", "okay perfect"), entry("🤌", "Pinched Fingers", "italian gesture"),
        entry("🤏", "Pinching Hand", "small little"), entry("✌️", "Victory Hand", "peace two"),
        entry("🤞", "Crossed Fingers", "luck hope"), entry("🫰", "Finger Heart", "love money"),
        entry("🤟", "Love-You Gesture", "love hand"), entry("🤘", "Rock On", "metal horns"),
        entry("🤙", "Call Me Hand", "phone shaka"), entry("👈", "Point Left", "direction"),
        entry("👉", "Point Right", "direction"), entry("👆", "Point Up", "direction"),
        entry("👇", "Point Down", "direction"), entry("☝️", "Index Up", "one point"),
        entry("👍", "Thumbs Up", "yes good like approve"), entry("👎", "Thumbs Down", "no bad dislike"),
        entry("✊", "Raised Fist", "power solidarity"), entry("👊", "Fist Bump", "punch"),
        entry("👏", "Clapping Hands", "applause congrats"), entry("🙌", "Raising Hands", "celebrate praise"),
        entry("🫶", "Heart Hands", "love support"), entry("🙏", "Folded Hands", "thanks please pray"),
        entry("💪", "Flexed Biceps", "strong muscle"), entry("🧠", "Brain", "think smart idea"),
        entry("👀", "Eyes", "look watch see"), entry("❤️", "Red Heart", "love favorite"),
        entry("🧡", "Orange Heart", "love"), entry("💛", "Yellow Heart", "love friendship"),
        entry("💚", "Green Heart", "love"), entry("💙", "Blue Heart", "love"),
        entry("💜", "Purple Heart", "love"), entry("🖤", "Black Heart", "love dark"),
        entry("🤍", "White Heart", "love"), entry("💔", "Broken Heart", "sad breakup"),
        entry("💕", "Two Hearts", "love"), entry("💯", "Hundred Points", "perfect score agree"),
        entry("🔥", "Fire", "hot trending great"), entry("✨", "Sparkles", "magic shine new"),
        entry("⭐", "Star", "favorite rating"), entry("🌟", "Glowing Star", "bright amazing"),
        entry("💫", "Dizzy", "star sparkle"), entry("⚡", "Lightning", "fast energy"),
        entry("💥", "Collision", "boom impact"), entry("🎉", "Party Popper", "celebrate congrats"),
        entry("🎊", "Confetti Ball", "celebrate party"), entry("✅", "Check Mark", "done yes complete"),
        entry("❌", "Cross Mark", "no wrong remove"), entry("⚠️", "Warning", "alert caution"),
        entry("❗", "Exclamation", "important alert"), entry("❓", "Question Mark", "help question"),
        entry("💡", "Light Bulb", "idea insight"), entry("📌", "Pushpin", "pin important"),
        entry("📎", "Paperclip", "attachment file"), entry("📝", "Memo", "note write"),
        entry("📅", "Calendar", "date schedule"), entry("⏰", "Alarm Clock", "time reminder"),
        entry("🚀", "Rocket", "launch fast ship"), entry("🎯", "Bullseye", "target goal"),
        entry("🏆", "Trophy", "win award"), entry("🥇", "Gold Medal", "first winner"),
        entry("☕", "Coffee", "drink morning"), entry("🍺", "Beer", "drink cheers"),
        entry("🥂", "Clinking Glasses", "cheers celebrate"), entry("🍕", "Pizza", "food"),
        entry("🌎", "Americas Globe", "world earth"), entry("🌈", "Rainbow", "color pride"),
        entry("☀️", "Sun", "weather bright"), entry("🌙", "Moon", "night"),
        entry("☁️", "Cloud", "weather"), entry("❄️", "Snowflake", "cold winter"),
        entry("🐶", "Dog Face", "pet puppy"), entry("🐱", "Cat Face", "pet kitten"),
        entry("🐻", "Bear", "animal"), entry("🦊", "Fox", "animal"),
        entry("🐼", "Panda", "animal"), entry("🦄", "Unicorn", "magic animal"),
        entry("💻", "Laptop", "computer work code"), entry("⌨️", "Keyboard", "computer type"),
        entry("📱", "Phone", "mobile call"), entry("🎧", "Headphones", "audio music"),
        entry("📣", "Megaphone", "announce"), entry("🔒", "Lock", "secure private"),
        entry("🔓", "Unlocked", "open access"), entry("🛠️", "Tools", "build fix"),
        entry("⚙️", "Gear", "settings system"), entry("🔍", "Magnifying Glass", "search find")
    ]

    private static func entry(_ emoji: String, _ name: String, _ keywords: String) -> EmojiEntry {
        EmojiEntry(emoji: emoji, name: name, keywords: keywords.split(separator: " ").map(String.init))
    }
}
