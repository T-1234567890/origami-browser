import Foundation

struct CommonSite {
    let name: String
    let domain: String
    let aliases: [String]
    let detail: String?
    init(_ name: String, _ domain: String, _ aliases: [String] = [], detail: String? = nil) {
        self.name = name; self.domain = domain; self.aliases = aliases; self.detail = detail
    }
}

// Human-facing destinations only. This list never requires a network lookup.
enum CommonSites {
    static let all: [CommonSite] = [
        .init("1234567890.dev", "1234567890.dev", ["1234567890"], detail: ""),
        .init("Google", "google.com", ["search"]), .init("YouTube", "youtube.com", ["yt", "video"]),
        .init("GitHub", "github.com", ["git"]), .init("Reddit", "reddit.com"),
        .init("Wikipedia", "wikipedia.org", ["wiki"]), .init("Amazon", "amazon.com"),
        .init("Apple", "apple.com"), .init("Microsoft", "microsoft.com"),
        .init("Netflix", "netflix.com"), .init("Spotify", "spotify.com", ["music"]),
        .init("Instagram", "instagram.com", ["ig"]), .init("Facebook", "facebook.com", ["fb"]),
        .init("X", "x.com", ["twitter"]), .init("LinkedIn", "linkedin.com"),
        .init("Discord", "discord.com"), .init("Twitch", "twitch.tv"),
        .init("Stack Overflow", "stackoverflow.com", ["stack"]), .init("GitLab", "gitlab.com", ["git"]),
        .init("Gmail", "mail.google.com", ["google mail"]), .init("Google Drive", "drive.google.com", ["gdrive"]),
        .init("Google Maps", "maps.google.com", ["maps"]), .init("Notion", "notion.so"),
        .init("Figma", "figma.com"), .init("Canva", "canva.com"),
        .init("Cloudflare", "cloudflare.com"), .init("OpenAI", "openai.com"),
        .init("Anthropic", "anthropic.com"), .init("ChatGPT", "chatgpt.com"),
        .init("Claude", "claude.ai"), .init("Bing", "bing.com"),
        .init("DuckDuckGo", "duckduckgo.com", ["ddg"]), .init("Brave Search", "search.brave.com"),
        .init("Yahoo", "yahoo.com"), .init("Outlook", "outlook.com", ["hotmail"]),
        .init("iCloud", "icloud.com"), .init("Dropbox", "dropbox.com"),
        .init("Google Docs", "docs.google.com"), .init("Google Calendar", "calendar.google.com"),
        .init("Google Photos", "photos.google.com"), .init("OneDrive", "onedrive.live.com"),
        .init("Slack", "slack.com"), .init("Zoom", "zoom.us"),
        .init("Microsoft Teams", "teams.microsoft.com"), .init("Trello", "trello.com"),
        .init("Asana", "asana.com"), .init("Linear", "linear.app"),
        .init("Jira", "atlassian.com", ["atlassian"]), .init("Airtable", "airtable.com"),
        .init("Pinterest", "pinterest.com"), .init("TikTok", "tiktok.com"),
        .init("Threads", "threads.com"), .init("Bluesky", "bsky.app"),
        .init("WhatsApp", "web.whatsapp.com"), .init("Telegram", "web.telegram.org"),
        .init("SoundCloud", "soundcloud.com"), .init("Bandcamp", "bandcamp.com"),
        .init("Apple Music", "music.apple.com"), .init("Vimeo", "vimeo.com"),
        .init("Disney+", "disneyplus.com", ["disney"]), .init("Prime Video", "primevideo.com"),
        .init("Hulu", "hulu.com"), .init("IMDb", "imdb.com", ["movies"]),
        .init("Steam", "store.steampowered.com", ["games"]), .init("Epic Games", "epicgames.com"),
        .init("eBay", "ebay.com"), .init("Etsy", "etsy.com"),
        .init("Walmart", "walmart.com"), .init("Target", "target.com"),
        .init("IKEA", "ikea.com"), .init("Best Buy", "bestbuy.com"),
        .init("PayPal", "paypal.com"), .init("Stripe", "stripe.com"),
        .init("Airbnb", "airbnb.com"), .init("Booking.com", "booking.com"),
        .init("Tripadvisor", "tripadvisor.com"), .init("Expedia", "expedia.com"),
        .init("BBC", "bbc.com"), .init("Reuters", "reuters.com"),
        .init("The Guardian", "theguardian.com"), .init("The New York Times", "nytimes.com", ["nyt"]),
        .init("Hacker News", "news.ycombinator.com", ["hn"]), .init("MDN Web Docs", "developer.mozilla.org", ["mozilla", "mdn"]),
        .init("Apple Developer", "developer.apple.com", ["swift", "apple dev"]), .init("Swift", "swift.org"),
        .init("npm", "npmjs.com", ["javascript"]), .init("PyPI", "pypi.org", ["python packages"]),
        .init("Python", "python.org"), .init("Rust", "rust-lang.org"),
        .init("Docker", "docker.com"), .init("Vercel", "vercel.com"),
        .init("Netlify", "netlify.com"), .init("DigitalOcean", "digitalocean.com"),
        .init("AWS", "aws.amazon.com", ["amazon web services"]), .init("Google Cloud", "cloud.google.com", ["gcp"]),
        .init("Microsoft Azure", "azure.microsoft.com"), .init("CodePen", "codepen.io"),
        .init("Medium", "medium.com"), .init("Substack", "substack.com"),
        .init("Coursera", "coursera.org"), .init("Khan Academy", "khanacademy.org"),
        .init("Duolingo", "duolingo.com"), .init("Internet Archive", "archive.org", ["wayback"])
    ]
}
