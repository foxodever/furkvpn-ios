package libxray

import (
	"regexp"
	"strings"
)

// Adding a key to a TV from a phone: the FurkVPN TV app shows furkapp.net/tv/<code> as a QR code,
// the phone sends its key for that code (POST https://furkapp.net/api/v1/tv/send).

var tvLink = regexp.MustCompile(`(?i)^(?:https://furkapp\.net/tv/|furkvpn://tv/)([a-z0-9]{3}-?[a-z0-9]{3})/?$`)

// TvCodeFromLink turns the TV's QR code "https://furkapp.net/tv/ABC123" (or "furkvpn://tv/ABC123")
// into "ABC123"; "" when the text is not such a link.
func TvCodeFromLink(text string) string {
	m := tvLink.FindStringSubmatch(strings.TrimSpace(text))
	if m == nil {
		return ""
	}
	return strings.ToUpper(strings.ReplaceAll(m[1], "-", ""))
}
