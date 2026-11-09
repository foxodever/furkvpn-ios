package libxray

import "testing"

var testHosts = []string{"*.furkvpn.com", "furkconnection.net"}

func keyURLOf(t *testing.T, input string) string {
	t.Helper()
	k := parseKey(input, testHosts)
	if k.Result != "ok" {
		t.Fatalf("parseKey(%q) = %s", input, k.Result)
	}
	return k.URL
}

func TestPlainSubscriptionLink(t *testing.T) {
	want := `{"result":"ok","url":"https://sub.furkvpn.com/abcDEF123456XYZ0","host":"sub.furkvpn.com","path":"/abcDEF123456XYZ0","shortId":"abcDEF123456XYZ0"}`
	if got := ParseKey("https://sub.furkvpn.com/abcDEF123456XYZ0", `["*.furkvpn.com","furkconnection.net"]`); got != want {
		t.Errorf("ParseKey = %s", got)
	}
}

func TestKeyForms(t *testing.T) {
	cases := map[string]string{
		// Client suffix and slash are removed.
		"https://sub.furkvpn.com/abcDEF123456/json":         "https://sub.furkvpn.com/abcDEF123456",
		"https://sub.furkvpn.com/abcDEF123456/":             "https://sub.furkvpn.com/abcDEF123456",
		"http://furkconnection.net/abcDEF123456/v2ray-json": "https://furkconnection.net/abcDEF123456",
		"https://sub.furkvpn.com:8443/abcDEF123456":         "https://sub.furkvpn.com:8443/abcDEF123456",
		// Links from the bot.
		"https://furkapp.net/import?url=https%3A%2F%2Fsub.furkvpn.com%2FabcDEF123456": "https://sub.furkvpn.com/abcDEF123456",
		"https://furkapp.net/import?url=https://sub.furkvpn.com/abcDEF123456":         "https://sub.furkvpn.com/abcDEF123456",
		"furkvpn://import?url=https%3A%2F%2Ffurkconnection.net%2FabcDEF123456":        "https://furkconnection.net/abcDEF123456",
		"furkvpn://add/https://sub.furkvpn.com/abcDEF123456":                          "https://sub.furkvpn.com/abcDEF123456",
		// A link inside a message.
		"Ваш ключ:\nhttps://sub.furkvpn.com/abcDEF123456.\nПриятного пользования!": "https://sub.furkvpn.com/abcDEF123456",
		"sub.furkvpn.com/abcDEF123456": "https://sub.furkvpn.com/abcDEF123456",
	}
	for in, want := range cases {
		if got := keyURLOf(t, in); got != want {
			t.Errorf("%q -> %q, want %q", in, got, want)
		}
	}
}

func TestForeignAndBrokenKeys(t *testing.T) {
	cases := map[string]string{
		"https://sub.fgnconnection.com/abcDEF123456":  "foreign",
		"https://furkvpn.com.evil.net/abcDEF123456":   "foreign",
		"https://evilfurkconnection.net/abcDEF123456": "foreign",
		"vless://uuid@1.2.3.4:443?security=reality#x": "notALink",
		"просто текст":                                "notALink",
		"https://sub.furkvpn.com/":                    "notALink",
		"https://furkapp.net/import":                  "notALink",
		"   ":                                         "empty",
	}
	for in, want := range cases {
		if got := parseKey(in, testHosts).Result; got != want {
			t.Errorf("%q -> %s, want %s", in, got, want)
		}
	}
}

func TestWildcardMatching(t *testing.T) {
	for host, want := range map[string]bool{
		"sub.furkvpn.com":        true,
		"a.b.furkvpn.com":        true,
		"SUB.FURKVPN.COM.":       true,
		"furkvpn.com":            false,
		"sub.furkconnection.net": false,
		"furkconnection.net":     true,
	} {
		if got := HostAllowed(host, `["*.furkvpn.com","furkconnection.net"]`); got != want {
			t.Errorf("HostAllowed(%q) = %v", host, got)
		}
	}
	// A broken or empty list from the API falls back to the built-in one.
	if !HostAllowed("sub.furkvpn.com", "[]") || !HostAllowed("furkconnection.net", "not json") {
		t.Error("no fallback to the default hosts")
	}
}

func TestKeyAfterOtherLinksInAMessage(t *testing.T) {
	message := "Бот: https://t.me/FurkVPNbot\nСайт: furkvpn.info\nВаш ключ: https://sub.furkvpn.com/abcDEF123456XYZ0"
	if got := keyURLOf(t, message); got != "https://sub.furkvpn.com/abcDEF123456XYZ0" {
		t.Errorf("key = %s", got)
	}
	if got := parseKey("https://t.me/FurkVPNbot https://example.com/x", testHosts).Result; got != "foreign" {
		t.Errorf("only foreign links: %s", got)
	}
}
